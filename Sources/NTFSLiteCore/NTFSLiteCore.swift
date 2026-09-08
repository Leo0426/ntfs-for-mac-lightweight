import Foundation

public struct VolumeID: Equatable, Hashable, Sendable {
    public let uuid: String
    public let bsdName: String

    public init(uuid: String, bsdName: String) {
        self.uuid = uuid
        self.bsdName = bsdName
    }
}

public struct PhysicalDiskID: Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct MediaGeneration: Equatable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct DiskInstanceID: Equatable, Hashable, Sendable {
    public let physicalDiskID: PhysicalDiskID
    public let mediaGeneration: MediaGeneration

    public init(
        physicalDiskID: PhysicalDiskID,
        mediaGeneration: MediaGeneration
    ) {
        self.physicalDiskID = physicalDiskID
        self.mediaGeneration = mediaGeneration
    }
}

public enum PhysicalDiskEjectability: Equatable, Sendable {
    case ejectable
    case notEjectable
    case unknown
}

public enum PhysicalDiskRemovability: Equatable, Sendable {
    case removable
    case notRemovable
    case unknown
}

public struct PhysicalDiskSafetySnapshot: Equatable, Sendable {
    public let diskInstanceID: DiskInstanceID
    public let ejectability: PhysicalDiskEjectability
    public let removability: PhysicalDiskRemovability

    public init(
        diskInstanceID: DiskInstanceID,
        ejectability: PhysicalDiskEjectability,
        removability: PhysicalDiskRemovability
    ) {
        self.diskInstanceID = diskInstanceID
        self.ejectability = ejectability
        self.removability = removability
    }

    public var isComplete: Bool {
        guard ejectability != .unknown, removability != .unknown else {
            return false
        }
        // Apple IOMedia defines software ejectability as implying
        // removability. The inverse combination is contradictory evidence.
        return !(ejectability == .ejectable && removability == .notRemovable)
    }

    fileprivate var permitsSoftwareEject: Bool {
        isComplete && ejectability == .ejectable && removability == .removable
    }
}

public struct VolumeInstanceID: Equatable, Hashable, Sendable {
    public let volumeID: VolumeID
    public let diskInstanceID: DiskInstanceID

    public init(volumeID: VolumeID, diskInstanceID: DiskInstanceID) {
        self.volumeID = volumeID
        self.diskInstanceID = diskInstanceID
    }
}

public struct MediaInstanceMismatch: Equatable, Sendable {
    public let expected: DiskInstanceID
    public let observed: DiskInstanceID

    public init(expected: DiskInstanceID, observed: DiskInstanceID) {
        self.expected = expected
        self.observed = observed
    }
}

public enum FileSystemKind: Equatable, Sendable {
    case ntfs
    case other
}

public enum VolumeLocation: Equatable, Sendable {
    case external
    case `internal`
}

public enum VolumeRole: Equatable, Sendable {
    case data
    /// Protected by a trusted product boundary without claiming an exact
    /// Windows or Boot Camp identity.
    case protected
    case bootCamp

    public var isProtected: Bool {
        self != .data
    }
}

/// Trusted role classification supplied by a read-only evidence boundary.
/// Disk Arbitration location facts may establish `protected`, but an
/// external volume remains `unknown` until a separate trusted source proves
/// that it is ordinary data media.
public enum VolumeRoleEvidence: Equatable, Sendable {
    case trustedData
    case protected
    case unknown
    case conflicting
}

public enum VolumeHealth: Equatable, Sendable {
    case clean
    case dirty
    case hibernated
    case unknown
}

public enum MountAccess: Equatable, Sendable {
    case unmounted
    case readOnly
    case readWrite
}

/// Fully validated read-only facts whose data/system purpose remains unknown.
/// This value intentionally carries no role, health, operation, or mutation
/// capability and cannot be used in place of `VolumeSnapshot`.
public struct ReadOnlyVolumeCandidate: Equatable, Sendable {
    public let id: VolumeID
    public let physicalDiskID: PhysicalDiskID
    public let mediaGeneration: MediaGeneration
    public let displayName: String
    public let fileSystem: FileSystemKind
    public let location: VolumeLocation
    public let mountAccess: MountAccess

    public init(
        id: VolumeID,
        physicalDiskID: PhysicalDiskID,
        mediaGeneration: MediaGeneration,
        displayName: String,
        fileSystem: FileSystemKind,
        location: VolumeLocation,
        mountAccess: MountAccess
    ) {
        self.id = id
        self.physicalDiskID = physicalDiskID
        self.mediaGeneration = mediaGeneration
        self.displayName = displayName
        self.fileSystem = fileSystem
        self.location = location
        self.mountAccess = mountAccess
    }

    public var diskInstanceID: DiskInstanceID {
        DiskInstanceID(
            physicalDiskID: physicalDiskID,
            mediaGeneration: mediaGeneration
        )
    }

    public var instanceID: VolumeInstanceID {
        VolumeInstanceID(volumeID: id, diskInstanceID: diskInstanceID)
    }
}

public struct VolumeSnapshot: Equatable, Sendable {
    public let id: VolumeID
    public let physicalDiskID: PhysicalDiskID
    public let mediaGeneration: MediaGeneration
    public let displayName: String
    public let fileSystem: FileSystemKind
    public let location: VolumeLocation
    public let role: VolumeRole
    public let health: VolumeHealth
    public let mountAccess: MountAccess

    public init(
        id: VolumeID,
        physicalDiskID: PhysicalDiskID,
        mediaGeneration: MediaGeneration,
        displayName: String,
        fileSystem: FileSystemKind,
        location: VolumeLocation,
        role: VolumeRole,
        health: VolumeHealth,
        mountAccess: MountAccess
    ) {
        self.id = id
        self.physicalDiskID = physicalDiskID
        self.mediaGeneration = mediaGeneration
        self.displayName = displayName
        self.fileSystem = fileSystem
        self.location = location
        self.role = role
        self.health = health
        self.mountAccess = mountAccess
    }

    public var diskInstanceID: DiskInstanceID {
        DiskInstanceID(
            physicalDiskID: physicalDiskID,
            mediaGeneration: mediaGeneration
        )
    }

    public var instanceID: VolumeInstanceID {
        VolumeInstanceID(volumeID: id, diskInstanceID: diskInstanceID)
    }
}

public struct OperationID: Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum ObservedMountBackend: Equatable, Sendable {
    case fsKit
    case kernelExtension
    case unknown
}

public enum MountVerificationFailure: Equatable, Sendable {
    case wrongVolume
    case observationIncomplete
    case sourceDeviceMismatch
    case notReadWrite
    case unexpectedBackend
    case invalidMountPoint
    case untrustedMountPath
}

public enum SafeMountPolicy: Equatable, Sendable {
    case fsKitCurrentUserNoRecovery
}

public struct MountPlan: Equatable, Sendable {
    public let operationID: OperationID
    public let target: VolumeInstanceID
    public let policy: SafeMountPolicy

    package init(
        operationID: OperationID,
        target: VolumeInstanceID,
        policy: SafeMountPolicy
    ) {
        self.operationID = operationID
        self.target = target
        self.policy = policy
    }
}

public struct MountObservation: Equatable, Sendable {
    public let volumeID: VolumeID
    public let physicalDiskID: PhysicalDiskID
    public let mediaGeneration: MediaGeneration
    public let access: MountAccess
    public let backend: ObservedMountBackend
    public let mountPoint: String
    public let isComplete: Bool
    public let sourceBSDName: String
    public let isCanonical: Bool
    public let isSymlink: Bool

    package init(
        volumeID: VolumeID,
        physicalDiskID: PhysicalDiskID,
        mediaGeneration: MediaGeneration,
        access: MountAccess,
        backend: ObservedMountBackend,
        mountPoint: String,
        isComplete: Bool,
        sourceBSDName: String,
        isCanonical: Bool,
        isSymlink: Bool
    ) {
        self.volumeID = volumeID
        self.physicalDiskID = physicalDiskID
        self.mediaGeneration = mediaGeneration
        self.access = access
        self.backend = backend
        self.mountPoint = mountPoint
        self.isComplete = isComplete
        self.sourceBSDName = sourceBSDName
        self.isCanonical = isCanonical
        self.isSymlink = isSymlink
    }
}

public struct WriteMutationReconciliationObservation: Equatable, Sendable {
    public let snapshot: VolumeSnapshot
    public let isComplete: Bool

    public init(snapshot: VolumeSnapshot, isComplete: Bool) {
        self.snapshot = snapshot
        self.isComplete = isComplete
    }
}

public enum EjectInspectionPhase: Equatable, Sendable {
    case afterUnmount
    case afterEject
}

public enum DiskPresence: Equatable, Sendable {
    case present
    case absent
}

public struct ChildVolumeObservation: Equatable, Sendable {
    public let volumeID: VolumeID
    public let mountAccess: MountAccess

    public init(volumeID: VolumeID, mountAccess: MountAccess) {
        self.volumeID = volumeID
        self.mountAccess = mountAccess
    }
}

public struct PhysicalDiskObservation: Equatable, Sendable {
    public let physicalDiskID: PhysicalDiskID
    public let mediaGeneration: MediaGeneration
    public let presence: DiskPresence
    public let isComplete: Bool
    public let childVolumes: [ChildVolumeObservation]

    public init(
        physicalDiskID: PhysicalDiskID,
        mediaGeneration: MediaGeneration,
        presence: DiskPresence,
        isComplete: Bool,
        childVolumes: [ChildVolumeObservation]
    ) {
        self.physicalDiskID = physicalDiskID
        self.mediaGeneration = mediaGeneration
        self.presence = presence
        self.isComplete = isComplete
        self.childVolumes = childVolumes
    }
}

package struct DiskMutationObservation: Equatable, Sendable {
    package let target: DiskInstanceID
    package let isComplete: Bool
    package let childSnapshots: [VolumeSnapshot]
    package let physicalDiskSafety: PhysicalDiskSafetySnapshot?

    package init(
        target: DiskInstanceID,
        isComplete: Bool,
        childSnapshots: [VolumeSnapshot],
        physicalDiskSafety: PhysicalDiskSafetySnapshot? = nil
    ) {
        self.target = target
        self.isComplete = isComplete
        self.childSnapshots = childSnapshots
        self.physicalDiskSafety = physicalDiskSafety
    }
}

package struct VolumeMutationObservation: Equatable, Sendable {
    package let snapshot: VolumeSnapshot
    package let isComplete: Bool

    package init(snapshot: VolumeSnapshot, isComplete: Bool) {
        self.snapshot = snapshot
        self.isComplete = isComplete
    }
}

public enum EjectFailure: Equatable, Sendable {
    case busy
    case volumesStillMounted([VolumeID])
    case diskStillPresent
    case observationIncomplete
    case timedOut
    case cancelled
}

public enum EjectMutationStage: Equatable, Sendable {
    case unmountingPhysicalDisk
    case ejectingPhysicalDisk
}

public enum EjectBlockReason: Equatable, Sendable {
    case internalDisk
    case bootCampDisk
    case protectedDisk
    case protectedSibling
    case notEjectable
}

public enum WriteOperationStage: Equatable, Sendable {
    case unmountingReadOnly
    case inspectingSafety
    case mountingWrite
    case inspectingWriteMount
}

public enum WriteOperationFailure: Equatable, Sendable {
    case busy
    case permissionDenied
    case dependencyUnavailable
    case engineFailed
    case inspectionUnavailable
    case timedOut
    case cancelled
}

public enum VolumeEffect: Equatable, Sendable {
    case none
    case unmountStandard(operationID: OperationID, target: VolumeInstanceID)
    case unmountPhysicalDiskStandard(operationID: OperationID, target: DiskInstanceID)
    case inspectPhysicalDisk(
        operationID: OperationID,
        target: DiskInstanceID,
        phase: EjectInspectionPhase
    )
    case ejectPhysicalDiskStandard(operationID: OperationID, target: DiskInstanceID)
    case inspectSafetySnapshot(operationID: OperationID, target: VolumeInstanceID)
    case mountReadWrite(MountPlan)
    case inspectWriteMount(operationID: OperationID, target: VolumeInstanceID)
    case inspectWriteMutationReconciliation(
        operationID: OperationID,
        target: VolumeInstanceID
    )
    case inspectEjectMutationReconciliation(
        operationID: OperationID,
        target: DiskInstanceID,
        stage: EjectMutationStage
    )
}

package enum MutationTarget: Equatable, Sendable {
    case volume(VolumeInstanceID)
    case disk(DiskInstanceID)
}

package enum MutationCommand: Equatable, Sendable {
    case unmountVolumeStandard(operationID: OperationID, target: VolumeInstanceID)
    case mountWrite(MountPlan)
    case unmountDiskStandard(operationID: OperationID, target: DiskInstanceID)
    case ejectDiskStandard(operationID: OperationID, target: DiskInstanceID)
}

package enum MutationPreflightFailure: Equatable, Sendable {
    case targetChanged(expected: MutationTarget, observed: MutationTarget)
    case operationNotActive(expected: OperationID?, observed: OperationID)
    case effectNotExpected
    case setupNotReady([SetupIssue])
    case volumeObservationIncomplete
    case writeSafetyChanged(WriteBlockReason)
    case unexpectedMountAccess(expected: MountAccess, observed: MountAccess)
    case diskObservationIncomplete
    case ejectBlocked(EjectBlockReason)
    case ejectNotReady(EjectFailure)
}

package enum MutationExecutionResult: Equatable, Sendable {
    case executed
    case rejected(MutationPreflightFailure)
    case notMutation
}

package enum MountEngineTermination: Equatable, Sendable {
    case exited(terminationStatus: Int32)
    case timedOutAfterConfirmedQuiescence
    case cancelledAfterConfirmedQuiescence
    case terminationUnconfirmed

    fileprivate var hasConfirmedQuiescence: Bool {
        self != .terminationUnconfirmed
    }
}

package enum MutationFreshEvidenceRequirement: Equatable, Sendable {
    case volume(VolumeInstanceID)
    case wholeDisk(DiskInstanceID)
}

package struct MountEngineResult: Equatable, Sendable {
    package let termination: MountEngineTermination
    package let requiredFreshEvidence: MutationFreshEvidenceRequirement

    package init(
        termination: MountEngineTermination,
        requiredFreshEvidence: MutationFreshEvidenceRequirement
    ) {
        self.termination = termination
        self.requiredFreshEvidence = requiredFreshEvidence
    }
}

/// A package-only, fixed-semantic execution contract. Its only input is a
/// coordinator-issued `MutationCommand`; paths, arguments and command text do
/// not cross this boundary.
package struct MountEngine: Sendable {
    private let invoke: @Sendable (MutationCommand) async -> MountEngineTermination

    package init(
        _ invoke: @escaping @Sendable (MutationCommand) async -> MountEngineTermination
    ) {
        self.invoke = invoke
    }

    fileprivate func execute(_ command: MutationCommand) async -> MountEngineResult {
        MountEngineResult(
            termination: await invoke(command),
            requiredFreshEvidence: command.requiredFreshEvidence
        )
    }
}

package enum MountEngineExecutionResult: Equatable, Sendable {
    case executed(MountEngineResult)
    case rejected(MutationPreflightFailure)
    case notMutation
}

package enum MutationPreflightEvidence: Equatable, Sendable {
    case volume(VolumeMutationObservation)
    case disk(DiskMutationObservation)

    fileprivate var target: MutationTarget {
        switch self {
        case let .volume(observation):
            return .volume(observation.snapshot.instanceID)
        case let .disk(observation):
            return .disk(observation.target)
        }
    }
}

private enum MutationPreflight {
    static func command(for effect: VolumeEffect) -> MutationCommand? {
        switch effect {
        case let .unmountStandard(operationID, target):
            return .unmountVolumeStandard(operationID: operationID, target: target)
        case let .mountReadWrite(plan):
            return .mountWrite(plan)
        case let .unmountPhysicalDiskStandard(operationID, target):
            return .unmountDiskStandard(operationID: operationID, target: target)
        case let .ejectPhysicalDiskStandard(operationID, target):
            return .ejectDiskStandard(operationID: operationID, target: target)
        case .none, .inspectPhysicalDisk, .inspectSafetySnapshot, .inspectWriteMount,
            .inspectWriteMutationReconciliation, .inspectEjectMutationReconciliation:
            return nil
        }
    }

    static func validate(
        command: MutationCommand,
        evidence: MutationPreflightEvidence,
        setupAssessment: SetupAssessment?
    ) -> MutationPreflightFailure? {
        guard command.target == evidence.target else {
            return .targetChanged(expected: command.target, observed: evidence.target)
        }

        switch command {
        case .unmountVolumeStandard:
            guard let setupAssessment, setupAssessment.isReady else {
                return .setupNotReady(setupAssessment?.issues ?? [])
            }
            guard case let .volume(observation) = evidence else {
                return .targetChanged(expected: command.target, observed: evidence.target)
            }
            if let failure = validateWriteObservation(
                observation,
                expectedAccess: .readOnly
            ) {
                return failure
            }
        case .mountWrite:
            guard let setupAssessment, setupAssessment.isReady else {
                return .setupNotReady(setupAssessment?.issues ?? [])
            }
            guard case let .volume(observation) = evidence else {
                return .targetChanged(expected: command.target, observed: evidence.target)
            }
            if let failure = validateWriteObservation(
                observation,
                expectedAccess: .unmounted
            ) {
                return failure
            }
        case .unmountDiskStandard, .ejectDiskStandard:
            guard case let .disk(observation) = evidence else {
                return .targetChanged(expected: command.target, observed: evidence.target)
            }
            let childVolumeIDs = observation.childSnapshots.map(\.id)
            guard
                observation.isComplete,
                !observation.childSnapshots.isEmpty,
                Set(childVolumeIDs).count == childVolumeIDs.count,
                observation.childSnapshots.allSatisfy({ snapshot in
                    snapshot.diskInstanceID == observation.target
                })
            else {
                return .diskObservationIncomplete
            }
            if observation.childSnapshots.contains(where: { snapshot in
                snapshot.location == .internal || snapshot.role.isProtected
            }) {
                return .ejectBlocked(.protectedSibling)
            }
            guard let physicalDiskSafety = observation.physicalDiskSafety,
                  physicalDiskSafety.diskInstanceID == observation.target,
                  physicalDiskSafety.isComplete
            else {
                return .diskObservationIncomplete
            }
            guard physicalDiskSafety.permitsSoftwareEject else {
                return .ejectBlocked(.notEjectable)
            }
            if case .ejectDiskStandard = command {
                let mountedVolumeIDs = Set(
                    observation.childSnapshots
                        .filter { $0.mountAccess != .unmounted }
                        .map(\.id)
                )
                    .sorted { lhs, rhs in
                        if lhs.uuid != rhs.uuid {
                            return lhs.uuid < rhs.uuid
                        }
                        return lhs.bsdName < rhs.bsdName
                    }
                if !mountedVolumeIDs.isEmpty {
                    return .ejectNotReady(.volumesStillMounted(mountedVolumeIDs))
                }
            }
        }
        return nil
    }

    private static func validateWriteObservation(
        _ observation: VolumeMutationObservation,
        expectedAccess: MountAccess
    ) -> MutationPreflightFailure? {
        guard observation.isComplete else {
            return .volumeObservationIncomplete
        }
        if let reason = WriteSafetyPolicy.blockReason(for: observation.snapshot) {
            return .writeSafetyChanged(reason)
        }
        guard observation.snapshot.mountAccess == expectedAccess else {
            return .unexpectedMountAccess(
                expected: expectedAccess,
                observed: observation.snapshot.mountAccess
            )
        }
        return nil
    }

}

private extension MutationCommand {
    var operationID: OperationID {
        switch self {
        case let .unmountVolumeStandard(operationID, _),
            let .unmountDiskStandard(operationID, _),
            let .ejectDiskStandard(operationID, _):
            return operationID
        case let .mountWrite(plan):
            return plan.operationID
        }
    }

    var target: MutationTarget {
        switch self {
        case let .unmountVolumeStandard(_, target):
            return .volume(target)
        case let .mountWrite(plan):
            return .volume(plan.target)
        case let .unmountDiskStandard(_, target), let .ejectDiskStandard(_, target):
            return .disk(target)
        }
    }

    var physicalDiskID: PhysicalDiskID {
        switch target {
        case let .volume(target):
            return target.diskInstanceID.physicalDiskID
        case let .disk(target):
            return target.physicalDiskID
        }
    }

    var requiresWriteSetup: Bool {
        switch self {
        case .unmountVolumeStandard, .mountWrite:
            return true
        case .unmountDiskStandard, .ejectDiskStandard:
            return false
        }
    }

    var requiredFreshEvidence: MutationFreshEvidenceRequirement {
        switch self {
        case let .unmountVolumeStandard(_, target):
            return .volume(target)
        case let .mountWrite(plan):
            return .volume(plan.target)
        case let .unmountDiskStandard(_, target), let .ejectDiskStandard(_, target):
            return .wholeDisk(target)
        }
    }
}

public enum WorkflowResult: Equatable, Sendable {
    case accepted(VolumeEffect)
    case rejected(WorkflowRejection)
    case ignored
}

public enum WorkflowRejection: Equatable, Sendable {
    case writeBlocked(WriteBlockReason)
    case setupNotReady([SetupIssue])
    case ejectBlocked(EjectBlockReason)
    case operationInProgress
    case volumeUnavailable
    case mountVerificationFailed(MountVerificationFailure)
    case ejectFailed(EjectFailure)
    case mediaChanged(MediaInstanceMismatch)
    case writeOperationFailed(stage: WriteOperationStage, failure: WriteOperationFailure)
}

public enum WriteBlockReason: Equatable, Sendable {
    case windowsHibernated
    case dirtyFileSystem
    case healthUnknown
    case internalVolume
    case bootCampVolume
    case protectedVolume
    case unsupportedFileSystem
}

private enum WriteSafetyPolicy {
    static func blockReason(for snapshot: VolumeSnapshot) -> WriteBlockReason? {
        guard snapshot.fileSystem == .ntfs else {
            return .unsupportedFileSystem
        }
        if snapshot.role == .protected {
            return .protectedVolume
        }
        guard snapshot.role != .bootCamp else {
            return .bootCampVolume
        }
        guard snapshot.location == .external else {
            return .internalVolume
        }

        switch snapshot.health {
        case .clean:
            return nil
        case .dirty:
            return .dirtyFileSystem
        case .hibernated:
            return .windowsHibernated
        case .unknown:
            return .healthUnknown
        }
    }
}

public enum VolumeState: Equatable, Sendable {
    case readOnlyReady
    case unmountedReady
    case existingWriteMountUnverified(WriteBlockReason?)
    case unmountingForWrite
    case awaitingSafetySnapshot
    case mountingWrite
    case awaitingWriteVerification
    case writable
    case writeVerificationFailed(MountVerificationFailure)
    case unmountingForEject
    case awaitingUnmountVerification
    case ejecting
    case awaitingRemovalVerification
    case safeToRemove
    case ejectFailed(EjectFailure)
    case ejectBlocked(EjectBlockReason)
    case writeBlocked(WriteBlockReason)
    case mediaInvalidated(MediaInstanceMismatch)
    case mediaUnavailable
    case writeMutationQuiescencePending(
        stage: WriteOperationStage,
        failure: WriteOperationFailure
    )
    case awaitingWriteMutationReconciliation(
        stage: WriteOperationStage,
        failure: WriteOperationFailure
    )
    case ejectMutationQuiescencePending(
        stage: EjectMutationStage,
        failure: EjectFailure
    )
    case awaitingEjectMutationReconciliation(
        stage: EjectMutationStage,
        failure: EjectFailure
    )
    case writeOperationFailed(stage: WriteOperationStage, failure: WriteOperationFailure)
}

public enum SafeEjectAvailability: Equatable, Sendable {
    case available
    case blocked(EjectBlockReason)
    case temporarilyUnavailable
}

public struct VolumeStatusSnapshot: Equatable, Sendable {
    public let state: VolumeState
    public let safeEjectAvailability: SafeEjectAvailability
    public let isPhysicalDiskBusy: Bool

    public init(
        state: VolumeState,
        safeEjectAvailability: SafeEjectAvailability,
        isPhysicalDiskBusy: Bool = false
    ) {
        self.state = state
        self.safeEjectAvailability = safeEjectAvailability
        self.isPhysicalDiskBusy = isPhysicalDiskBusy
    }
}

package enum VolumeEvent: Equatable, Sendable {
    case enableWritingRequested(operationID: OperationID)
    case unmountSucceeded(operationID: OperationID)
    case safetySnapshotReceived(operationID: OperationID, snapshot: VolumeSnapshot)
    case mountCommandSucceeded(operationID: OperationID)
    case writeMountObserved(operationID: OperationID, observation: MountObservation)
    case ejectRequested(operationID: OperationID)
    case ejectUnmountCommandSucceeded(operationID: OperationID)
    case ejectUnmountCommandFailed(operationID: OperationID, failure: EjectFailure)
    case ejectCommandSucceeded(operationID: OperationID)
    case ejectCommandFailed(operationID: OperationID, failure: EjectFailure)
    case ejectDiskObserved(
        operationID: OperationID,
        phase: EjectInspectionPhase,
        observation: PhysicalDiskObservation
    )
    case writeMutationOutcomeUncertain(
        operationID: OperationID,
        stage: WriteOperationStage,
        failure: WriteOperationFailure
    )
    case writeMutationQuiesced(operationID: OperationID, stage: WriteOperationStage)
    case writeMutationReconciliationObserved(
        operationID: OperationID,
        observation: WriteMutationReconciliationObservation
    )
    case ejectMutationOutcomeUncertain(
        operationID: OperationID,
        stage: EjectMutationStage,
        failure: EjectFailure
    )
    case ejectMutationQuiesced(
        operationID: OperationID,
        stage: EjectMutationStage
    )
    case ejectMutationReconciliationObserved(
        operationID: OperationID,
        observation: PhysicalDiskObservation
    )
    case writeOperationFailed(
        operationID: OperationID,
        stage: WriteOperationStage,
        failure: WriteOperationFailure
    )
}

package enum DiskLifecycleEvent: Equatable, Sendable {
    case mediaRemoved(expected: DiskInstanceID)
    case mediaReplaced(expected: DiskInstanceID, observed: DiskInstanceID)
}

package enum DiskLifecycleResult: Equatable, Sendable {
    case applied([VolumeID])
    case ignored
}

package struct VolumeWorkflow: Equatable, Sendable {
    package private(set) var state: VolumeState
    private var snapshot: VolumeSnapshot
    package private(set) var activeOperationID: OperationID?

    package init(snapshot: VolumeSnapshot) {
        self.snapshot = snapshot
        self.state = Self.initialState(for: snapshot)
        self.activeOperationID = nil
    }

    package mutating func reconcileObservedSnapshot(
        _ freshSnapshot: VolumeSnapshot,
        preservingWorkflowState: Bool
    ) -> Bool {
        guard
            freshSnapshot.id == snapshot.id,
            freshSnapshot.diskInstanceID == snapshot.diskInstanceID
        else {
            return false
        }
        if !preservingWorkflowState {
            guard activeOperationID == nil else {
                return false
            }
        }
        snapshot = freshSnapshot
        if !preservingWorkflowState {
            state = Self.initialState(for: freshSnapshot)
        }
        return true
    }

    package mutating func handle(_ event: VolumeEvent) -> WorkflowResult {
        switch event {
        case let .enableWritingRequested(operationID):
            if case let .writeBlocked(reason) = state {
                return .rejected(.writeBlocked(reason))
            }
            if state == .unmountedReady {
                activeOperationID = operationID
                state = .awaitingSafetySnapshot
                return .accepted(
                    .inspectSafetySnapshot(
                        operationID: operationID,
                        target: snapshot.instanceID
                    )
                )
            }
            guard state == .readOnlyReady else {
                return .rejected(.operationInProgress)
            }
            activeOperationID = operationID
            state = .unmountingForWrite
            return .accepted(
                .unmountStandard(
                    operationID: operationID,
                    target: snapshot.instanceID
                )
            )
        case let .unmountSucceeded(operationID):
            guard state == .unmountingForWrite, activeOperationID == operationID else {
                return .ignored
            }
            state = .awaitingSafetySnapshot
            return .accepted(
                .inspectSafetySnapshot(
                    operationID: operationID,
                    target: snapshot.instanceID
                )
            )
        case let .safetySnapshotReceived(operationID, freshSnapshot):
            guard
                state == .awaitingSafetySnapshot,
                activeOperationID == operationID
            else {
                return .ignored
            }
            guard freshSnapshot.id == snapshot.id else {
                activeOperationID = nil
                state = .writeVerificationFailed(.wrongVolume)
                return .rejected(.mountVerificationFailed(.wrongVolume))
            }
            guard freshSnapshot.diskInstanceID == snapshot.diskInstanceID else {
                return invalidateMedia(observed: freshSnapshot.diskInstanceID)
            }
            guard freshSnapshot.mountAccess == .unmounted else {
                return .accepted(
                    .inspectSafetySnapshot(
                        operationID: operationID,
                        target: snapshot.instanceID
                    )
                )
            }
            if let reason = WriteSafetyPolicy.blockReason(for: freshSnapshot) {
                activeOperationID = nil
                state = .writeBlocked(reason)
                return .rejected(.writeBlocked(reason))
            }
            state = .mountingWrite
            return .accepted(
                .mountReadWrite(
                    MountPlan(
                        operationID: operationID,
                        target: freshSnapshot.instanceID,
                        policy: .fsKitCurrentUserNoRecovery
                    )
                )
            )
        case let .mountCommandSucceeded(operationID):
            guard state == .mountingWrite, activeOperationID == operationID else {
                return .ignored
            }
            state = .awaitingWriteVerification
            return .accepted(
                .inspectWriteMount(
                    operationID: operationID,
                    target: snapshot.instanceID
                )
            )
        case let .writeMountObserved(operationID, observation):
            guard state == .awaitingWriteVerification, activeOperationID == operationID else {
                return .ignored
            }
            let observedDiskInstanceID = DiskInstanceID(
                physicalDiskID: observation.physicalDiskID,
                mediaGeneration: observation.mediaGeneration
            )
            guard observedDiskInstanceID == snapshot.diskInstanceID else {
                return invalidateMedia(observed: observedDiskInstanceID)
            }
            if let failure = mountVerificationFailure(for: observation) {
                activeOperationID = nil
                state = .writeVerificationFailed(failure)
                return .rejected(.mountVerificationFailed(failure))
            }
            activeOperationID = nil
            state = .writable
            return .accepted(.none)
        case let .ejectRequested(operationID):
            if case let .ejectBlocked(reason) = state {
                return .rejected(.ejectBlocked(reason))
            }
            if let reason = Self.ejectBlockReason(for: snapshot) {
                return .rejected(.ejectBlocked(reason))
            }
            let canStartEject: Bool
            switch state {
            case .readOnlyReady, .unmountedReady, .writable,
                .existingWriteMountUnverified(_), .writeBlocked(_),
                .writeVerificationFailed(_), .writeOperationFailed(_, _), .ejectFailed(_):
                canStartEject = true
            default:
                canStartEject = false
            }
            guard canStartEject else {
                return .rejected(.operationInProgress)
            }
            activeOperationID = operationID
            state = .unmountingForEject
            return .accepted(
                .unmountPhysicalDiskStandard(
                    operationID: operationID,
                    target: snapshot.diskInstanceID
                )
            )
        case let .ejectUnmountCommandSucceeded(operationID):
            guard state == .unmountingForEject, activeOperationID == operationID else {
                return .ignored
            }
            state = .awaitingUnmountVerification
            return .accepted(
                .inspectPhysicalDisk(
                    operationID: operationID,
                    target: snapshot.diskInstanceID,
                    phase: .afterUnmount
                )
            )
        case let .ejectUnmountCommandFailed(operationID, failure):
            guard state == .unmountingForEject, activeOperationID == operationID else {
                return .ignored
            }
            state = .awaitingEjectMutationReconciliation(
                stage: .unmountingPhysicalDisk,
                failure: failure
            )
            return .accepted(
                .inspectEjectMutationReconciliation(
                    operationID: operationID,
                    target: snapshot.diskInstanceID,
                    stage: .unmountingPhysicalDisk
                )
            )
        case let .ejectCommandSucceeded(operationID):
            guard state == .ejecting, activeOperationID == operationID else {
                return .ignored
            }
            state = .awaitingRemovalVerification
            return .accepted(
                .inspectPhysicalDisk(
                    operationID: operationID,
                    target: snapshot.diskInstanceID,
                    phase: .afterEject
                )
            )
        case let .ejectCommandFailed(operationID, failure):
            guard state == .ejecting, activeOperationID == operationID else {
                return .ignored
            }
            state = .awaitingEjectMutationReconciliation(
                stage: .ejectingPhysicalDisk,
                failure: failure
            )
            return .accepted(
                .inspectEjectMutationReconciliation(
                    operationID: operationID,
                    target: snapshot.diskInstanceID,
                    stage: .ejectingPhysicalDisk
                )
            )
        case let .ejectDiskObserved(operationID, phase, observation):
            guard activeOperationID == operationID else {
                return .ignored
            }
            let observedDiskInstanceID = DiskInstanceID(
                physicalDiskID: observation.physicalDiskID,
                mediaGeneration: observation.mediaGeneration
            )
            guard observedDiskInstanceID == snapshot.diskInstanceID else {
                return invalidateMedia(observed: observedDiskInstanceID)
            }
            let childVolumeIDs = observation.childVolumes.map(\.volumeID)
            let hasUniqueChildVolumes = Set(childVolumeIDs).count == childVolumeIDs.count
            switch (state, phase) {
            case (.awaitingUnmountVerification, .afterUnmount):
                guard observation.isComplete, hasUniqueChildVolumes else {
                    return .accepted(
                        .inspectPhysicalDisk(
                            operationID: operationID,
                            target: snapshot.diskInstanceID,
                            phase: .afterUnmount
                        )
                    )
                }
                if observation.presence == .absent {
                    guard observation.childVolumes.isEmpty else {
                        return .accepted(
                            .inspectPhysicalDisk(
                                operationID: operationID,
                                target: snapshot.diskInstanceID,
                                phase: .afterUnmount
                            )
                        )
                    }
                    activeOperationID = nil
                    state = .safeToRemove
                    return .accepted(.none)
                }
                guard observation.childVolumes.contains(where: { $0.volumeID == snapshot.id }) else {
                    activeOperationID = nil
                    state = .ejectFailed(.observationIncomplete)
                    return .rejected(.ejectFailed(.observationIncomplete))
                }
                let mountedVolumeIDs = observation.childVolumes.compactMap { child in
                    child.mountAccess == .unmounted ? nil : child.volumeID
                }
                guard mountedVolumeIDs.isEmpty else {
                    let failure = EjectFailure.volumesStillMounted(mountedVolumeIDs)
                    activeOperationID = nil
                    state = .ejectFailed(failure)
                    return .rejected(.ejectFailed(failure))
                }
                state = .ejecting
                return .accepted(
                    .ejectPhysicalDiskStandard(
                        operationID: operationID,
                        target: snapshot.diskInstanceID
                    )
                )
            case (.awaitingRemovalVerification, .afterEject):
                guard observation.isComplete, hasUniqueChildVolumes else {
                    return .accepted(
                        .inspectPhysicalDisk(
                            operationID: operationID,
                            target: snapshot.diskInstanceID,
                            phase: .afterEject
                        )
                    )
                }
                if observation.presence == .absent {
                    guard observation.childVolumes.isEmpty else {
                        return .accepted(
                            .inspectPhysicalDisk(
                                operationID: operationID,
                                target: snapshot.diskInstanceID,
                                phase: .afterEject
                            )
                        )
                    }
                    activeOperationID = nil
                    state = .safeToRemove
                    return .accepted(.none)
                }
                if observation.presence == .present {
                    activeOperationID = nil
                    state = .ejectFailed(.diskStillPresent)
                    return .rejected(.ejectFailed(.diskStillPresent))
                }
                return .ignored
            default:
                return .ignored
            }
        case let .writeMutationOutcomeUncertain(operationID, stage, failure):
            guard
                activeOperationID == operationID,
                Self.writeOperationStage(for: state) == stage,
                failure == .timedOut || failure == .cancelled,
                stage == .unmountingReadOnly || stage == .mountingWrite
            else {
                return .ignored
            }
            state = .writeMutationQuiescencePending(stage: stage, failure: failure)
            return .rejected(.writeOperationFailed(stage: stage, failure: failure))
        case let .writeMutationQuiesced(operationID, stage):
            guard
                activeOperationID == operationID,
                case let .writeMutationQuiescencePending(expectedStage, failure) = state,
                expectedStage == stage
            else {
                return .ignored
            }
            state = .awaitingWriteMutationReconciliation(stage: stage, failure: failure)
            return .accepted(
                .inspectWriteMutationReconciliation(
                    operationID: operationID,
                    target: snapshot.instanceID
                )
            )
        case let .writeMutationReconciliationObserved(operationID, observation):
            guard
                activeOperationID == operationID,
                case let .awaitingWriteMutationReconciliation(stage, failure) = state
            else {
                return .ignored
            }
            guard observation.isComplete else {
                return .accepted(
                    .inspectWriteMutationReconciliation(
                        operationID: operationID,
                        target: snapshot.instanceID
                    )
                )
            }
            guard observation.snapshot.diskInstanceID == snapshot.diskInstanceID else {
                return invalidateMedia(observed: observation.snapshot.diskInstanceID)
            }
            guard observation.snapshot.id == snapshot.id else {
                activeOperationID = nil
                state = .writeVerificationFailed(.wrongVolume)
                return .rejected(.mountVerificationFailed(.wrongVolume))
            }
            activeOperationID = nil
            state = .writeOperationFailed(stage: stage, failure: failure)
            return .rejected(.writeOperationFailed(stage: stage, failure: failure))
        case let .ejectMutationOutcomeUncertain(operationID, stage, failure):
            guard
                activeOperationID == operationID,
                Self.ejectMutationStage(for: state) == stage,
                failure == .timedOut || failure == .cancelled
            else {
                return .ignored
            }
            state = .ejectMutationQuiescencePending(stage: stage, failure: failure)
            return .rejected(.ejectFailed(failure))
        case let .ejectMutationQuiesced(operationID, stage):
            guard
                activeOperationID == operationID,
                case let .ejectMutationQuiescencePending(expectedStage, failure) = state,
                expectedStage == stage
            else {
                return .ignored
            }
            state = .awaitingEjectMutationReconciliation(stage: stage, failure: failure)
            return .accepted(
                .inspectEjectMutationReconciliation(
                    operationID: operationID,
                    target: snapshot.diskInstanceID,
                    stage: stage
                )
            )
        case let .ejectMutationReconciliationObserved(operationID, observation):
            guard
                activeOperationID == operationID,
                case let .awaitingEjectMutationReconciliation(stage, failure) = state
            else {
                return .ignored
            }
            let observedDiskInstanceID = DiskInstanceID(
                physicalDiskID: observation.physicalDiskID,
                mediaGeneration: observation.mediaGeneration
            )
            guard observedDiskInstanceID == snapshot.diskInstanceID else {
                return invalidateMedia(observed: observedDiskInstanceID)
            }
            let childVolumeIDs = observation.childVolumes.map(\.volumeID)
            guard
                observation.isComplete,
                Set(childVolumeIDs).count == childVolumeIDs.count
            else {
                return .accepted(
                    .inspectEjectMutationReconciliation(
                        operationID: operationID,
                        target: snapshot.diskInstanceID,
                        stage: stage
                    )
                )
            }
            if observation.presence == .absent {
                guard observation.childVolumes.isEmpty else {
                    return .accepted(
                        .inspectEjectMutationReconciliation(
                            operationID: operationID,
                            target: snapshot.diskInstanceID,
                            stage: stage
                        )
                    )
                }
                activeOperationID = nil
                state = .safeToRemove
                return .accepted(.none)
            }
            if observation.presence == .present {
                activeOperationID = nil
                state = .ejectFailed(failure)
                return .rejected(.ejectFailed(failure))
            }
            return .ignored
        case let .writeOperationFailed(operationID, stage, failure):
            guard
                activeOperationID == operationID,
                Self.writeOperationStage(for: state) == stage
            else {
                return .ignored
            }
            activeOperationID = nil
            state = .writeOperationFailed(stage: stage, failure: failure)
            return .rejected(.writeOperationFailed(stage: stage, failure: failure))
        }
    }

    fileprivate mutating func settleRejectedPreflight(
        command: MutationCommand,
        failure: MutationPreflightFailure
    ) -> Bool {
        guard activeOperationID == command.operationID else {
            return false
        }

        activeOperationID = nil
        switch command {
        case .unmountVolumeStandard:
            if case let .writeSafetyChanged(reason) = failure {
                state = .writeBlocked(reason)
            } else {
                state = .writeOperationFailed(
                    stage: .unmountingReadOnly,
                    failure: Self.preflightWriteFailure(for: failure)
                )
            }
        case .mountWrite:
            if case let .writeSafetyChanged(reason) = failure {
                state = .writeBlocked(reason)
            } else {
                state = .writeOperationFailed(
                    stage: .mountingWrite,
                    failure: Self.preflightWriteFailure(for: failure)
                )
            }
        case .unmountDiskStandard, .ejectDiskStandard:
            if case let .ejectBlocked(reason) = failure {
                state = .ejectBlocked(reason)
            } else if case let .ejectNotReady(ejectFailure) = failure {
                state = .ejectFailed(ejectFailure)
            } else {
                state = .ejectFailed(.observationIncomplete)
            }
        }
        return true
    }

    package mutating func handleDiskLifecycleEvent(
        _ event: DiskLifecycleEvent
    ) -> WorkflowResult {
        switch event {
        case let .mediaRemoved(expected):
            guard expected == snapshot.diskInstanceID else {
                return .ignored
            }
            activeOperationID = nil
            if state == .safeToRemove {
                return .accepted(.none)
            }
            state = .mediaUnavailable
            return .accepted(.none)
        case let .mediaReplaced(expected, observed):
            guard
                expected == snapshot.diskInstanceID,
                observed.physicalDiskID == expected.physicalDiskID,
                observed != expected
            else {
                return .ignored
            }
            return invalidateMedia(observed: observed)
        }
    }

    private static func ejectBlockReason(for snapshot: VolumeSnapshot) -> EjectBlockReason? {
        if snapshot.role == .protected {
            return .protectedDisk
        }
        if snapshot.role == .bootCamp {
            return .bootCampDisk
        }
        if snapshot.location == .internal {
            return .internalDisk
        }
        return nil
    }

    private static func preflightWriteFailure(
        for failure: MutationPreflightFailure
    ) -> WriteOperationFailure {
        if case .setupNotReady = failure {
            return .dependencyUnavailable
        }
        return .inspectionUnavailable
    }

    private static func initialState(for snapshot: VolumeSnapshot) -> VolumeState {
        let writeBlockReason = WriteSafetyPolicy.blockReason(for: snapshot)
        if snapshot.mountAccess == .readWrite {
            return .existingWriteMountUnverified(writeBlockReason)
        }
        if let writeBlockReason {
            return .writeBlocked(writeBlockReason)
        }
        switch snapshot.mountAccess {
        case .unmounted:
            return .unmountedReady
        case .readOnly:
            return .readOnlyReady
        case .readWrite:
            return .existingWriteMountUnverified(nil)
        }
    }

    private static func writeOperationStage(for state: VolumeState) -> WriteOperationStage? {
        switch state {
        case .unmountingForWrite:
            return .unmountingReadOnly
        case .awaitingSafetySnapshot:
            return .inspectingSafety
        case .mountingWrite:
            return .mountingWrite
        case .awaitingWriteVerification:
            return .inspectingWriteMount
        default:
            return nil
        }
    }

    private static func ejectMutationStage(for state: VolumeState) -> EjectMutationStage? {
        switch state {
        case .unmountingForEject:
            return .unmountingPhysicalDisk
        case .ejecting:
            return .ejectingPhysicalDisk
        default:
            return nil
        }
    }

    private func mountVerificationFailure(
        for observation: MountObservation
    ) -> MountVerificationFailure? {
        guard observation.isComplete else {
            return .observationIncomplete
        }
        guard observation.volumeID == snapshot.id else {
            return .wrongVolume
        }
        guard observation.sourceBSDName == snapshot.id.bsdName else {
            return .sourceDeviceMismatch
        }
        guard observation.access == .readWrite else {
            return .notReadWrite
        }
        guard observation.backend == .fsKit else {
            return .unexpectedBackend
        }
        guard observation.isCanonical, !observation.isSymlink else {
            return .untrustedMountPath
        }

        let volumePrefix = "/Volumes/"
        let mountName = observation.mountPoint.dropFirst(volumePrefix.count)
        let hasControlCharacter = mountName.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
        guard
            observation.mountPoint.hasPrefix(volumePrefix),
            !mountName.isEmpty,
            mountName != ".",
            mountName != "..",
            !mountName.contains("/"),
            !hasControlCharacter
        else {
            return .invalidMountPoint
        }
        return nil
    }

    fileprivate mutating func invalidateMedia(
        observed: DiskInstanceID
    ) -> WorkflowResult {
        let mismatch = MediaInstanceMismatch(
            expected: snapshot.diskInstanceID,
            observed: observed
        )
        activeOperationID = nil
        state = .mediaInvalidated(mismatch)
        return .rejected(.mediaChanged(mismatch))
    }
}

public enum InventoryRebuildResult: Equatable, Sendable {
    case rebuilt
    case operationsInProgress([PhysicalDiskID])
}

private struct ActiveOperationLease: Sendable {
    let operationID: OperationID
    let diskInstanceID: DiskInstanceID
    let ownerVolumeID: VolumeID
    var expectedMutation: MutationCommand?
    var claimedMutation: MutationCommand?
    var claimedMutationIsExecuting: Bool
    var lifecycleInvalidated: Bool
    var mediaRemovalObserved: Bool
}

private enum MutationClaimResult: Sendable {
    case claimed(MutationCommand)
    case rejected(MutationPreflightFailure)
    case notMutation
}

public actor VolumeCoordinator {
    private var workflows: [VolumeID: VolumeWorkflow]
    private var snapshots: [VolumeID: VolumeSnapshot]
    private var activeOperations: [PhysicalDiskID: ActiveOperationLease]
    private var physicalDiskSafetyByInstance: [
        DiskInstanceID: PhysicalDiskSafetySnapshot
    ]
    private let setupFactsProvider: SetupFactsProvider
    private let operationNamespace: UUID
    private var nextOperationSequence: UInt64

    public init(
        snapshots: [VolumeSnapshot],
        physicalDiskSafetySnapshots: [PhysicalDiskSafetySnapshot] = [],
        setupFactsProvider: SetupFactsProvider
    ) {
        var initialWorkflows: [VolumeID: VolumeWorkflow] = [:]
        var initialSnapshots: [VolumeID: VolumeSnapshot] = [:]
        for snapshot in snapshots {
            initialWorkflows[snapshot.id] = VolumeWorkflow(snapshot: snapshot)
            initialSnapshots[snapshot.id] = snapshot
        }
        self.workflows = initialWorkflows
        self.snapshots = initialSnapshots
        self.activeOperations = [:]
        self.physicalDiskSafetyByInstance = Self.indexedPhysicalDiskSafety(
            physicalDiskSafetySnapshots
        )
        self.setupFactsProvider = setupFactsProvider
        self.operationNamespace = UUID()
        self.nextOperationSequence = 0
    }

    public func state(for volumeID: VolumeID) -> VolumeState? {
        workflows[volumeID]?.state
    }

    public func status(for volumeID: VolumeID) -> VolumeStatusSnapshot? {
        guard
            let workflow = workflows[volumeID],
            let snapshot = snapshots[volumeID]
        else {
            return nil
        }
        return VolumeStatusSnapshot(
            state: workflow.state,
            safeEjectAvailability: safeEjectAvailability(for: snapshot),
            isPhysicalDiskBusy: activeOperations[snapshot.physicalDiskID]
                .map { lease in
                    lease.ownerVolumeID != volumeID
                        && !Self.isTerminalMediaState(workflow.state)
                } ?? false
        )
    }

    public func rebuildInventory(
        snapshots: [VolumeSnapshot],
        physicalDiskSafetySnapshots: [PhysicalDiskSafetySnapshot] = []
    ) -> InventoryRebuildResult {
        guard activeOperations.isEmpty else {
            let activeDiskIDs = activeOperations.keys.sorted { lhs, rhs in
                lhs.rawValue < rhs.rawValue
            }
            return .operationsInProgress(activeDiskIDs)
        }
        var rebuiltWorkflows: [VolumeID: VolumeWorkflow] = [:]
        var rebuiltSnapshots: [VolumeID: VolumeSnapshot] = [:]
        for snapshot in snapshots {
            rebuiltWorkflows[snapshot.id] = VolumeWorkflow(snapshot: snapshot)
            rebuiltSnapshots[snapshot.id] = snapshot
        }
        workflows = rebuiltWorkflows
        self.snapshots = rebuiltSnapshots
        physicalDiskSafetyByInstance = Self.indexedPhysicalDiskSafety(
            physicalDiskSafetySnapshots
        )
        activeOperations.removeAll()
        return .rebuilt
    }

    public func requestEnableWriting(target: VolumeInstanceID) async -> WorkflowResult {
        guard snapshots[target.volumeID]?.instanceID == target else {
            return .rejected(.volumeUnavailable)
        }
        let assessment = SetupChecker.assess(await setupFactsProvider.currentFacts())
        guard assessment.isReady else {
            return .rejected(.setupNotReady(assessment.issues))
        }
        return beginOperation(target: target) { operationID in
            .enableWritingRequested(operationID: operationID)
        }
    }

    public func requestEject(target: VolumeInstanceID) -> WorkflowResult {
        guard
            let selectedSnapshot = snapshots[target.volumeID],
            selectedSnapshot.instanceID == target
        else {
            return .rejected(.volumeUnavailable)
        }
        switch safeEjectAvailability(for: selectedSnapshot) {
        case .available:
            break
        case let .blocked(reason):
            return .rejected(.ejectBlocked(reason))
        case .temporarilyUnavailable:
            return .rejected(.volumeUnavailable)
        }
        return beginOperation(target: target) { operationID in
            .ejectRequested(operationID: operationID)
        }
    }

    /// Atomically consumes the current one-shot mutation intent before invoking it.
    /// This closure-compatible entry requires the adapter to preserve the same
    /// explicit termination semantics as `MountEngine`.
    package func executeMutation(
        effect: VolumeEffect,
        resolveEvidence: @Sendable () async -> MutationPreflightEvidence,
        invoke: @Sendable (MutationCommand) async -> MountEngineTermination
    ) async -> MutationExecutionResult {
        switch await claimMutation(effect: effect, resolveEvidence: resolveEvidence) {
        case let .claimed(command):
            let termination = await invoke(command)
            settleMutationInvocation(
                command,
                hasConfirmedQuiescence: termination.hasConfirmedQuiescence
            )
            return .executed
        case let .rejected(failure):
            return .rejected(failure)
        case .notMutation:
            return .notMutation
        }
    }

    /// Runs the exact claimed semantic command through the package-only engine
    /// contract. The result identifies both process quiescence and the fresh
    /// system evidence scope that must be read before any final state is claimed.
    package func executeMutation(
        effect: VolumeEffect,
        resolveEvidence: @Sendable () async -> MutationPreflightEvidence,
        engine: MountEngine
    ) async -> MountEngineExecutionResult {
        switch await claimMutation(effect: effect, resolveEvidence: resolveEvidence) {
        case let .claimed(command):
            let result = await engine.execute(command)
            settleMutationInvocation(
                command,
                hasConfirmedQuiescence: result.termination.hasConfirmedQuiescence
            )
            return .executed(result)
        case let .rejected(failure):
            return .rejected(failure)
        case .notMutation:
            return .notMutation
        }
    }

    private func claimMutation(
        effect: VolumeEffect,
        resolveEvidence: @Sendable () async -> MutationPreflightEvidence
    ) async -> MutationClaimResult {
        guard let command = MutationPreflight.command(for: effect) else {
            return .notMutation
        }

        let assessment: SetupAssessment?
        if command.requiresWriteSetup {
            assessment = SetupChecker.assess(await setupFactsProvider.currentFacts())
        } else {
            assessment = nil
        }
        let evidence = await resolveEvidence()
        let diskID = command.physicalDiskID

        guard var lease = activeOperations[diskID] else {
            return .rejected(
                .operationNotActive(expected: nil, observed: command.operationID)
            )
        }
        guard lease.operationID == command.operationID else {
            return .rejected(
                .operationNotActive(
                    expected: lease.operationID,
                    observed: command.operationID
                )
            )
        }
        guard lease.expectedMutation == command else {
            return .rejected(.effectNotExpected)
        }

        if case .disk = command.target,
            case let .disk(observation) = evidence
        {
            reconcileCompleteDiskMutationObservation(
                observation,
                ownerVolumeID: lease.ownerVolumeID
            )
        }

        lease.expectedMutation = nil
        activeOperations[diskID] = lease
        let validationFailure = MutationPreflight.validate(
            command: command,
            evidence: evidence,
            setupAssessment: assessment
        )
        let failure = validationFailure ?? Self.coordinatorDiskPreflightFailure(
            command: command,
            evidence: evidence,
            ownerVolumeID: lease.ownerVolumeID
        )
        if let failure {
            if Self.completeDiskEvidenceOmitsOwner(
                command: command,
                evidence: evidence,
                ownerVolumeID: lease.ownerVolumeID
            ) {
                settleMissingOwner(command: command)
            } else {
                settleRejectedPreflight(command: command, failure: failure)
            }
            return .rejected(failure)
        }

        lease.claimedMutation = command
        lease.claimedMutationIsExecuting = true
        activeOperations[diskID] = lease
        return .claimed(command)
    }

    private func settleMutationInvocation(
        _ command: MutationCommand,
        hasConfirmedQuiescence: Bool
    ) {
        guard hasConfirmedQuiescence else {
            return
        }
        let diskID = command.physicalDiskID
        if
            var currentLease = activeOperations[diskID],
            currentLease.operationID == command.operationID,
            currentLease.claimedMutation == command
        {
            if currentLease.lifecycleInvalidated {
                activeOperations[diskID] = nil
            } else {
                currentLease.claimedMutationIsExecuting = false
                activeOperations[diskID] = currentLease
            }
        }
    }

    package func processDiskLifecycleEvent(
        _ event: DiskLifecycleEvent
    ) -> DiskLifecycleResult {
        let expected: DiskInstanceID
        switch event {
        case let .mediaRemoved(target):
            expected = target
        case let .mediaReplaced(target, observed):
            guard
                observed.physicalDiskID == target.physicalDiskID,
                observed != target
            else {
                return .ignored
            }
            expected = target
        }

        let affectedIDs = snapshots.values
            .filter { snapshot in snapshot.diskInstanceID == expected }
            .map(\.id)
            .sorted { lhs, rhs in
                if lhs.uuid != rhs.uuid {
                    return lhs.uuid < rhs.uuid
                }
                return lhs.bsdName < rhs.bsdName
            }
        physicalDiskSafetyByInstance[expected] = nil
        guard !affectedIDs.isEmpty else {
            return .ignored
        }

        let preservedEjectOwnerID: VolumeID?
        if case .mediaRemoved = event,
            let lease = activeOperations[expected.physicalDiskID],
            lease.diskInstanceID == expected,
            let ownerWorkflow = workflows[lease.ownerVolumeID],
            ownerWorkflow.activeOperationID == lease.operationID
        {
            switch ownerWorkflow.state {
            case .ejecting:
                if case let .ejectDiskStandard(operationID, target) = lease.claimedMutation,
                    operationID == lease.operationID,
                    target == expected
                {
                    preservedEjectOwnerID = lease.ownerVolumeID
                } else {
                    preservedEjectOwnerID = nil
                }
            case .awaitingRemovalVerification,
                .ejectMutationQuiescencePending,
                .awaitingEjectMutationReconciliation:
                preservedEjectOwnerID = lease.ownerVolumeID
            default:
                preservedEjectOwnerID = nil
            }
        } else {
            preservedEjectOwnerID = nil
        }

        for volumeID in affectedIDs {
            if volumeID == preservedEjectOwnerID {
                continue
            }
            guard var workflow = workflows[volumeID] else {
                continue
            }
            _ = workflow.handleDiskLifecycleEvent(event)
            workflows[volumeID] = workflow
        }
        if
            var lease = activeOperations[expected.physicalDiskID],
            lease.diskInstanceID == expected
        {
            if preservedEjectOwnerID != nil {
                lease.mediaRemovalObserved = true
                activeOperations[expected.physicalDiskID] = lease
            } else if lease.claimedMutationIsExecuting {
                lease.expectedMutation = nil
                lease.lifecycleInvalidated = true
                activeOperations[expected.physicalDiskID] = lease
            } else {
                activeOperations[expected.physicalDiskID] = nil
            }
        }
        return .applied(affectedIDs)
    }

    package func processSystemEvent(
        _ event: VolumeEvent,
        volumeID: VolumeID
    ) -> WorkflowResult {
        switch event {
        case .enableWritingRequested, .ejectRequested, .writeMutationOutcomeUncertain,
            .ejectMutationOutcomeUncertain:
            return .ignored
        default:
            break
        }
        guard
            var workflow = workflows[volumeID],
            let snapshot = snapshots[volumeID]
        else {
            return .rejected(.volumeUnavailable)
        }

        var routedEvent = event
        if case let .writeOperationFailed(operationID, stage, failure) = event,
            (failure == .timedOut || failure == .cancelled),
            (stage == .unmountingReadOnly || stage == .mountingWrite),
            let lease = activeOperations[snapshot.physicalDiskID],
            lease.operationID == operationID,
            lease.claimedMutation != nil
        {
            routedEvent = .writeMutationOutcomeUncertain(
                operationID: operationID,
                stage: stage,
                failure: failure
            )
        }
        if
            let lease = activeOperations[snapshot.physicalDiskID],
            Self.failureEvent(
                event,
                matches: lease.claimedMutation,
                operationID: lease.operationID
            )
        {
            switch event {
            case let .ejectUnmountCommandFailed(operationID, failure)
                where failure == .timedOut || failure == .cancelled:
                routedEvent = .ejectMutationOutcomeUncertain(
                    operationID: operationID,
                    stage: .unmountingPhysicalDisk,
                    failure: failure
                )
            case let .ejectCommandFailed(operationID, failure)
                where failure == .timedOut || failure == .cancelled:
                routedEvent = .ejectMutationOutcomeUncertain(
                    operationID: operationID,
                    stage: .ejectingPhysicalDisk,
                    failure: failure
                )
            default:
                break
            }
        }
        if case let .writeMutationQuiesced(operationID, _) = routedEvent {
            guard
                let lease = activeOperations[snapshot.physicalDiskID],
                lease.operationID == operationID,
                lease.claimedMutation != nil,
                !lease.claimedMutationIsExecuting
            else {
                return .ignored
            }
        }
        if case let .ejectMutationQuiesced(operationID, _) = routedEvent {
            guard
                let lease = activeOperations[snapshot.physicalDiskID],
                lease.operationID == operationID,
                lease.claimedMutation != nil,
                !lease.claimedMutationIsExecuting
            else {
                return .ignored
            }
        }

        if Self.isMutationSuccessEvent(routedEvent) {
            guard
                let lease = activeOperations[snapshot.physicalDiskID],
                Self.successEvent(
                    routedEvent,
                    matches: lease.claimedMutation,
                    operationID: lease.operationID
                ),
                !lease.claimedMutationIsExecuting
            else {
                return .ignored
            }
        }
        if Self.isMutationFailureEvent(routedEvent) {
            guard
                let lease = activeOperations[snapshot.physicalDiskID],
                Self.failureEvent(
                    routedEvent,
                    matches: lease.claimedMutation,
                    operationID: lease.operationID
                ),
                !lease.claimedMutationIsExecuting
            else {
                return .ignored
            }
        }

        if let lease = activeOperations[snapshot.physicalDiskID],
            let effect = Self.reinspectionEffectAfterRemoval(
                for: routedEvent,
                workflow: workflow,
                snapshot: snapshot,
                lease: lease
            )
        {
            return .accepted(effect)
        }

        let operationBeforeTransition = workflow.activeOperationID
        let result = workflow.handle(routedEvent)
        let completePresentObservation: PhysicalDiskObservation?
        if result != .ignored {
            completePresentObservation = Self.completePresentDiskObservation(
                in: routedEvent,
                expected: snapshot.diskInstanceID
            )
        } else {
            completePresentObservation = nil
        }
        if let observation = completePresentObservation {
            if let child = Self.uniqueChildObservation(
                for: volumeID,
                in: observation
            ), let currentSnapshot = snapshots[volumeID] {
                let freshSnapshot = Self.replacingMountAccess(
                    in: currentSnapshot,
                    with: child.mountAccess
                )
                snapshots[volumeID] = freshSnapshot
                _ = workflow.reconcileObservedSnapshot(
                    freshSnapshot,
                    preservingWorkflowState: true
                )
            } else if workflow.activeOperationID == nil {
                _ = workflow.handleDiskLifecycleEvent(
                    .mediaRemoved(expected: snapshot.diskInstanceID)
                )
            }
        }
        if
            let lease = activeOperations[snapshot.physicalDiskID],
            lease.ownerVolumeID == volumeID,
            lease.mediaRemovalObserved,
            workflow.activeOperationID == nil,
            workflow.state != .safeToRemove
        {
            _ = workflow.handleDiskLifecycleEvent(
                .mediaRemoved(expected: snapshot.diskInstanceID)
            )
        }
        workflows[volumeID] = workflow
        if let completePresentObservation {
            reconcileCompletePresentDiskObservation(
                completePresentObservation,
                ownerVolumeID: volumeID
            )
        }
        if case let .rejected(.mediaChanged(mismatch)) = result,
            mismatch.expected.physicalDiskID == mismatch.observed.physicalDiskID,
            case .applied = processDiskLifecycleEvent(
                .mediaReplaced(
                    expected: mismatch.expected,
                    observed: mismatch.observed
                )
            )
        {
            return result
        }
        let verifiedWholeDiskAbsence: Bool
        switch routedEvent {
        case .ejectDiskObserved,
            .ejectMutationReconciliationObserved:
            verifiedWholeDiskAbsence = workflow.state == .safeToRemove
        default:
            verifiedWholeDiskAbsence = false
        }
        if verifiedWholeDiskAbsence {
            revokeSiblingWorkflowsAfterVerifiedAbsence(
                ownerVolumeID: volumeID,
                diskInstanceID: snapshot.diskInstanceID
            )
        }
        if
            let operationBeforeTransition,
            workflow.activeOperationID == nil,
            activeOperations[snapshot.physicalDiskID]?.operationID == operationBeforeTransition
        {
            activeOperations[snapshot.physicalDiskID] = nil
        } else if
            case let .accepted(effect) = result,
            let operationID = workflow.activeOperationID,
            var lease = activeOperations[snapshot.physicalDiskID],
            lease.operationID == operationID
        {
            if
                Self.isMutationSuccessEvent(routedEvent)
                    || Self.isMutationQuiescenceEvent(routedEvent)
            {
                lease.claimedMutation = nil
                lease.claimedMutationIsExecuting = false
            }
            lease.expectedMutation = MutationPreflight.command(for: effect)
            activeOperations[snapshot.physicalDiskID] = lease
        }
        return result
    }

    private func reconcileCompleteDiskMutationObservation(
        _ observation: DiskMutationObservation,
        ownerVolumeID: VolumeID
    ) {
        let childIDs = observation.childSnapshots.map(\.id)
        guard
            observation.isComplete,
            Set(childIDs).count == childIDs.count,
            observation.childSnapshots.allSatisfy({ snapshot in
                snapshot.diskInstanceID == observation.target
                    && snapshots[snapshot.id].map { existing in
                        existing.diskInstanceID == observation.target
                    } ?? true
            }),
            snapshots[ownerVolumeID]?.diskInstanceID == observation.target
        else {
            return
        }

        let observedIDs = Set(childIDs)
        let knownIDs = snapshots.values
            .filter { $0.diskInstanceID == observation.target }
            .map(\.id)

        for freshSnapshot in observation.childSnapshots {
            snapshots[freshSnapshot.id] = freshSnapshot
            if var workflow = workflows[freshSnapshot.id] {
                let preservingWorkflowState = freshSnapshot.id == ownerVolumeID
                if !workflow.reconcileObservedSnapshot(
                    freshSnapshot,
                    preservingWorkflowState: preservingWorkflowState
                ) {
                    _ = workflow.handleDiskLifecycleEvent(
                        .mediaRemoved(expected: observation.target)
                    )
                }
                workflows[freshSnapshot.id] = workflow
            } else {
                workflows[freshSnapshot.id] = VolumeWorkflow(snapshot: freshSnapshot)
            }
        }

        for missingID in knownIDs where missingID != ownerVolumeID && !observedIDs.contains(missingID) {
            guard var workflow = workflows[missingID] else {
                continue
            }
            _ = workflow.handleDiskLifecycleEvent(
                .mediaRemoved(expected: observation.target)
            )
            workflows[missingID] = workflow
        }
    }

    private func reconcileCompletePresentDiskObservation(
        _ observation: PhysicalDiskObservation,
        ownerVolumeID: VolumeID
    ) {
        let diskInstanceID = DiskInstanceID(
            physicalDiskID: observation.physicalDiskID,
            mediaGeneration: observation.mediaGeneration
        )
        let childIDs = observation.childVolumes.map(\.volumeID)
        guard
            observation.isComplete,
            observation.presence == .present,
            Set(childIDs).count == childIDs.count
        else {
            return
        }
        let childrenByID = Dictionary(
            uniqueKeysWithValues: observation.childVolumes.map { child in
                (child.volumeID, child)
            }
        )
        let siblingIDs = snapshots.values
            .filter { snapshot in
                snapshot.diskInstanceID == diskInstanceID
                    && snapshot.id != ownerVolumeID
            }
            .map(\.id)

        for siblingID in siblingIDs {
            guard var workflow = workflows[siblingID] else {
                continue
            }
            if let child = childrenByID[siblingID],
                let currentSnapshot = snapshots[siblingID]
            {
                let freshSnapshot = Self.replacingMountAccess(
                    in: currentSnapshot,
                    with: child.mountAccess
                )
                snapshots[siblingID] = freshSnapshot
                if !workflow.reconcileObservedSnapshot(
                    freshSnapshot,
                    preservingWorkflowState: false
                ) {
                    _ = workflow.handleDiskLifecycleEvent(
                        .mediaRemoved(expected: diskInstanceID)
                    )
                }
            } else {
                _ = workflow.handleDiskLifecycleEvent(
                    .mediaRemoved(expected: diskInstanceID)
                )
            }
            workflows[siblingID] = workflow
        }
    }

    private static func completePresentDiskObservation(
        in event: VolumeEvent,
        expected: DiskInstanceID
    ) -> PhysicalDiskObservation? {
        let observation: PhysicalDiskObservation
        switch event {
        case let .ejectDiskObserved(_, _, observed),
            let .ejectMutationReconciliationObserved(_, observed):
            observation = observed
        default:
            return nil
        }
        let observedInstance = DiskInstanceID(
            physicalDiskID: observation.physicalDiskID,
            mediaGeneration: observation.mediaGeneration
        )
        guard
            observation.isComplete,
            observation.presence == .present,
            observedInstance == expected,
            Set(observation.childVolumes.map(\.volumeID)).count
                == observation.childVolumes.count
        else {
            return nil
        }
        return observation
    }

    private static func reinspectionEffectAfterRemoval(
        for event: VolumeEvent,
        workflow: VolumeWorkflow,
        snapshot: VolumeSnapshot,
        lease: ActiveOperationLease
    ) -> VolumeEffect? {
        guard
            lease.mediaRemovalObserved,
            lease.ownerVolumeID == snapshot.id,
            lease.operationID == workflow.activeOperationID
        else {
            return nil
        }

        switch event {
        case let .ejectDiskObserved(operationID, phase, observation):
            let observedInstance = DiskInstanceID(
                physicalDiskID: observation.physicalDiskID,
                mediaGeneration: observation.mediaGeneration
            )
            guard
                operationID == lease.operationID,
                phase == .afterEject,
                workflow.state == .awaitingRemovalVerification,
                observation.presence == .present,
                observedInstance == lease.diskInstanceID
            else {
                return nil
            }
            return .inspectPhysicalDisk(
                operationID: operationID,
                target: snapshot.diskInstanceID,
                phase: .afterEject
            )
        case let .ejectMutationReconciliationObserved(operationID, observation):
            let observedInstance = DiskInstanceID(
                physicalDiskID: observation.physicalDiskID,
                mediaGeneration: observation.mediaGeneration
            )
            guard
                operationID == lease.operationID,
                observation.presence == .present,
                observedInstance == lease.diskInstanceID,
                case let .awaitingEjectMutationReconciliation(stage, _) = workflow.state
            else {
                return nil
            }
            return .inspectEjectMutationReconciliation(
                operationID: operationID,
                target: snapshot.diskInstanceID,
                stage: stage
            )
        default:
            return nil
        }
    }

    private static func uniqueChildObservation(
        for volumeID: VolumeID,
        in observation: PhysicalDiskObservation
    ) -> ChildVolumeObservation? {
        let matches = observation.childVolumes.filter { $0.volumeID == volumeID }
        guard matches.count == 1 else {
            return nil
        }
        return matches[0]
    }

    private static func replacingMountAccess(
        in snapshot: VolumeSnapshot,
        with mountAccess: MountAccess
    ) -> VolumeSnapshot {
        VolumeSnapshot(
            id: snapshot.id,
            physicalDiskID: snapshot.physicalDiskID,
            mediaGeneration: snapshot.mediaGeneration,
            displayName: snapshot.displayName,
            fileSystem: snapshot.fileSystem,
            location: snapshot.location,
            role: snapshot.role,
            health: snapshot.health,
            mountAccess: mountAccess
        )
    }

    private static func coordinatorDiskPreflightFailure(
        command: MutationCommand,
        evidence: MutationPreflightEvidence,
        ownerVolumeID: VolumeID
    ) -> MutationPreflightFailure? {
        switch (command, evidence) {
        case let (.unmountDiskStandard(_, target), .disk(observation)),
            let (.ejectDiskStandard(_, target), .disk(observation)):
            guard observation.target == target else {
                return nil
            }
            guard observation.childSnapshots.contains(where: { snapshot in
                snapshot.id == ownerVolumeID
                    && snapshot.diskInstanceID == target
            }) else {
                return .diskObservationIncomplete
            }
        default:
            break
        }
        return nil
    }

    private static func completeDiskEvidenceOmitsOwner(
        command: MutationCommand,
        evidence: MutationPreflightEvidence,
        ownerVolumeID: VolumeID
    ) -> Bool {
        let target: DiskInstanceID
        switch command {
        case let .unmountDiskStandard(_, diskTarget),
            let .ejectDiskStandard(_, diskTarget):
            target = diskTarget
        default:
            return false
        }
        guard case let .disk(observation) = evidence else {
            return false
        }
        let childIDs = observation.childSnapshots.map(\.id)
        guard
            observation.target == target,
            observation.isComplete,
            Set(childIDs).count == childIDs.count,
            observation.childSnapshots.allSatisfy({ $0.diskInstanceID == target })
        else {
            return false
        }
        return !childIDs.contains(ownerVolumeID)
    }

    private static func isTerminalMediaState(_ state: VolumeState) -> Bool {
        switch state {
        case .mediaInvalidated, .mediaUnavailable, .safeToRemove:
            return true
        default:
            return false
        }
    }

    private func revokeSiblingWorkflowsAfterVerifiedAbsence(
        ownerVolumeID: VolumeID,
        diskInstanceID: DiskInstanceID
    ) {
        let event = DiskLifecycleEvent.mediaRemoved(expected: diskInstanceID)
        let siblingIDs = snapshots.values
            .filter { snapshot in
                snapshot.diskInstanceID == diskInstanceID
                    && snapshot.id != ownerVolumeID
            }
            .map(\.id)
        for siblingID in siblingIDs {
            guard var siblingWorkflow = workflows[siblingID] else {
                continue
            }
            _ = siblingWorkflow.handleDiskLifecycleEvent(event)
            workflows[siblingID] = siblingWorkflow
        }
    }

    private func beginOperation(
        target: VolumeInstanceID,
        event: (OperationID) -> VolumeEvent
    ) -> WorkflowResult {
        guard
            var workflow = workflows[target.volumeID],
            let snapshot = snapshots[target.volumeID],
            snapshot.instanceID == target
        else {
            return .rejected(.volumeUnavailable)
        }
        guard activeOperations[snapshot.physicalDiskID] == nil else {
            return .rejected(.operationInProgress)
        }

        nextOperationSequence &+= 1
        let operationID = OperationID(
            rawValue: "\(operationNamespace.uuidString)-\(nextOperationSequence)"
        )
        let result = workflow.handle(event(operationID))
        workflows[target.volumeID] = workflow
        if workflow.activeOperationID == operationID {
            let expectedMutation: MutationCommand?
            if case let .accepted(effect) = result {
                expectedMutation = MutationPreflight.command(for: effect)
            } else {
                expectedMutation = nil
            }
            activeOperations[snapshot.physicalDiskID] = ActiveOperationLease(
                operationID: operationID,
                diskInstanceID: snapshot.diskInstanceID,
                ownerVolumeID: target.volumeID,
                expectedMutation: expectedMutation,
                claimedMutation: nil,
                claimedMutationIsExecuting: false,
                lifecycleInvalidated: false,
                mediaRemovalObserved: false
            )
        }
        return result
    }

    private func safeEjectAvailability(
        for selectedSnapshot: VolumeSnapshot
    ) -> SafeEjectAvailability {
        if selectedSnapshot.role == .protected {
            return .blocked(.protectedDisk)
        }
        if selectedSnapshot.role == .bootCamp {
            return .blocked(.bootCampDisk)
        }
        if selectedSnapshot.location == .internal {
            return .blocked(.internalDisk)
        }
        let siblings = snapshots.values.filter { snapshot in
            snapshot.physicalDiskID == selectedSnapshot.physicalDiskID
        }
        guard siblings.allSatisfy({ snapshot in
            snapshot.diskInstanceID == selectedSnapshot.diskInstanceID
        }) else {
            return .temporarilyUnavailable
        }
        if siblings.contains(where: { snapshot in
            snapshot.location == .internal || snapshot.role.isProtected
        }) {
            return .blocked(.protectedSibling)
        }
        guard let physicalDiskSafety = physicalDiskSafetyByInstance[
            selectedSnapshot.diskInstanceID
        ], physicalDiskSafety.isComplete else {
            return .temporarilyUnavailable
        }
        guard physicalDiskSafety.permitsSoftwareEject else {
            return .blocked(.notEjectable)
        }
        return .available
    }

    private static func indexedPhysicalDiskSafety(
        _ snapshots: [PhysicalDiskSafetySnapshot]
    ) -> [DiskInstanceID: PhysicalDiskSafetySnapshot] {
        var result: [DiskInstanceID: PhysicalDiskSafetySnapshot] = [:]
        var conflictedIDs: Set<DiskInstanceID> = []
        for snapshot in snapshots where !conflictedIDs.contains(snapshot.diskInstanceID) {
            if let existing = result[snapshot.diskInstanceID], existing != snapshot {
                result[snapshot.diskInstanceID] = nil
                conflictedIDs.insert(snapshot.diskInstanceID)
            } else {
                result[snapshot.diskInstanceID] = snapshot
            }
        }
        return result
    }

    private func settleRejectedPreflight(
        command: MutationCommand,
        failure: MutationPreflightFailure
    ) {
        if let identityChange = Self.mediaIdentityChange(for: failure) {
            if identityChange.expected.physicalDiskID
                == identityChange.observed.physicalDiskID
            {
                _ = processDiskLifecycleEvent(
                    .mediaReplaced(
                        expected: identityChange.expected,
                        observed: identityChange.observed
                    )
                )
                return
            }
            guard
                let lease = activeOperations[command.physicalDiskID],
                lease.operationID == command.operationID,
                var workflow = workflows[lease.ownerVolumeID]
            else {
                return
            }
            _ = workflow.invalidateMedia(observed: identityChange.observed)
            workflows[lease.ownerVolumeID] = workflow
            activeOperations[command.physicalDiskID] = nil
            return
        }

        guard
            let lease = activeOperations[command.physicalDiskID],
            lease.operationID == command.operationID,
            var workflow = workflows[lease.ownerVolumeID],
            workflow.settleRejectedPreflight(command: command, failure: failure)
        else {
            return
        }
        workflows[lease.ownerVolumeID] = workflow
        activeOperations[command.physicalDiskID] = nil
    }

    private func settleMissingOwner(command: MutationCommand) {
        guard
            let lease = activeOperations[command.physicalDiskID],
            lease.operationID == command.operationID,
            var workflow = workflows[lease.ownerVolumeID]
        else {
            return
        }
        _ = workflow.handleDiskLifecycleEvent(
            .mediaRemoved(expected: lease.diskInstanceID)
        )
        workflows[lease.ownerVolumeID] = workflow
        activeOperations[command.physicalDiskID] = nil
    }

    private static func mediaIdentityChange(
        for failure: MutationPreflightFailure
    ) -> (expected: DiskInstanceID, observed: DiskInstanceID)? {
        guard case let .targetChanged(expectedTarget, observedTarget) = failure else {
            return nil
        }
        let expected: DiskInstanceID
        let observed: DiskInstanceID
        switch (expectedTarget, observedTarget) {
        case let (.volume(expectedVolume), .volume(observedVolume)):
            expected = expectedVolume.diskInstanceID
            observed = observedVolume.diskInstanceID
        case let (.disk(expectedDisk), .disk(observedDisk)):
            expected = expectedDisk
            observed = observedDisk
        default:
            return nil
        }
        guard expected != observed else {
            return nil
        }
        return (expected, observed)
    }

    private static func isMutationSuccessEvent(_ event: VolumeEvent) -> Bool {
        switch event {
        case .unmountSucceeded, .mountCommandSucceeded,
            .ejectUnmountCommandSucceeded, .ejectCommandSucceeded:
            return true
        default:
            return false
        }
    }

    private static func isMutationQuiescenceEvent(_ event: VolumeEvent) -> Bool {
        switch event {
        case .writeMutationQuiesced, .ejectMutationQuiesced:
            return true
        default:
            return false
        }
    }

    private static func isMutationFailureEvent(_ event: VolumeEvent) -> Bool {
        switch event {
        case .ejectUnmountCommandFailed, .ejectCommandFailed:
            return true
        case let .writeOperationFailed(_, stage, _):
            return stage == .unmountingReadOnly || stage == .mountingWrite
        default:
            return false
        }
    }

    private static func successEvent(
        _ event: VolumeEvent,
        matches command: MutationCommand?,
        operationID: OperationID
    ) -> Bool {
        guard let command else {
            return false
        }
        switch (event, command) {
        case let (
            .unmountSucceeded(observedOperationID),
            .unmountVolumeStandard(expectedOperationID, _)
        ):
            return
                observedOperationID == expectedOperationID
                    && expectedOperationID == operationID
        case let (.mountCommandSucceeded(observedOperationID), .mountWrite(plan)):
            return observedOperationID == plan.operationID && plan.operationID == operationID
        case let (
            .ejectUnmountCommandSucceeded(observedOperationID),
            .unmountDiskStandard(expectedOperationID, _)
        ):
            return
                observedOperationID == expectedOperationID
                    && expectedOperationID == operationID
        case let (
            .ejectCommandSucceeded(observedOperationID),
            .ejectDiskStandard(expectedOperationID, _)
        ):
            return
                observedOperationID == expectedOperationID
                    && expectedOperationID == operationID
        default:
            return false
        }
    }

    private static func failureEvent(
        _ event: VolumeEvent,
        matches command: MutationCommand?,
        operationID: OperationID
    ) -> Bool {
        guard let command else {
            return false
        }
        switch (event, command) {
        case let (
            .writeOperationFailed(observedOperationID, .unmountingReadOnly, _),
            .unmountVolumeStandard(expectedOperationID, _)
        ):
            return
                observedOperationID == expectedOperationID
                    && expectedOperationID == operationID
        case let (
            .writeOperationFailed(observedOperationID, .mountingWrite, _),
            .mountWrite(plan)
        ):
            return observedOperationID == plan.operationID && plan.operationID == operationID
        case let (
            .ejectUnmountCommandFailed(observedOperationID, _),
            .unmountDiskStandard(expectedOperationID, _)
        ):
            return
                observedOperationID == expectedOperationID
                    && expectedOperationID == operationID
        case let (
            .ejectCommandFailed(observedOperationID, _),
            .ejectDiskStandard(expectedOperationID, _)
        ):
            return
                observedOperationID == expectedOperationID
                    && expectedOperationID == operationID
        default:
            return false
        }
    }
}
