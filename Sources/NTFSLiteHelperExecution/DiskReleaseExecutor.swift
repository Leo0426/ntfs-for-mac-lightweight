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
public protocol DiskReleaseSystem: Sendable {
    func volumeFacts(bsdName: String) async -> HelperVolumeFacts?
    func partitions(ofDisk bsdName: String) async -> [String]?
    /// FSKit mounts whose pinned driver process holds `devicePath`; nil when facts are unavailable.
    func ownedFSKitMounts(devicePath: String) async -> [HelperOwnedMount]?
    func unmountFileSystem(mountPoint: String) async -> Bool
    /// Bounded wait for the driver to exit on its own.
    func waitForDriverExit(pid: Int32) async -> Bool
    func removeEmptyMountPoint(_ path: String) async -> Bool
    func unmountNativeVolume(bsdName: String) async -> Bool
    func eject(diskBSDName: String) async -> Bool
    func diskIsPresent(bsdName: String) async -> Bool
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
        guard let facts = await system.volumeFacts(bsdName: bsd), facts.bsdName == bsd,
              facts.isWholeDisk == false, facts.wholeDiskBSDName == target.disk.physicalDiskBSDName
        else { return failed(.targetMismatch) }
        guard isExternalRemovable(facts) else { return failed(.notExternalRemovable) }
        return await release(partition: bsd, facts: facts, system: system) ?? succeeded
    }

    public static func unmountDisk(target: HelperDiskInstanceIdentity, system: DiskReleaseSystem) async -> HelperResponseEnvelope {
        if let removed = await releaseOrphans(ofRemoved: target, system: system) { return removed }
        switch await verifiedPartitions(of: target, system: system) {
        case let .failure(failure):
            return failure.response
        case let .success(partitions):
            for (bsd, facts) in partitions {
                if let failure = await release(partition: bsd, facts: facts, system: system) { return failure }
            }
            return succeeded
        }
    }

    public static func ejectDisk(target: HelperDiskInstanceIdentity, system: DiskReleaseSystem) async -> HelperResponseEnvelope {
        if await system.volumeFacts(bsdName: target.physicalDiskBSDName) == nil,
           await !system.diskIsPresent(bsdName: target.physicalDiskBSDName) {
            // Already removed: done only once none of our mounts for it remain.
            guard let orphans = await system.orphanedMounts(diskBSDName: target.physicalDiskBSDName) else { return failed(.factsUnavailable) }
            return orphans.isEmpty ? succeeded : failed(.stillMounted)
        }
        switch await verifiedPartitions(of: target, system: system) {
        case let .failure(failure):
            return failure.response
        case let .success(partitions):
            for (bsd, facts) in partitions {
                guard let owned = await system.ownedFSKitMounts(devicePath: "/dev/" + bsd) else { return failed(.factsUnavailable) }
                guard owned.isEmpty, facts.mountPoint?.isEmpty ?? true else { return failed(.stillMounted) }
            }
            let disk = target.physicalDiskBSDName
            guard await system.eject(diskBSDName: disk) else { return failed(.ejectRefused) }
            for _ in 0..<ejectConfirmationPolls {
                if await !system.diskIsPresent(bsdName: disk) { return succeeded }
                await system.pause()
            }
            return changed(.ejectNotConfirmed)
        }
    }

    /// A disk pulled out while writable leaves our driver serving a dead device. Returns nil when
    /// the disk is present (normal path applies).
    private static func releaseOrphans(ofRemoved target: HelperDiskInstanceIdentity, system: DiskReleaseSystem) async -> HelperResponseEnvelope? {
        let disk = target.physicalDiskBSDName
        guard await system.volumeFacts(bsdName: disk) == nil, await !system.diskIsPresent(bsdName: disk) else { return nil }
        guard let orphans = await system.orphanedMounts(diskBSDName: disk) else { return failed(.factsUnavailable) }
        for mount in orphans {
            guard await system.unmountFileSystem(mountPoint: mount.mountPoint) else { return failed(.unmountRefused) }
            guard await system.waitForDriverExit(pid: mount.driverPID) else { return changed(.driverNotExited) }
            guard await system.removeEmptyMountPoint(mount.mountPoint) else { return changed(.mountPointNotRemoved) }
        }
        return succeeded
    }

    /// Releases one partition; nil means it is no longer mounted.
    private static func release(partition bsd: String, facts: HelperVolumeFacts, system: DiskReleaseSystem) async -> HelperResponseEnvelope? {
        guard let owned = await system.ownedFSKitMounts(devicePath: "/dev/" + bsd) else { return failed(.factsUnavailable) }
        guard owned.count <= 1 else { return failed(.ambiguousMount) }
        if let mount = owned.first {
            guard await system.unmountFileSystem(mountPoint: mount.mountPoint) else { return failed(.unmountRefused) }
            guard await system.waitForDriverExit(pid: mount.driverPID) else { return changed(.driverNotExited) }
            guard await system.removeEmptyMountPoint(mount.mountPoint) else { return changed(.mountPointNotRemoved) }
            return nil
        }
        if let mountPoint = facts.mountPoint, !mountPoint.isEmpty {
            guard await system.unmountNativeVolume(bsdName: bsd) else { return failed(.unmountRefused) }
        }
        return nil
    }

    private static func verifiedPartitions(
        of target: HelperDiskInstanceIdentity, system: DiskReleaseSystem
    ) async -> Result<[(String, HelperVolumeFacts)], ResponseFailure> {
        let disk = target.physicalDiskBSDName
        guard let facts = await system.volumeFacts(bsdName: disk), facts.bsdName == disk, facts.isWholeDisk == true
        else { return .failure(ResponseFailure(failed(.targetMismatch))) }
        guard isExternalRemovable(facts) else { return .failure(ResponseFailure(failed(.notExternalRemovable))) }
        guard let names = await system.partitions(ofDisk: disk) else { return .failure(ResponseFailure(failed(.factsUnavailable))) }
        var partitions: [(String, HelperVolumeFacts)] = []
        for name in names {
            guard let partition = await system.volumeFacts(bsdName: name), partition.wholeDiskBSDName == disk
            else { return .failure(ResponseFailure(failed(.factsUnavailable))) }
            partitions.append((name, partition))
        }
        return .success(partitions)
    }

    static func isExternalRemovable(_ facts: HelperVolumeFacts) -> Bool {
        facts.isInternal == false && facts.isRemovable == true && facts.isEjectable == true
            && facts.deviceProtocol.map(WritableMountExecutor.externalProtocols.contains) == true
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
