import Foundation
import NTFSLiteHelperProtocol

/// A writable FSKit mount served by the helper's pinned driver.
public struct HelperOwnedMount: Equatable, Sendable {
    public let mountPoint: String
    public let driverPID: Int32

    public init(mountPoint: String, driverPID: Int32) {
        self.mountPoint = mountPoint
        self.driverPID = driverPID
    }
}

/// Primitive release operations; none of them may force an unmount or eject.
public protocol DiskReleaseSystem: HelperMediaTopologyReading {
    func unmountFileSystem(mountPoint: String) async -> Bool
    /// Bounded wait for the driver to exit on its own.
    func waitForDriverExit(pid: Int32) async -> Bool
    func removeEmptyMountPoint(_ path: String) async -> Bool
    func unmountNativeVolume(bsdName: String, expectedRegistryEntryID: UInt64) async -> Bool
    func eject(diskBSDName: String, expectedRegistryEntryID: UInt64) async -> Bool
    /// nil means presence could not be established; only an explicit false is absence.
    func diskIsPresent(bsdName: String, registryEntryID: UInt64) async -> Bool?
    /// Our driver's mounts whose partition device on `diskBSDName` no longer exists.
    func orphanedMounts(diskBSDName: String) async -> [HelperOwnedMount]?
    func pause() async
}

public enum DiskReleaseFailure: Int32, Sendable {
    case targetMismatch = 21
    case notExternalRemovable = 22
    case ambiguousMount = 23
    case unmountRefused = 24
    case driverNotExited = 25
    case mountPointNotRemoved = 26
    case stillMounted = 27
    case ejectRefused = 28
    case ejectNotConfirmed = 29
    case factsUnavailable = 30
}

public enum DiskReleaseExecutor {
    static let ejectConfirmationPolls = 40

    public static func unmountVolume(target: HelperVolumeInstanceIdentity, system: DiskReleaseSystem) async -> HelperResponseEnvelope {
        let bsd = target.volumeBSDName
        let verified: [HelperVerifiedPartition]
        switch await HelperTopologyVerifier.verify(target.disk, selectedVolumeBSDName: bsd, system: system) {
        case let .success(partitions):
            verified = partitions
        case let .failure(failure):
            return failed(topologyFailure(failure))
        }
        guard let partition = verified.first(where: { $0.bsdName == bsd }) else {
            return failed(.targetMismatch)
        }
        if partition.ownedMounts.isEmpty,
           let mountPoint = partition.facts.mountPoint, !mountPoint.isEmpty {
            guard let uuid = partition.facts.volumeUUID,
                  uuid.caseInsensitiveCompare(target.volumeUUID) == .orderedSame
            else { return failed(.targetMismatch) }
        }
        if let failure = await release(partition: partition, system: system) { return failure }
        return await confirmedReleased(
            target: target.disk, selectedVolumeBSDName: bsd, system: system
        )
    }

    public static func unmountDisk(target: HelperDiskInstanceIdentity, system: DiskReleaseSystem) async -> HelperResponseEnvelope {
        switch await verifiedPartitions(of: target, system: system) {
        case let .failure(failure):
            return failure.response
        case let .success(partitions):
            for partition in partitions {
                // A prior sibling release may have yielded while the media changed.
                switch await verifiedPartitions(of: target, system: system) {
                case let .failure(failure): return failure.response
                case let .success(current):
                    guard let fresh = current.first(where: { $0.bsdName == partition.bsdName }) else {
                        return failed(.targetMismatch)
                    }
                    if let failure = await release(partition: fresh, system: system) {
                        return failure
                    }
                }
            }
            return await confirmedReleased(target: target, system: system)
        }
    }

    public static func ejectDisk(target: HelperDiskInstanceIdentity, system: DiskReleaseSystem) async -> HelperResponseEnvelope {
        if await system.volumeFacts(bsdName: target.physicalDiskBSDName) == nil,
           await system.diskIsPresent(
               bsdName: target.physicalDiskBSDName, registryEntryID: target.registryEntryID
           ) == false {
            // Already removed: done only once none of our mounts for it remain.
            guard let orphans = await system.orphanedMounts(diskBSDName: target.physicalDiskBSDName) else { return failed(.factsUnavailable) }
            // Absence before this eject request cannot prove a standard safe eject.
            return orphans.isEmpty ? failed(.factsUnavailable) : failed(.stillMounted)
        }
        switch await verifiedPartitions(of: target, system: system) {
        case let .failure(failure):
            return failure.response
        case let .success(partitions):
            for partition in partitions {
                guard let owned = await system.ownedFSKitMounts(devicePath: "/dev/" + partition.bsdName) else {
                    return failed(.factsUnavailable)
                }
                guard owned.isEmpty, partition.ownedMounts.isEmpty,
                      partition.facts.mountPoint?.isEmpty ?? true
                else { return failed(.stillMounted) }
            }
            let disk = target.physicalDiskBSDName
            // `unmountDisk` and `ejectDisk` are separate requests. Rebind the
            // current media immediately before the irreversible eject call.
            switch await verifiedPartitions(of: target, system: system) {
            case let .failure(failure): return failure.response
            case let .success(fresh):
                for partition in fresh {
                    guard let owned = await system.ownedFSKitMounts(devicePath: "/dev/" + partition.bsdName) else {
                        return failed(.factsUnavailable)
                    }
                    guard owned.isEmpty, partition.ownedMounts.isEmpty,
                          partition.facts.mountPoint?.isEmpty ?? true else {
                        return failed(.stillMounted)
                    }
                }
            }
            guard await system.eject(diskBSDName: disk, expectedRegistryEntryID: target.registryEntryID) else {
                return changed(.ejectRefused)
            }
            var consecutiveAbsence = 0
            for _ in 0..<ejectConfirmationPolls {
                guard let isPresent = await system.diskIsPresent(
                    bsdName: disk, registryEntryID: target.registryEntryID
                ) else {
                    return changed(.factsUnavailable)
                }
                consecutiveAbsence = isPresent ? 0 : consecutiveAbsence + 1
                if consecutiveAbsence >= 2 { return succeeded }
                await system.pause()
            }
            return changed(.ejectNotConfirmed)
        }
    }

    /// Releases one partition; nil means it is no longer mounted.
    private static func release(
        partition: HelperVerifiedPartition, system: DiskReleaseSystem
    ) async -> HelperResponseEnvelope? {
        let bsd = partition.bsdName
        guard let owned = await system.ownedFSKitMounts(devicePath: "/dev/" + bsd) else { return failed(.factsUnavailable) }
        guard owned == partition.ownedMounts else { return failed(.ambiguousMount) }
        if let mount = owned.first {
            guard await system.unmountFileSystem(mountPoint: mount.mountPoint) else { return changed(.unmountRefused) }
            guard await system.waitForDriverExit(pid: mount.driverPID) else { return changed(.driverNotExited) }
            guard await system.removeEmptyMountPoint(mount.mountPoint) else { return changed(.mountPointNotRemoved) }
            return nil
        }
        if let mountPoint = partition.facts.mountPoint, !mountPoint.isEmpty {
            guard await system.unmountNativeVolume(
                bsdName: bsd, expectedRegistryEntryID: partition.registryEntryID
            ) else { return changed(.unmountRefused) }
        }
        return nil
    }

    private static func confirmedReleased(
        target: HelperDiskInstanceIdentity, selectedVolumeBSDName: String? = nil,
        system: DiskReleaseSystem
    ) async -> HelperResponseEnvelope {
        switch await HelperTopologyVerifier.verify(
            target, selectedVolumeBSDName: selectedVolumeBSDName, system: system
        ) {
        case let .failure(failure):
            return changed(topologyFailure(failure))
        case let .success(partitions):
            let checked = selectedVolumeBSDName.map { bsd in partitions.filter { $0.bsdName == bsd } } ?? partitions
            guard !checked.isEmpty,
                  checked.allSatisfy({ $0.ownedMounts.isEmpty && ($0.facts.mountPoint?.isEmpty ?? true) })
            else { return changed(.stillMounted) }
            return succeeded
        }
    }

    private static func verifiedPartitions(
        of target: HelperDiskInstanceIdentity, system: DiskReleaseSystem
    ) async -> Result<[HelperVerifiedPartition], ResponseFailure> {
        switch await HelperTopologyVerifier.verify(target, system: system) {
        case let .failure(failure):
            return .failure(ResponseFailure(failed(topologyFailure(failure))))
        case let .success(partitions):
            return .success(partitions)
        }
    }

    static func isExternalRemovable(_ facts: HelperVolumeFacts) -> Bool {
        HelperTopologyVerifier.isExternalRemovable(facts)
    }

    private static func topologyFailure(_ failure: HelperTopologyFailure) -> DiskReleaseFailure {
        switch failure {
        case .factsUnavailable: .factsUnavailable
        case .targetMismatch: .targetMismatch
        case .notExternalRemovable: .notExternalRemovable
        case .ambiguousMount: .ambiguousMount
        case .siblingMounted: .stillMounted
        }
    }

    private static let succeeded = HelperResponseEnvelope(resultCode: .succeeded, exitStatus: 0)

    private static func failed(_ failure: DiskReleaseFailure) -> HelperResponseEnvelope {
        HelperResponseEnvelope(resultCode: .executionFailed, exitStatus: failure.rawValue)
    }

    private static func changed(_ failure: DiskReleaseFailure) -> HelperResponseEnvelope {
        HelperResponseEnvelope(resultCode: .postconditionFailed, exitStatus: failure.rawValue)
    }
}

/// Carries an early response through `Result`.
struct ResponseFailure: Error {
    let response: HelperResponseEnvelope
    init(_ response: HelperResponseEnvelope) { self.response = response }
}
