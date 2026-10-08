import Darwin
import Foundation
import NTFSLiteHelperProtocol

/// Fresh IOMedia facts for one object. A partition's parent is the whole-disk
/// IOMedia registry entry, not a reusable BSD name.
public struct HelperObservedMedia: Equatable, Sendable {
    public let bsdName: String
    public let registryEntryID: UInt64
    public let parentRegistryEntryID: UInt64?
    public let isWholeDisk: Bool
    public let mediaUUID: String?
    public let content: String?
    public let contentHint: String?

    public init(
        bsdName: String, registryEntryID: UInt64, parentRegistryEntryID: UInt64?,
        isWholeDisk: Bool, mediaUUID: String?, content: String?, contentHint: String?
    ) {
        self.bsdName = bsdName
        self.registryEntryID = registryEntryID
        self.parentRegistryEntryID = parentRegistryEntryID
        self.isWholeDisk = isWholeDisk
        self.mediaUUID = mediaUUID
        self.content = content
        self.contentHint = contentHint
    }
}

/// An independently enumerated, settled view of the selected physical media.
public struct HelperMediaTopology: Equatable, Sendable {
    public let disk: HelperObservedMedia
    public let partitions: [HelperObservedMedia]

    public init(disk: HelperObservedMedia, partitions: [HelperObservedMedia]) {
        self.disk = disk
        self.partitions = partitions
    }
}

/// The live reader samples the entire selected IOMedia topology twice. Any
/// change, missing fact or unreadable sample leaves it unverified.
public enum HelperMediaTopologySettlement {
    public static func settled(
        maximumSamples: Int = 6,
        sample: () -> HelperMediaTopology?
    ) -> HelperMediaTopology? {
        var previous: HelperMediaTopology?
        for _ in 0..<max(2, maximumSamples) {
            guard let current = sample() else { return nil }
            if current == previous { return current }
            previous = current
        }
        return nil
    }
}

/// A DA mount path can have a virtual FSKit source after our driver takes
/// ownership. The virtual source is accepted only when that driver is proven
/// to own this exact partition and mount point.
public enum HelperMountSourceBinding {
    public static func accepts(
        source: String, devicePath: String, mountPoint: String,
        ownedMounts: [HelperOwnedMount]?, isFSKitPlaceholder: Bool
    ) -> Bool {
        if source == devicePath { return true }
        guard isFSKitPlaceholder,
              source.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil,
              let ownedMounts, ownedMounts.count == 1,
              ownedMounts[0].mountPoint == mountPoint
        else { return false }
        return true
    }
}

public struct HelperProcessInventorySample: Sendable {
    public let reportedCount: Int
    public let capacity: Int
    public let processIDs: [Int32]

    public init(reportedCount: Int, capacity: Int, processIDs: [Int32]) {
        self.reportedCount = reportedCount
        self.capacity = capacity
        self.processIDs = processIDs
    }
}

/// A full PID list is required before the helper may conclude no owned FSKit
/// mount exists. Two sets must agree; a full buffer may have been truncated.
public enum HelperProcessInventorySettlement {
    public static func settled(sample: () -> HelperProcessInventorySample?) -> [Int32]? {
        guard let first = validated(sample()), let second = validated(sample()), first == second else { return nil }
        return first
    }

    private static func validated(_ sample: HelperProcessInventorySample?) -> [Int32]? {
        guard let sample, sample.reportedCount > 0,
              sample.reportedCount < sample.capacity,
              sample.reportedCount <= sample.processIDs.count
        else { return nil }
        let ids = Array(sample.processIDs.prefix(sample.reportedCount))
        let positiveIDs = ids.filter { $0 > 0 }
        guard Set(positiveIDs).count == positiveIDs.count else { return nil }
        return positiveIDs.sorted()
    }
}

public enum HelperProcessInspectionPolicy {
    public static func mayIgnoreUnreadableProcess(errno code: Int32, confirmedZombie: Bool? = nil) -> Bool {
        code == ESRCH || (code == 0 && confirmedZombie == true)
    }
}

public enum HelperDiskPresencePolicy {
    public static func isPresent(
        deviceNodeExists: Bool?, bsdNameInRegistry: Bool?,
        requestedEntryInRegistry: Bool?, diskArbitrationHasDisk: Bool?
    ) -> Bool? {
        let evidence = [deviceNodeExists, bsdNameInRegistry, requestedEntryInRegistry, diskArbitrationHasDisk]
        if evidence.contains(where: { $0 == true }) { return true }
        return evidence.allSatisfy { $0 == false } ? false : nil
    }
}

public enum HelperMountTableSnapshotPolicy {
    public static func isComplete(
        initialCount: Int, copiedCount: Int, countAfterRead: Int, capacity: Int
    ) -> Bool {
        initialCount >= 0 && copiedCount >= 0 && countAfterRead >= 0 && capacity > 0
            && initialCount < capacity && copiedCount < capacity && countAfterRead < capacity
            && initialCount == copiedCount && copiedCount == countAfterRead
    }
}

public protocol HelperMediaTopologyReading: Sendable {
    func volumeFacts(bsdName: String) async -> HelperVolumeFacts?
    func mediaTopology(diskBSDName: String) async -> HelperMediaTopology?
    func ownedFSKitMounts(devicePath: String) async -> [HelperOwnedMount]?
}

enum HelperTopologyFailure: Error {
    case factsUnavailable
    case targetMismatch
    case notExternalRemovable
    case ambiguousMount
    case siblingMounted
}

struct HelperVerifiedPartition: Sendable {
    let bsdName: String
    let registryEntryID: UInt64
    let facts: HelperVolumeFacts
    let ownedMounts: [HelperOwnedMount]
}

enum HelperTopologyVerifier {
    static func verify(
        _ target: HelperDiskInstanceIdentity,
        selectedVolumeBSDName: String? = nil,
        system: any HelperMediaTopologyReading
    ) async -> Result<[HelperVerifiedPartition], HelperTopologyFailure> {
        let diskName = target.physicalDiskBSDName
        guard let first = await system.mediaTopology(diskBSDName: diskName) else {
            return .failure(.factsUnavailable)
        }
        guard first.disk.bsdName == diskName,
              first.disk.isWholeDisk,
              first.disk.registryEntryID == target.registryEntryID,
              first.disk.content == target.mediaContent,
              first.disk.parentRegistryEntryID == nil,
              first.partitions.count == target.partitions.count,
              first.partitions.map(\.bsdName) == target.partitions.map(\.bsdName)
        else { return .failure(.targetMismatch) }

        if let selectedVolumeBSDName,
           target.partitions.first(where: { $0.kind == .ntfsTarget })?.bsdName != selectedVolumeBSDName {
            return .failure(.targetMismatch)
        }
        guard let diskFacts = await system.volumeFacts(bsdName: diskName) else {
            return .failure(.factsUnavailable)
        }
        guard diskFacts.bsdName == diskName,
              diskFacts.wholeDiskBSDName == diskName,
              diskFacts.isWholeDisk == true,
              diskFacts.mediaContent == target.mediaContent
        else { return .failure(.targetMismatch) }
        guard isExternalRemovable(diskFacts) else {
            return .failure(.notExternalRemovable)
        }

        var verified: [HelperVerifiedPartition] = []
        for (expected, observed) in zip(target.partitions, first.partitions) {
            let observedContent = observed.content?.lowercased()
            guard observed.bsdName == expected.bsdName,
                  !observed.isWholeDisk,
                  observed.parentRegistryEntryID == target.registryEntryID,
                  observed.registryEntryID == expected.registryEntryID,
                  observed.mediaUUID?.lowercased() == expected.mediaUUID,
                  observed.contentHint?.lowercased() == expected.contentHint,
                  observedContent != nil
            else { return .failure(.targetMismatch) }
            guard let facts = await system.volumeFacts(bsdName: expected.bsdName) else {
                return .failure(.factsUnavailable)
            }
            guard facts.bsdName == expected.bsdName,
                  facts.wholeDiskBSDName == diskName,
                  facts.isWholeDisk == false,
                  facts.mediaUUID?.lowercased() == expected.mediaUUID,
                  facts.mediaContent?.lowercased() == observedContent
            else { return .failure(.targetMismatch) }
            guard isExternalRemovable(facts) else {
                return .failure(.notExternalRemovable)
            }
            guard facts.isInternal == diskFacts.isInternal,
                  facts.isRemovable == diskFacts.isRemovable,
                  facts.isEjectable == diskFacts.isEjectable,
                  facts.deviceProtocol == diskFacts.deviceProtocol
            else { return .failure(.targetMismatch) }
            guard let owned = await system.ownedFSKitMounts(devicePath: "/dev/" + expected.bsdName) else {
                return .failure(.factsUnavailable)
            }
            guard owned.count <= 1 else { return .failure(.ambiguousMount) }
            if let ownedMount = owned.first, let mountPoint = facts.mountPoint,
               !mountPoint.isEmpty, ownedMount.mountPoint != mountPoint {
                return .failure(.ambiguousMount)
            }
            if expected.kind == .efiSystem {
                guard facts.fileSystemName?.lowercased() == "msdos",
                      observedContent == expected.contentHint
                else { return .failure(.targetMismatch) }
                guard facts.mountPoint == nil, owned.isEmpty else {
                    return .failure(.siblingMounted)
                }
            } else {
                // Content Hint proves GPT Basic Data; Content may have been
                // refined by the NTFS probe after IOMedia was created.
                guard observedContent == expected.contentHint || observedContent == "windows_ntfs" else {
                    return .failure(.targetMismatch)
                }
                if let nativeMountPoint = facts.mountPoint,
                   !nativeMountPoint.isEmpty, owned.isEmpty,
                   facts.fileSystemName?.lowercased() != "ntfs" {
                    return .failure(.targetMismatch)
                }
            }
            verified.append(HelperVerifiedPartition(
                bsdName: expected.bsdName, registryEntryID: expected.registryEntryID,
                facts: facts, ownedMounts: owned
            ))
        }
        // DA reads and process inspection are asynchronous. Detect a topology
        // replacement that happened while the preflight was collecting them.
        guard await system.mediaTopology(diskBSDName: diskName) == first else {
            return .failure(.targetMismatch)
        }
        return .success(verified)
    }

    static func isExternalRemovable(_ facts: HelperVolumeFacts) -> Bool {
        facts.isInternal == false && facts.isRemovable == true && facts.isEjectable == true
            && facts.deviceProtocol.map(WritableMountExecutor.externalProtocols.contains) == true
    }
}
