import NTFSLiteCore

/// UI-side record of completed helper requests. It never grants mutation authority:
/// the helper re-reads every system fact for each request.
public struct WriteInteractionLedger: Sendable {
    public private(set) var writableVolumes: Set<VolumeInstanceID> = []
    public private(set) var unresolvedDisks: Set<PhysicalDiskID> = []

    public init() {}

    public func canStartOperation(on disk: DiskInstanceID) -> Bool {
        !unresolvedDisks.contains(disk.physicalDiskID)
    }

    public mutating func recordEnable(_ outcome: WriteOutcome, for volume: VolumeInstanceID) {
        switch outcome {
        case .writingEnabled:
            writableVolumes.insert(volume)
        case .needsRefresh:
            unresolvedDisks.insert(volume.diskInstanceID.physicalDiskID)
            writableVolumes.remove(volume)
        case .ejected, .refused:
            break
        }
    }

    public mutating func recordEject(_ outcome: WriteOutcome, for disk: DiskInstanceID) {
        switch outcome {
        case .refused(.helperUnavailable), .refused(.helperVersionMismatch),
             .refused(.identityInvalid),
             .refused(.diskBusy), .refused(.notConfirmed), .refused(.requestRejected):
            // These are known to stop before an unmount is delivered.
            break
        case .ejected:
            writableVolumes = writableVolumes.filter { $0.diskInstanceID != disk }
        case .needsRefresh, .refused(.release), .refused(.unknownStage),
             .refused(.mount), .writingEnabled:
            // The whole-disk unmount may have changed sibling mounts.
            writableVolumes = writableVolumes.filter { $0.diskInstanceID != disk }
            unresolvedDisks.insert(disk.physicalDiskID)
        case .refused(.helperTimedOut), .refused(.invalidResponse):
            writableVolumes = writableVolumes.filter { $0.diskInstanceID != disk }
            unresolvedDisks.insert(disk.physicalDiskID)
        }
    }

    public mutating func reconcileObservedDisks(
        _ observedDisks: Set<DiskInstanceID>,
        coverageVerified: Bool
    ) {
        guard coverageVerified else { return }
        writableVolumes = writableVolumes.filter { observedDisks.contains($0.diskInstanceID) }
        // A refreshed inventory cannot prove a timed-out helper has stopped.
        // Its disk remains blocked for this app session.
    }
}
