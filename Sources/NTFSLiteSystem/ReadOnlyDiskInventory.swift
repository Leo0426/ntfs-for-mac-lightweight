import NTFSLiteCore

public struct MountTableSnapshotProvider: Sendable {
    private let loadSnapshot: @Sendable () throws -> SystemMountTableSnapshot

    public init(_ loadSnapshot: @escaping @Sendable () throws -> SystemMountTableSnapshot) {
        self.loadSnapshot = loadSnapshot
    }

    public func currentSnapshot() throws -> SystemMountTableSnapshot {
        try loadSnapshot()
    }

    public static let live = MountTableSnapshotProvider {
        try SystemMountTableReader().currentSnapshot()
    }
}

public enum DiskInventoryIssue: Equatable, Sendable {
    case initialEnumerationPending
    case enumerationCoverageUnverified
    case eventSourceUnavailable
    case unidentifiedDiskEvent
    case mountTableReadFailed
    case missingPhysicalDiskDescription(childBSDName: String)
    case unknownDiskKind(bsdName: String)
    case physicalParentMismatch(bsdName: String)
    case missingPhysicalLocation(bsdName: String)
    case missingEjectability(bsdName: String)
    case missingRemovability(bsdName: String)
    case contradictoryEjectability(bsdName: String)
    case childLocationMismatch(bsdName: String)
    case duplicateMountTableEntry(bsdName: String)
}

public struct ReadOnlyPhysicalDiskRecord: Equatable, Sendable {
    public let instanceID: DiskInstanceID
    public let description: DiskArbitrationDescription
    public let volumes: [ReadOnlyVolumeRecord]
    public let issues: [DiskInventoryIssue]

    public init(
        instanceID: DiskInstanceID,
        description: DiskArbitrationDescription,
        volumes: [ReadOnlyVolumeRecord],
        issues: [DiskInventoryIssue]
    ) {
        self.instanceID = instanceID
        self.description = description
        self.volumes = volumes
        self.issues = issues
    }

    public var isComplete: Bool {
        issues.isEmpty && volumes.allSatisfy(\.isComplete)
    }

    public var safetySnapshot: PhysicalDiskSafetySnapshot? {
        guard let isEjectable = description.isEjectable,
              let isRemovable = description.isRemovable
        else {
            return nil
        }
        let snapshot = PhysicalDiskSafetySnapshot(
            diskInstanceID: instanceID,
            ejectability: isEjectable ? .ejectable : .notEjectable,
            removability: isRemovable ? .removable : .notRemovable
        )
        return snapshot.isComplete ? snapshot : nil
    }
}

public struct ReadOnlyCoordinatorInventory: Equatable, Sendable {
    public let volumeSnapshots: [VolumeSnapshot]
    public let physicalDiskSafetySnapshots: [PhysicalDiskSafetySnapshot]

    public init(
        volumeSnapshots: [VolumeSnapshot],
        physicalDiskSafetySnapshots: [PhysicalDiskSafetySnapshot]
    ) {
        self.volumeSnapshots = volumeSnapshots
        self.physicalDiskSafetySnapshots = physicalDiskSafetySnapshots
    }
}

public struct DiskInventoryObservation: Equatable, Sendable {
    public let physicalDisks: [ReadOnlyPhysicalDiskRecord]
    public let issues: [DiskInventoryIssue]

    public init(
        physicalDisks: [ReadOnlyPhysicalDiskRecord],
        issues: [DiskInventoryIssue]
    ) {
        self.physicalDisks = physicalDisks
        self.issues = issues
    }

    public var isComplete: Bool {
        issues.isEmpty && physicalDisks.allSatisfy(\.isComplete)
    }

    public var volumeSnapshots: [VolumeSnapshot]? {
        guard isComplete else {
            return nil
        }
        return physicalDisks.flatMap { disk in
            disk.volumes.compactMap(\.snapshot)
        }
    }

    public var coordinatorInventory: ReadOnlyCoordinatorInventory? {
        guard let volumeSnapshots else {
            return nil
        }
        let safetySnapshots = physicalDisks.compactMap(\.safetySnapshot)
        guard safetySnapshots.count == physicalDisks.count else {
            return nil
        }
        return ReadOnlyCoordinatorInventory(
            volumeSnapshots: volumeSnapshots,
            physicalDiskSafetySnapshots: safetySnapshots
        )
    }
}

public protocol DiskInventoryReading: Sendable {
    func currentInventory() async -> DiskInventoryObservation
}

public actor ReadOnlyDiskInventory: DiskInventoryReading {
    private enum EnumerationCoverage {
        case pending
        case quietSettled
        case verifiedComplete
    }

    private let mountTableProvider: MountTableSnapshotProvider
    private var descriptionsByBSDName: [String: DiskArbitrationDescription] = [:]
    private var knownWholeDiskBSDNames: Set<String> = []
    private var activeGenerations: [PhysicalDiskID: MediaGeneration] = [:]
    private var nextGenerationRawValue: UInt64 = 1
    private var enumerationCoverage: EnumerationCoverage = .pending
    private var receivedUnidentifiedDiskEvent = false

    public init(mountTableProvider: MountTableSnapshotProvider = .live) {
        self.mountTableProvider = mountTableProvider
    }

    public func handle(_ event: DiskArbitrationEvent) {
        // Network volumes are not IOMedia-backed physical disks and therefore
        // are outside both this inventory and its independent IOKit coverage.
        // Only Apple's explicit positive flag permits exclusion; an absent or
        // false flag retains the existing fail-closed identity behavior.
        guard event.description.isNetworkVolume != true else {
            return
        }
        guard let bsdName = normalized(event.description.bsdName) else {
            receivedUnidentifiedDiskEvent = true
            return
        }

        switch event.kind {
        case .appeared, .descriptionChanged:
            descriptionsByBSDName[bsdName] = event.description
            if event.description.isWholeDisk == true {
                knownWholeDiskBSDNames.insert(bsdName)
                _ = generation(for: PhysicalDiskID(rawValue: bsdName))
            }
        case .disappeared:
            let cachedDescription = descriptionsByBSDName[bsdName]
            let disappearingDescription = cachedDescription ?? event.description
            descriptionsByBSDName.removeValue(forKey: bsdName)

            if disappearingDescription.isWholeDisk == true
                || knownWholeDiskBSDNames.contains(bsdName)
            {
                let physicalDiskID = PhysicalDiskID(rawValue: bsdName)
                knownWholeDiskBSDNames.remove(bsdName)
                activeGenerations.removeValue(forKey: physicalDiskID)
                descriptionsByBSDName = descriptionsByBSDName.filter { _, description in
                    normalized(description.physicalDiskBSDName) != bsdName
                }
            }
        }
    }

    @discardableResult
    package func verifyEnumerationCoverage(
        using snapshot: IOMediaEnumerationSnapshot
    ) -> Bool {
        let diskArbitrationBSDNames = Set(descriptionsByBSDName.keys)
        guard snapshot.bsdNames == diskArbitrationBSDNames else {
            enumerationCoverage = .quietSettled
            return false
        }
        enumerationCoverage = .verifiedComplete
        return true
    }

    package func markEnumerationPending() {
        enumerationCoverage = .pending
    }

    package func markEnumerationSettledWithoutCoverage() {
        enumerationCoverage = .quietSettled
    }

    public func currentInventory() -> DiskInventoryObservation {
        let mountTable: SystemMountTableSnapshot?
        var topLevelIssues: [DiskInventoryIssue] = []
        let enumerationCoverageIsVerified: Bool
        switch enumerationCoverage {
        case .pending:
            enumerationCoverageIsVerified = false
            topLevelIssues.append(.initialEnumerationPending)
        case .quietSettled:
            enumerationCoverageIsVerified = false
            topLevelIssues.append(.enumerationCoverageUnverified)
        case .verifiedComplete:
            enumerationCoverageIsVerified = true
            break
        }
        if receivedUnidentifiedDiskEvent {
            topLevelIssues.append(.unidentifiedDiskEvent)
        }
        let topologyAllowsCandidates = enumerationCoverageIsVerified
            && !receivedUnidentifiedDiskEvent
        do {
            mountTable = try mountTableProvider.currentSnapshot()
        } catch {
            mountTable = nil
            topLevelIssues.append(.mountTableReadFailed)
        }

        let wholeDisks = descriptionsByBSDName.values
            .filter { $0.isWholeDisk == true }
            .sorted { normalized($0.bsdName) ?? "" < normalized($1.bsdName) ?? "" }
        var physicalDisks: [ReadOnlyPhysicalDiskRecord] = []

        for wholeDisk in wholeDisks {
            guard let bsdName = normalized(wholeDisk.bsdName) else {
                continue
            }
            let physicalDiskID = PhysicalDiskID(rawValue: bsdName)
            let mediaGeneration = generation(for: physicalDiskID)
            var diskIssues = physicalDiskIssues(for: wholeDisk, bsdName: bsdName)
            let wholeDiskIdentityBlocksCandidates = diskIssues.contains { issue in
                switch issue {
                case .physicalParentMismatch, .missingPhysicalLocation:
                    true
                default:
                    false
                }
            }

            let childDescriptions = descriptionsByBSDName.values
                .filter {
                    $0.isWholeDisk == false
                        && normalized($0.physicalDiskBSDName) == bsdName
                }
                .sorted { normalized($0.bsdName) ?? "" < normalized($1.bsdName) ?? "" }
            var volumeRecords: [ReadOnlyVolumeRecord] = []

            for child in childDescriptions {
                guard let childBSDName = normalized(child.bsdName),
                      let volumeEvidence = child.volumeEvidence
                else {
                    continue
                }

                let childLocationConflicts = child.isInternal != wholeDisk.isInternal
                if childLocationConflicts {
                    diskIssues.append(.childLocationMismatch(bsdName: childBSDName))
                }

                let matchingMountRecords = mountTable?.records.filter {
                    $0.sourceBSDName == childBSDName
                } ?? []
                if matchingMountRecords.count > 1 {
                    diskIssues.append(.duplicateMountTableEntry(bsdName: childBSDName))
                }

                var record = ReadOnlyVolumeMapper.map(
                    volumeEvidence,
                    mount: matchingMountRecords.count == 1
                        ? matchingMountRecords[0].volumeEvidence
                        : nil,
                    mediaGeneration: mediaGeneration
                )
                if childLocationConflicts
                    || wholeDiskIdentityBlocksCandidates
                    || !topologyAllowsCandidates
                {
                    record = removingCandidate(from: record)
                }
                if mountTable == nil {
                    record = invalidating(
                        record,
                        with: .mountTableReadFailed
                    )
                } else if matchingMountRecords.count > 1 {
                    record = invalidating(
                        record,
                        with: .duplicateMountTableEntry
                    )
                }
                volumeRecords.append(record)
            }

            physicalDisks.append(
                ReadOnlyPhysicalDiskRecord(
                    instanceID: DiskInstanceID(
                        physicalDiskID: physicalDiskID,
                        mediaGeneration: mediaGeneration
                    ),
                    description: wholeDisk,
                    volumes: volumeRecords,
                    issues: deduplicated(diskIssues)
                )
            )
        }

        let knownWholeDiskNames = Set(wholeDisks.compactMap { normalized($0.bsdName) })
        for description in descriptionsByBSDName.values {
            guard let bsdName = normalized(description.bsdName) else {
                continue
            }
            if description.isWholeDisk == nil {
                topLevelIssues.append(.unknownDiskKind(bsdName: bsdName))
            } else if description.isWholeDisk == false {
                guard let parent = normalized(description.physicalDiskBSDName),
                      knownWholeDiskNames.contains(parent)
                else {
                    topLevelIssues.append(
                        .missingPhysicalDiskDescription(childBSDName: bsdName)
                    )
                    continue
                }
            }
        }

        if !topLevelIssues.isEmpty {
            physicalDisks = physicalDisks.map { disk in
                ReadOnlyPhysicalDiskRecord(
                    instanceID: disk.instanceID,
                    description: disk.description,
                    volumes: disk.volumes.map(removingCandidate),
                    issues: disk.issues
                )
            }
        }

        return DiskInventoryObservation(
            physicalDisks: physicalDisks,
            issues: deduplicated(topLevelIssues)
        )
    }

    private func removingCandidate(
        from record: ReadOnlyVolumeRecord
    ) -> ReadOnlyVolumeRecord {
        ReadOnlyVolumeRecord(
            evidence: record.evidence,
            candidate: nil,
            snapshot: record.snapshot,
            mountObservation: record.mountObservation,
            issues: record.issues
        )
    }

    private func generation(for physicalDiskID: PhysicalDiskID) -> MediaGeneration {
        if let activeGeneration = activeGenerations[physicalDiskID] {
            return activeGeneration
        }
        let generation = MediaGeneration(rawValue: nextGenerationRawValue)
        nextGenerationRawValue += 1
        activeGenerations[physicalDiskID] = generation
        return generation
    }

    private func physicalDiskIssues(
        for description: DiskArbitrationDescription,
        bsdName: String
    ) -> [DiskInventoryIssue] {
        var issues: [DiskInventoryIssue] = []
        if normalized(description.physicalDiskBSDName) != bsdName {
            issues.append(.physicalParentMismatch(bsdName: bsdName))
        }
        if description.isInternal == nil {
            issues.append(.missingPhysicalLocation(bsdName: bsdName))
        }
        if description.isEjectable == nil {
            issues.append(.missingEjectability(bsdName: bsdName))
        }
        if description.isRemovable == nil {
            issues.append(.missingRemovability(bsdName: bsdName))
        }
        if description.isEjectable == true, description.isRemovable == false {
            issues.append(.contradictoryEjectability(bsdName: bsdName))
        }
        return issues
    }

    private func invalidating(
        _ record: ReadOnlyVolumeRecord,
        with issue: ReadOnlyObservationIssue
    ) -> ReadOnlyVolumeRecord {
        ReadOnlyVolumeRecord(
            evidence: record.evidence,
            snapshot: nil,
            mountObservation: nil,
            issues: deduplicated(record.issues + [issue])
        )
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func deduplicated<T: Equatable>(_ values: [T]) -> [T] {
        values.reduce(into: []) { result, value in
            if !result.contains(value) {
                result.append(value)
            }
        }
    }
}
