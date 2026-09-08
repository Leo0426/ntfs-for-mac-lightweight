import CoreFoundation
import DiskArbitration
import Foundation
import NTFSLiteCore

public struct DiskArbitrationDescription: Equatable, Sendable {
    public let bsdName: String?
    public let physicalDiskBSDName: String?
    public let isWholeDisk: Bool?
    public let isInternal: Bool?
    public let isEjectable: Bool?
    public let isRemovable: Bool?
    public let mediaSize: UInt64?
    public let mediaUUID: String?
    public let volumeUUID: String?
    public let volumeName: String?
    public let fileSystemName: String?
    public let mountPoint: String?
    public let roleEvidence: VolumeRoleEvidence
    public let isNetworkVolume: Bool?

    public init(
        bsdName: String?,
        physicalDiskBSDName: String?,
        isWholeDisk: Bool?,
        isInternal: Bool?,
        isEjectable: Bool?,
        isRemovable: Bool?,
        mediaSize: UInt64?,
        mediaUUID: String?,
        volumeUUID: String?,
        volumeName: String?,
        fileSystemName: String?,
        mountPoint: String?,
        roleEvidence: VolumeRoleEvidence? = nil,
        isNetworkVolume: Bool? = nil
    ) {
        self.bsdName = bsdName
        self.physicalDiskBSDName = physicalDiskBSDName
        self.isWholeDisk = isWholeDisk
        self.isInternal = isInternal
        self.isEjectable = isEjectable
        self.isRemovable = isRemovable
        self.mediaSize = mediaSize
        self.mediaUUID = mediaUUID
        self.volumeUUID = volumeUUID
        self.volumeName = volumeName
        self.fileSystemName = fileSystemName
        self.mountPoint = mountPoint
        // The live Disk Arbitration decoder never supplies an override. An
        // internal location is enough for generic protection; every other
        // role remains unknown until a separate trusted source is introduced.
        self.roleEvidence = roleEvidence ?? (isInternal == true ? .protected : .unknown)
        self.isNetworkVolume = isNetworkVolume
    }

    public var volumeEvidence: ReadOnlyVolumeEvidence? {
        guard isWholeDisk == false else {
            return nil
        }
        return ReadOnlyVolumeEvidence(
            bsdName: bsdName,
            volumeUUID: volumeUUID,
            physicalDiskBSDName: physicalDiskBSDName,
            displayName: volumeName,
            fileSystemName: fileSystemName,
            isInternal: isInternal,
            roleEvidence: roleEvidence,
            diskArbitrationMountPoint: mountPoint
        )
    }
}

public enum DiskArbitrationEventKind: Equatable, Sendable {
    case appeared
    case descriptionChanged
    case disappeared
}

public struct DiskArbitrationEvent: Equatable, Sendable {
    public let kind: DiskArbitrationEventKind
    public let description: DiskArbitrationDescription

    public init(kind: DiskArbitrationEventKind, description: DiskArbitrationDescription) {
        self.kind = kind
        self.description = description
    }
}

public enum DiskArbitrationEventSourceError: Error, Equatable, Sendable {
    case sessionCreationFailed
}

package enum DiskArbitrationDescriptionValueDecoder {
    package static func boolean(_ rawValue: Any?) -> Bool? {
        guard let rawValue else {
            return nil
        }
        let value = rawValue as CFTypeRef
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return nil
        }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }
}

public struct DiskArbitrationEventSource: Sendable {
    public init() {}

    public func events() throws -> AsyncStream<DiskArbitrationEvent> {
        let session = try eventStreamSession()
        return AsyncStream { continuation in
            let forwardingTask = Task {
                for await item in session.items {
                    guard !Task.isCancelled else {
                        break
                    }
                    guard case let .event(event) = item else {
                        continue
                    }
                    if case .terminated = continuation.yield(event) {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                forwardingTask.cancel()
                session.stopImmediately()
            }
        }
    }

    public func eventStreamSession() throws -> DiskEventStreamSession {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw DiskArbitrationEventSourceError.sessionCreationFailed
        }
        let pair = AsyncStream<DiskEventStreamItem>.makeStream()
        let controller = DiskArbitrationStreamController(
            session: session,
            continuation: pair.continuation
        )
        pair.continuation.onTermination = { @Sendable _ in
            controller.stop()
        }
        controller.start()
        return DiskEventStreamSession(
            items: pair.stream,
            stopAndDrain: {
                await controller.stopAndDrain()
            },
            stopImmediately: {
                controller.stop()
            }
        )
    }
}

private final class DiskArbitrationStreamController: @unchecked Sendable {
    private let session: DASession
    private let queue = DispatchQueue(label: "NTFSLite.DiskArbitration.ReadOnly")
    private let lock = NSLock()
    private var continuation: AsyncStream<DiskEventStreamItem>.Continuation?
    private var callbackContext: UnsafeMutableRawPointer?
    private var isStopped = false
    private var isDraining = false
    private var drainWaiters: [CheckedContinuation<Bool, Never>] = []

    init(
        session: DASession,
        continuation: AsyncStream<DiskEventStreamItem>.Continuation
    ) {
        self.session = session
        self.continuation = continuation
    }

    func start() {
        let context = Unmanaged.passRetained(self).toOpaque()
        callbackContext = context
        DARegisterDiskAppearedCallback(session, nil, diskAppeared, context)
        DARegisterDiskDescriptionChangedCallback(
            session,
            nil,
            nil,
            diskDescriptionChanged,
            context
        )
        DARegisterDiskDisappearedCallback(session, nil, diskDisappeared, context)
        DASessionSetDispatchQueue(session, queue)
    }

    func stop() {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        isStopped = true
        continuation = nil
        let context = callbackContext
        callbackContext = nil
        let waiters = drainWaiters
        drainWaiters = []
        lock.unlock()

        DASessionSetDispatchQueue(session, nil)
        waiters.forEach { $0.resume(returning: false) }
        if let context {
            let contextAddress = UInt(bitPattern: context)
            queue.async {
                guard let drainedContext = UnsafeMutableRawPointer(
                    bitPattern: contextAddress
                ) else {
                    return
                }
                Unmanaged<DiskArbitrationStreamController>
                    .fromOpaque(drainedContext)
                    .release()
            }
        }
    }

    func stopAndDrain() async -> Bool {
        await withCheckedContinuation { response in
            lock.lock()
            guard !isStopped else {
                lock.unlock()
                response.resume(returning: false)
                return
            }
            drainWaiters.append(response)
            if isDraining {
                lock.unlock()
                return
            }
            isDraining = true
            lock.unlock()

            DASessionSetDispatchQueue(session, nil)
            queue.async { [self] in
                completeDrainBarrier()
            }
        }
    }

    private func completeDrainBarrier() {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        isStopped = true
        let activeContinuation = continuation
        continuation = nil
        let context = callbackContext
        callbackContext = nil
        let waiters = drainWaiters
        drainWaiters = []
        lock.unlock()

        let boundaryAccepted: Bool
        if let activeContinuation {
            switch activeContinuation.yield(.drainBoundary) {
            case .enqueued:
                boundaryAccepted = true
            case .dropped, .terminated:
                boundaryAccepted = false
            @unknown default:
                boundaryAccepted = false
            }
            activeContinuation.finish()
        } else {
            boundaryAccepted = false
        }
        if let context {
            Unmanaged<DiskArbitrationStreamController>
                .fromOpaque(context)
                .release()
        }
        waiters.forEach { $0.resume(returning: boundaryAccepted) }
    }

    func receive(_ disk: DADisk, kind: DiskArbitrationEventKind) {
        let event = DiskArbitrationEvent(
            kind: kind,
            description: Self.copyDescription(of: disk)
        )

        lock.lock()
        let activeContinuation = isStopped ? nil : continuation
        lock.unlock()
        activeContinuation?.yield(.event(event))
    }

    private static func copyDescription(of disk: DADisk) -> DiskArbitrationDescription {
        let dictionary = DADiskCopyDescription(disk) as? [String: Any] ?? [:]
        let bsdName = DADiskGetBSDName(disk).map(String.init(cString:))

        let physicalDiskBSDName: String?
        if let wholeDisk = DADiskCopyWholeDisk(disk),
           let wholeDiskName = DADiskGetBSDName(wholeDisk)
        {
            physicalDiskBSDName = String(cString: wholeDiskName)
        } else {
            physicalDiskBSDName = nil
        }

        let volumePath = value(
            for: kDADiskDescriptionVolumePathKey,
            in: dictionary,
            as: URL.self
        )?.path

        return DiskArbitrationDescription(
            bsdName: bsdName,
            physicalDiskBSDName: physicalDiskBSDName,
            isWholeDisk: bool(for: kDADiskDescriptionMediaWholeKey, in: dictionary),
            isInternal: bool(for: kDADiskDescriptionDeviceInternalKey, in: dictionary),
            isEjectable: bool(for: kDADiskDescriptionMediaEjectableKey, in: dictionary),
            isRemovable: bool(for: kDADiskDescriptionMediaRemovableKey, in: dictionary),
            mediaSize: number(for: kDADiskDescriptionMediaSizeKey, in: dictionary)?.uint64Value,
            mediaUUID: uuidString(for: kDADiskDescriptionMediaUUIDKey, in: dictionary),
            volumeUUID: uuidString(for: kDADiskDescriptionVolumeUUIDKey, in: dictionary),
            volumeName: string(for: kDADiskDescriptionVolumeNameKey, in: dictionary),
            fileSystemName: string(for: kDADiskDescriptionVolumeKindKey, in: dictionary),
            mountPoint: volumePath,
            isNetworkVolume: bool(
                for: kDADiskDescriptionVolumeNetworkKey,
                in: dictionary
            )
        )
    }

    private static func value<T>(
        for key: CFString,
        in dictionary: [String: Any],
        as type: T.Type
    ) -> T? {
        dictionary[key as String] as? T
    }

    private static func string(
        for key: CFString,
        in dictionary: [String: Any]
    ) -> String? {
        value(for: key, in: dictionary, as: String.self)
    }

    private static func number(
        for key: CFString,
        in dictionary: [String: Any]
    ) -> NSNumber? {
        value(for: key, in: dictionary, as: NSNumber.self)
    }

    private static func bool(
        for key: CFString,
        in dictionary: [String: Any]
    ) -> Bool? {
        DiskArbitrationDescriptionValueDecoder.boolean(
            dictionary[key as String]
        )
    }

    private static func uuidString(
        for key: CFString,
        in dictionary: [String: Any]
    ) -> String? {
        guard let rawValue = dictionary[key as String] else {
            return nil
        }
        let value = rawValue as CFTypeRef
        guard CFGetTypeID(value) == CFUUIDGetTypeID() else {
            return nil
        }
        let uuid = unsafeDowncast(value, to: CFUUID.self)
        return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String?
    }
}

private func diskAppeared(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    guard let context else {
        return
    }
    Unmanaged<DiskArbitrationStreamController>
        .fromOpaque(context)
        .takeUnretainedValue()
        .receive(disk, kind: .appeared)
}

private func diskDescriptionChanged(
    _ disk: DADisk,
    _: CFArray,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else {
        return
    }
    Unmanaged<DiskArbitrationStreamController>
        .fromOpaque(context)
        .takeUnretainedValue()
        .receive(disk, kind: .descriptionChanged)
}

private func diskDisappeared(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    guard let context else {
        return
    }
    Unmanaged<DiskArbitrationStreamController>
        .fromOpaque(context)
        .takeUnretainedValue()
        .receive(disk, kind: .disappeared)
}
