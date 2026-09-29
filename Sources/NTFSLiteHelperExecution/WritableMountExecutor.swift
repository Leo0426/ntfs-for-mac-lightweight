import Foundation
import NTFSLiteHelperProtocol

/// Facts the helper reads fresh from Disk Arbitration and the mounted file system.
public struct HelperVolumeFacts: Equatable, Sendable {
    public var bsdName: String?
    public var wholeDiskBSDName: String?
    public var isWholeDisk: Bool?
    public var isInternal: Bool?
    public var isRemovable: Bool?
    public var isEjectable: Bool?
    public var deviceProtocol: String?
    public var fileSystemName: String?
    public var mountPoint: String?
    public var isWritableMount: Bool?
    public var volumeUUID: String?
    public var volumeName: String?

    public init(
        bsdName: String?, wholeDiskBSDName: String?, isWholeDisk: Bool?, isInternal: Bool?,
        isRemovable: Bool?, isEjectable: Bool?, deviceProtocol: String?, fileSystemName: String?,
        mountPoint: String?, isWritableMount: Bool?, volumeUUID: String?, volumeName: String? = nil
    ) {
        self.bsdName = bsdName
        self.wholeDiskBSDName = wholeDiskBSDName
        self.isWholeDisk = isWholeDisk
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.deviceProtocol = deviceProtocol
        self.fileSystemName = fileSystemName
        self.mountPoint = mountPoint
        self.isWritableMount = isWritableMount
        self.volumeUUID = volumeUUID
        self.volumeName = volumeName
    }
}

public struct HelperMountEntry: Equatable, Sendable {
    public let source: String
    public let mountPoint: String
    public let flags: Set<String>

    public init(source: String, mountPoint: String, flags: Set<String>) {
        self.source = source
        self.mountPoint = mountPoint
        self.flags = flags
    }
}

public struct HelperDriverState: Equatable, Sendable {
    public let isAlive: Bool
    public let uid: UInt32?
    public let gid: UInt32?

    public init(isAlive: Bool, uid: UInt32?, gid: UInt32?) {
        self.isAlive = isAlive
        self.uid = uid
        self.gid = gid
    }
}

/// Primitive system operations the privileged helper implements; every answer is fresh.
public protocol WritableMountSystem: Sendable {
    func volumeFacts(bsdName: String) async -> HelperVolumeFacts?
    func readBootSector(partitionBSDName: String) async -> Data?
    /// Standard (never forced) unmount of the native read-only mount.
    func unmountNative(bsdName: String) async -> Bool
    /// No-recovery health probe; nil means unknown.
    func healthIsClean(bsdName: String) async -> Bool?
    func pathExists(_ path: String) async -> Bool
    /// Starts the pinned driver in its own session; returns its pid.
    func startDriver(bsdName: String, mountPoint: String) async -> Int32?
    func mountEntry(at mountPoint: String) async -> HelperMountEntry?
    func isFSKitPlaceholder(source: String) async -> Bool
    func driverState(pid: Int32) async -> HelperDriverState
    func driverHolds(pid: Int32, devicePath: String) async -> Bool
    func isWritable(mountPoint: String) async -> Bool
    /// Short wait between mount-table polls.
    func pause() async
}

/// Fixed, non-sensitive stage codes returned as the helper exit status.
public enum WritableMountFailure: Int32, Sendable {
    case targetMismatch = 1
    case notExternalRemovable = 2
    case notNTFS = 3
    case notNativeReadOnly = 4
    case identityUnavailable = 5
    case bootSectorInvalid = 6
    case nativeUnmountFailed = 7
    case bootSectorChanged = 8
    case healthNotClean = 9
    case driverStartFailed = 10
    case mountNotObserved = 11
    case mountNotVerified = 12
    case factsUnavailable = 13
    case volumeUUIDMismatch = 14
}

public enum WritableMountExecutor {
    public static let mountUID: UInt32 = 501
    public static let mountGID: UInt32 = 20
    static let externalProtocols: Set<String> = ["USB", "Thunderbolt"]
    static let mountPollLimit = 80

    public static func run(target: HelperVolumeInstanceIdentity, system: WritableMountSystem) async -> HelperResponseEnvelope {
        let bsd = target.volumeBSDName
        // Before any mutation: every failure leaves the system unchanged.
        guard let facts = await system.volumeFacts(bsdName: bsd) else { return refused(.factsUnavailable) }
        guard facts.bsdName == bsd, facts.wholeDiskBSDName == target.disk.physicalDiskBSDName,
              facts.isWholeDisk == false
        else { return refused(.targetMismatch) }
        guard facts.isInternal == false, facts.isRemovable == true, facts.isEjectable == true,
              let deviceProtocol = facts.deviceProtocol, externalProtocols.contains(deviceProtocol)
        else { return refused(.notExternalRemovable) }
        guard facts.fileSystemName?.lowercased() == "ntfs" else { return refused(.notNTFS) }
        guard let mountPoint = facts.mountPoint, !mountPoint.isEmpty, facts.isWritableMount == false
        else { return refused(.notNativeReadOnly) }
        guard let uuid = facts.volumeUUID else { return refused(.identityUnavailable) }
        guard uuid.caseInsensitiveCompare(target.volumeUUID) == .orderedSame else { return refused(.volumeUUIDMismatch) }
        guard let boot = await system.readBootSector(partitionBSDName: bsd), isNTFSBootSector(boot)
        else { return refused(.bootSectorInvalid) }

        guard await system.unmountNative(bsdName: bsd) else { return refused(.nativeUnmountFailed) }

        // After the native unmount: the volume state has changed; the app must re-read facts.
        guard let unmounted = await system.volumeFacts(bsdName: bsd),
              unmounted.wholeDiskBSDName == target.disk.physicalDiskBSDName,
              unmounted.mountPoint == nil || unmounted.mountPoint == ""
        else { return changed(.nativeUnmountFailed) }
        guard await system.readBootSector(partitionBSDName: bsd) == boot else { return changed(.bootSectorChanged) }
        guard await system.healthIsClean(bsdName: bsd) == true else { return changed(.healthNotClean) }

        // Under FSKit, Finder names the volume after its mount point: keep the familiar label.
        var root: String?
        let name = mountPointName(forLabel: facts.volumeName ?? "")
        for candidate in [name] + (2...9).map({ "\(name) \($0)" }) where await !system.pathExists("/Volumes/" + candidate) {
            root = "/Volumes/" + candidate
            break
        }
        guard let root else { return changed(.driverStartFailed) }
        guard let pid = await system.startDriver(bsdName: bsd, mountPoint: root) else {
            return changed(.driverStartFailed)
        }
        var entry: HelperMountEntry?
        for _ in 0..<mountPollLimit {
            entry = await system.mountEntry(at: root)
            if entry != nil { break }
            guard await system.driverState(pid: pid).isAlive else { return changed(.mountNotObserved) }
            await system.pause()
        }
        guard let entry else { return changed(.mountNotObserved) }
        let driver = await system.driverState(pid: pid)
        guard entry.mountPoint == root,
              entry.flags.isSuperset(of: ["macfuse", "local", "fskit", "nodev", "nosuid"]),
              !entry.flags.contains("read-only"),
              await system.isFSKitPlaceholder(source: entry.source),
              driver.isAlive, driver.uid == mountUID, driver.gid == mountGID,
              await system.driverHolds(pid: pid, devicePath: "/dev/" + bsd),
              await system.isWritable(mountPoint: root)
        else { return changed(.mountNotVerified) }
        return HelperResponseEnvelope(resultCode: .succeeded, exitStatus: 0)
    }

    /// Safe single path component for the mount point; anything unusual becomes "NTFS".
    public static func mountPointName(forLabel label: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _-."))
        guard (1...32).contains(label.count), !label.hasPrefix("."), !label.hasSuffix(" "),
              label.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII })
        else { return "NTFS" }
        return label
    }

    static func isNTFSBootSector(_ boot: Data) -> Bool {
        let bytes = [UInt8](boot)
        return bytes.count == 512 && Array(bytes[3..<11]) == Array("NTFS    ".utf8)
            && bytes[510] == 0x55 && bytes[511] == 0xAA && bytes[72..<80].contains { $0 != 0 }
    }

    private static func refused(_ failure: WritableMountFailure) -> HelperResponseEnvelope {
        HelperResponseEnvelope(resultCode: .executionFailed, exitStatus: failure.rawValue)
    }

    private static func changed(_ failure: WritableMountFailure) -> HelperResponseEnvelope {
        HelperResponseEnvelope(resultCode: .postconditionFailed, exitStatus: failure.rawValue)
    }
}
