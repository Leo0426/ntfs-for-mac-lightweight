import Darwin
import CryptoKit
import Foundation
import NTFSLiteCore
import NTFSLiteDiagnostics
import NTFSLiteGateEvidence
import NTFSLiteHelperProtocol
import NTFSLiteMutationPreparation
import NTFSLitePresentation
import NTFSLiteReadOnlyProbing
import NTFSLiteSystem

let gate1FixtureEvidenceID = "G1-0123456789ABCDEF0123456789ABCDEF"

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("CHECK FAILED: \(message)")
    }
}

func expectAsync(
    _ condition: @autoclosure () async -> Bool,
    _ message: String
) async {
    guard await condition() else {
        fatalError("CHECK FAILED: \(message)")
    }
}

func makeSnapshot(
    uuid: String,
    bsdName: String,
    displayName: String,
    physicalDiskID: PhysicalDiskID = PhysicalDiskID(rawValue: "physical-disk"),
    mediaGeneration: MediaGeneration = MediaGeneration(rawValue: 1),
    fileSystem: FileSystemKind = .ntfs,
    location: VolumeLocation = .external,
    role: VolumeRole = .data,
    health: VolumeHealth = .clean,
    mountAccess: MountAccess = .readOnly
) -> VolumeSnapshot {
    VolumeSnapshot(
        id: VolumeID(uuid: uuid, bsdName: bsdName),
        physicalDiskID: physicalDiskID,
        mediaGeneration: mediaGeneration,
        displayName: displayName,
        fileSystem: fileSystem,
        location: location,
        role: role,
        health: health,
        mountAccess: mountAccess
    )
}

func readySetupFacts() -> SetupFacts {
    SetupFacts(
        macOSVersion: SemanticVersion(major: 15, minor: 4, patch: 0),
        architecture: .appleSilicon,
        macFUSEVersion: SemanticVersion(major: 5, minor: 3, patch: 3),
        ntfs3GVersion: SemanticVersion(major: 2026, minor: 7, patch: 7),
        fileSystemExtensionEnabled: true,
        selectedBackend: .fsKit,
        authorizationStatus: .granted,
        conflictScanComplete: true,
        conflictingDrivers: []
    )
}

actor MutableSetupFactsStore {
    private var facts: SetupFacts

    init(_ facts: SetupFacts) {
        self.facts = facts
    }

    func current() -> SetupFacts {
        facts
    }

    func replace(with facts: SetupFacts) {
        self.facts = facts
    }
}

actor SuspendedSetupFactsStore {
    private var hasStarted = false
    private var isReleased = false

    func current() async -> SetupFacts {
        hasStarted = true
        while !isReleased {
            await Task.yield()
        }
        return readySetupFacts()
    }

    func waitUntilStarted() async {
        while !hasStarted {
            await Task.yield()
        }
    }

    func release() {
        isReleased = true
    }
}

actor SuspendedSecondSetupFactsStore {
    private var callCount = 0
    private var secondCallStarted = false
    private var secondCallReleased = false

    func current() async -> SetupFacts {
        callCount += 1
        if callCount == 2 {
            secondCallStarted = true
            while !secondCallReleased {
                await Task.yield()
            }
        }
        return readySetupFacts()
    }

    func waitUntilSecondCallStarted() async {
        while !secondCallStarted {
            await Task.yield()
        }
    }

    func releaseSecondCall() {
        secondCallReleased = true
    }
}

final class LockedRunIDGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else {
            fatalError("CHECK FAILED: run ID fixture was exhausted")
        }
        return values.removeFirst()
    }
}

final class LockedDateSource: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(secondsSince1970: TimeInterval) {
        value = Date(timeIntervalSince1970: secondsSince1970)
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(secondsSince1970: TimeInterval) {
        lock.lock()
        value = Date(timeIntervalSince1970: secondsSince1970)
        lock.unlock()
    }
}

final class LockedMountTableSnapshotSource: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<SystemMountTableSnapshot, SystemMountTableReadError>]

    init(_ results: [Result<SystemMountTableSnapshot, SystemMountTableReadError>]) {
        self.results = results
    }

    func next() throws -> SystemMountTableSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard !results.isEmpty else {
            throw SystemMountTableReadError.changedDuringRead
        }
        return try results.removeFirst().get()
    }
}

final class LockedIOMediaSnapshotSource: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<IOMediaEnumerationSnapshot, IOMediaEnumerationReadError>]

    init(_ results: [Result<IOMediaEnumerationSnapshot, IOMediaEnumerationReadError>]) {
        self.results = results
    }

    func next() throws -> IOMediaEnumerationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard !results.isEmpty else {
            throw IOMediaEnumerationReadError.changedDuringRead
        }
        return try results.removeFirst().get()
    }
}

actor MutableVolumeEvidenceStore {
    private var snapshot: VolumeSnapshot

    init(_ snapshot: VolumeSnapshot) {
        self.snapshot = snapshot
    }

    func current() -> MutationPreflightEvidence {
        volumeMutationEvidence(snapshot)
    }

    func replace(with snapshot: VolumeSnapshot) {
        self.snapshot = snapshot
    }
}

func readySetupFactsProvider() -> SetupFactsProvider {
    SetupFactsProvider {
        readySetupFacts()
    }
}

/// CoreChecks fixtures explicitly model a software-ejectable physical disk
/// unless a test supplies another disk-safety snapshot itself.
func makeCoordinator(
    snapshots: [VolumeSnapshot],
    setupFactsProvider: SetupFactsProvider
) -> VolumeCoordinator {
    let physicalDiskSafetySnapshots = Set(snapshots.map(\.diskInstanceID)).map {
        PhysicalDiskSafetySnapshot(
            diskInstanceID: $0,
            ejectability: .ejectable,
            removability: .removable
        )
    }
    return VolumeCoordinator(
        snapshots: snapshots,
        physicalDiskSafetySnapshots: physicalDiskSafetySnapshots,
        setupFactsProvider: setupFactsProvider
    )
}

func makeDiskMutationObservation(
    target: DiskInstanceID,
    isComplete: Bool,
    childSnapshots: [VolumeSnapshot],
    physicalDiskSafety: PhysicalDiskSafetySnapshot? = nil
) -> DiskMutationObservation {
    DiskMutationObservation(
        target: target,
        isComplete: isComplete,
        childSnapshots: childSnapshots,
        physicalDiskSafety: physicalDiskSafety ?? PhysicalDiskSafetySnapshot(
            diskInstanceID: target,
            ejectability: .ejectable,
            removability: .removable
        )
    )
}

func volumeMutationEvidence(
    _ snapshot: VolumeSnapshot,
    isComplete: Bool = true
) -> MutationPreflightEvidence {
    .volume(
        VolumeMutationObservation(
            snapshot: snapshot,
            isComplete: isComplete
        )
    )
}

func present(
    _ state: VolumeState,
    safeEjectAvailability: SafeEjectAvailability = .available
) -> VolumePresentation {
    VolumePresenter.presentation(
        for: VolumeStatusSnapshot(
            state: state,
            safeEjectAvailability: safeEjectAvailability
        )
    )
}

func healthyExternalNTFSVolumeCanBeginEnablingWrite() {
    let snapshot = makeSnapshot(uuid: "A1B2-C3D4", bsdName: "disk4s1", displayName: "WORK-SSD")
    var workflow = VolumeWorkflow(snapshot: snapshot)
    let operationID = OperationID(rawValue: "enable-write-1")

    let result = workflow.handle(.enableWritingRequested(operationID: operationID))

    expect(
        result == .accepted(
            .unmountStandard(
                operationID: operationID,
                target: snapshot.instanceID
            )
        ),
        "healthy external NTFS volume should begin with a standard unmount"
    )
    expect(workflow.state == .unmountingForWrite, "workflow should expose the unmounting-for-write state")
}

func hibernatedVolumeCannotBeginEnablingWrite() {
    let snapshot = makeSnapshot(
        uuid: "HIBERNATED-1",
        bsdName: "disk5s1",
        displayName: "WINDOWS-DATA",
        health: .hibernated
    )
    var workflow = VolumeWorkflow(snapshot: snapshot)

    expect(
        workflow.state == .writeBlocked(.windowsHibernated),
        "hibernated volume should expose the Windows hibernation block"
    )

    let result = workflow.handle(.enableWritingRequested(operationID: OperationID(rawValue: "blocked-1")))

    expect(
        result == .rejected(.writeBlocked(.windowsHibernated)),
        "hibernated volume should reject write enablement"
    )
    expect(
        workflow.state == .writeBlocked(.windowsHibernated),
        "a rejected request must not change the blocked state"
    )
}

func unsafeAndOutOfScopeVolumesExposeSpecificWriteBlocks() {
    let cases: [(String, VolumeSnapshot, WriteBlockReason)] = [
        (
            "dirty file system",
            makeSnapshot(
                uuid: "BOUNDARY-1",
                bsdName: "disk6s1",
                displayName: "DIRTY",
                health: .dirty
            ),
            .dirtyFileSystem
        ),
        (
            "unknown health",
            makeSnapshot(
                uuid: "BOUNDARY-1",
                bsdName: "disk6s1",
                displayName: "UNKNOWN",
                health: .unknown
            ),
            .healthUnknown
        ),
        (
            "internal volume",
            makeSnapshot(
                uuid: "BOUNDARY-1",
                bsdName: "disk6s1",
                displayName: "INTERNAL",
                location: .internal,
            ),
            .internalVolume
        ),
        (
            "Boot Camp volume",
            makeSnapshot(
                uuid: "BOUNDARY-1",
                bsdName: "disk6s1",
                displayName: "BOOTCAMP",
                location: .internal,
                role: .bootCamp
            ),
            .bootCampVolume
        ),
        (
            "generic protected volume",
            makeSnapshot(
                uuid: "BOUNDARY-1",
                bsdName: "disk6s1",
                displayName: "PROTECTED",
                role: .protected
            ),
            .protectedVolume
        ),
        (
            "non-NTFS volume",
            makeSnapshot(
                uuid: "BOUNDARY-1",
                bsdName: "disk6s1",
                displayName: "EXFAT",
                fileSystem: .other
            ),
            .unsupportedFileSystem
        ),
    ]

    for (label, snapshot, reason) in cases {
        var workflow = VolumeWorkflow(snapshot: snapshot)
        expect(workflow.state == .writeBlocked(reason), "\(label) should expose its exact block reason")
        expect(
            workflow.handle(.enableWritingRequested(operationID: OperationID(rawValue: "blocked-\(label)")))
                == .rejected(.writeBlocked(reason)),
            "\(label) should reject write enablement"
        )
        expect(workflow.state == .writeBlocked(reason), "\(label) should remain blocked after rejection")
    }
}

func duplicateWriteRequestDoesNotStartAnotherOperation() {
    let snapshot = makeSnapshot(uuid: "SERIAL-1", bsdName: "disk7s1", displayName: "SERIAL")
    var workflow = VolumeWorkflow(snapshot: snapshot)

    _ = workflow.handle(.enableWritingRequested(operationID: OperationID(rawValue: "first")))
    let duplicate = workflow.handle(.enableWritingRequested(operationID: OperationID(rawValue: "second")))

    expect(
        duplicate == .rejected(.operationInProgress),
        "a second request must not emit another mutating effect"
    )
    expect(workflow.state == .unmountingForWrite, "duplicate request must not change the active operation")
}

func successfulUnmountRequestsAFreshSafetySnapshot() {
    let snapshot = makeSnapshot(uuid: "REPROBE-1", bsdName: "disk8s1", displayName: "REPROBE")
    var workflow = VolumeWorkflow(snapshot: snapshot)
    let operationID = OperationID(rawValue: "reprobe")
    _ = workflow.handle(.enableWritingRequested(operationID: operationID))

    let result = workflow.handle(.unmountSucceeded(operationID: operationID))

    expect(
        result == .accepted(
            .inspectSafetySnapshot(operationID: operationID, target: snapshot.instanceID)
        ),
        "successful unmount should request a fresh safety snapshot"
    )
    expect(
        workflow.state == .awaitingSafetySnapshot,
        "workflow should wait for safety evidence before mounting writable"
    )
}

func freshCleanUnmountedSnapshotProducesSafeMountPlan() {
    let initial = makeSnapshot(uuid: "SAFE-MOUNT-1", bsdName: "disk9s1", displayName: "SAFE-MOUNT")
    var workflow = VolumeWorkflow(snapshot: initial)
    let operationID = OperationID(rawValue: "safe-mount")
    _ = workflow.handle(.enableWritingRequested(operationID: operationID))
    _ = workflow.handle(.unmountSucceeded(operationID: operationID))

    let afterUnmount = makeSnapshot(
        uuid: initial.id.uuid,
        bsdName: initial.id.bsdName,
        displayName: initial.displayName,
        mountAccess: .unmounted
    )
    let result = workflow.handle(
        .safetySnapshotReceived(operationID: operationID, snapshot: afterUnmount)
    )

    expect(
        result == .accepted(
            .mountReadWrite(
                MountPlan(
                    operationID: operationID,
                    target: initial.instanceID,
                    policy: .fsKitCurrentUserNoRecovery
                )
            )
        ),
        "fresh clean unmounted snapshot should produce the fixed safe mount plan"
    )
    expect(workflow.state == .mountingWrite, "workflow should expose the mounting-write state")
}

func healthChangeAfterUnmountPreventsWritableMount() {
    let initial = makeSnapshot(uuid: "CHANGED-1", bsdName: "disk10s1", displayName: "CHANGED")
    var workflow = VolumeWorkflow(snapshot: initial)
    let operationID = OperationID(rawValue: "changed-health")
    _ = workflow.handle(.enableWritingRequested(operationID: operationID))
    _ = workflow.handle(.unmountSucceeded(operationID: operationID))

    let dirtyAfterUnmount = makeSnapshot(
        uuid: initial.id.uuid,
        bsdName: initial.id.bsdName,
        displayName: initial.displayName,
        health: .dirty,
        mountAccess: .unmounted
    )
    let result = workflow.handle(
        .safetySnapshotReceived(operationID: operationID, snapshot: dirtyAfterUnmount)
    )

    expect(
        result == .rejected(.writeBlocked(.dirtyFileSystem)),
        "fresh dirty evidence must reject the writable mount"
    )
    expect(
        workflow.state == .writeBlocked(.dirtyFileSystem),
        "fresh dirty evidence must replace the stale clean state"
    )
}

func changedMediaGenerationInvalidatesPendingWriteOperation() {
    let initial = makeSnapshot(
        uuid: "REINSERT-1",
        bsdName: "disk11s1",
        displayName: "REINSERT",
        physicalDiskID: PhysicalDiskID(rawValue: "disk11"),
        mediaGeneration: MediaGeneration(rawValue: 41)
    )
    var workflow = VolumeWorkflow(snapshot: initial)
    let operationID = OperationID(rawValue: "reinsert")
    _ = workflow.handle(.enableWritingRequested(operationID: operationID))
    _ = workflow.handle(.unmountSucceeded(operationID: operationID))

    let reinserted = makeSnapshot(
        uuid: initial.id.uuid,
        bsdName: initial.id.bsdName,
        displayName: initial.displayName,
        physicalDiskID: initial.physicalDiskID,
        mediaGeneration: MediaGeneration(rawValue: 42),
        mountAccess: .unmounted
    )
    let result = workflow.handle(
        .safetySnapshotReceived(operationID: operationID, snapshot: reinserted)
    )
    let mismatch = MediaInstanceMismatch(
        expected: initial.diskInstanceID,
        observed: reinserted.diskInstanceID
    )

    expect(
        result == .rejected(.mediaChanged(mismatch)),
        "a new media generation must invalidate the pending write operation"
    )
    expect(
        workflow.state == .mediaInvalidated(mismatch),
        "media replacement should require a new workflow from fresh system state"
    )
}

func staleOperationCompletionIsIgnored() {
    let snapshot = makeSnapshot(uuid: "STALE-1", bsdName: "disk12s1", displayName: "STALE")
    var workflow = VolumeWorkflow(snapshot: snapshot)
    let current = OperationID(rawValue: "current")
    _ = workflow.handle(.enableWritingRequested(operationID: current))

    let stale = workflow.handle(.unmountSucceeded(operationID: OperationID(rawValue: "old")))

    expect(stale == .ignored, "stale completion should not be reported as current progress")
    expect(workflow.state == .unmountingForWrite, "stale completion must not advance state")
    expect(
        workflow.handle(.unmountSucceeded(operationID: current))
            == .accepted(.inspectSafetySnapshot(operationID: current, target: snapshot.instanceID)),
        "current operation should remain able to advance"
    )
}

func mountCommandSuccessRequestsVerificationInsteadOfClaimingWritable() {
    let initial = makeSnapshot(uuid: "VERIFY-1", bsdName: "disk13s1", displayName: "VERIFY")
    var workflow = VolumeWorkflow(snapshot: initial)
    let operationID = OperationID(rawValue: "verify")
    _ = workflow.handle(.enableWritingRequested(operationID: operationID))
    _ = workflow.handle(.unmountSucceeded(operationID: operationID))
    _ = workflow.handle(
        .safetySnapshotReceived(
            operationID: operationID,
            snapshot: makeSnapshot(
                uuid: initial.id.uuid,
                bsdName: initial.id.bsdName,
                displayName: initial.displayName,
                mountAccess: .unmounted
            )
        )
    )

    let result = workflow.handle(.mountCommandSucceeded(operationID: operationID))

    expect(
        result == .accepted(
            .inspectWriteMount(operationID: operationID, target: initial.instanceID)
        ),
        "mount command success should request inspection of actual mount facts"
    )
    expect(
        workflow.state == .awaitingWriteVerification,
        "command success alone must not expose writable state"
    )
}

func verifiedMountFactsExposeWritableState() {
    let initial = makeSnapshot(
        uuid: "WRITABLE-1",
        bsdName: "disk14s1",
        displayName: "WRITABLE",
        physicalDiskID: PhysicalDiskID(rawValue: "disk14"),
        mediaGeneration: MediaGeneration(rawValue: 7)
    )
    var workflow = VolumeWorkflow(snapshot: initial)
    let operationID = OperationID(rawValue: "writable")
    _ = workflow.handle(.enableWritingRequested(operationID: operationID))
    _ = workflow.handle(.unmountSucceeded(operationID: operationID))
    _ = workflow.handle(
        .safetySnapshotReceived(
            operationID: operationID,
            snapshot: makeSnapshot(
                uuid: initial.id.uuid,
                bsdName: initial.id.bsdName,
                displayName: initial.displayName,
                physicalDiskID: initial.physicalDiskID,
                mediaGeneration: initial.mediaGeneration,
                mountAccess: .unmounted
            )
        )
    )
    _ = workflow.handle(.mountCommandSucceeded(operationID: operationID))

    let result = workflow.handle(
        .writeMountObserved(
            operationID: operationID,
            observation: MountObservation(
                volumeID: initial.id,
                physicalDiskID: initial.physicalDiskID,
                mediaGeneration: initial.mediaGeneration,
                access: .readWrite,
                backend: .fsKit,
                mountPoint: "/Volumes/WRITABLE",
                isComplete: true,
                sourceBSDName: initial.id.bsdName,
                isCanonical: true,
                isSymlink: false
            )
        )
    )

    expect(result == .accepted(.none), "complete matching mount evidence should be accepted")
    expect(workflow.state == .writable, "only verified mount facts should expose writable state")
}

func workflowAwaitingWriteVerification(
    uuid: String,
    bsdName: String,
    physicalDisk: String,
    generation: UInt64,
    operation: String
) -> (VolumeWorkflow, VolumeSnapshot, OperationID) {
    let initial = makeSnapshot(
        uuid: uuid,
        bsdName: bsdName,
        displayName: "VERIFY-FAILURE",
        physicalDiskID: PhysicalDiskID(rawValue: physicalDisk),
        mediaGeneration: MediaGeneration(rawValue: generation)
    )
    var workflow = VolumeWorkflow(snapshot: initial)
    let operationID = OperationID(rawValue: operation)
    _ = workflow.handle(.enableWritingRequested(operationID: operationID))
    _ = workflow.handle(.unmountSucceeded(operationID: operationID))
    _ = workflow.handle(
        .safetySnapshotReceived(
            operationID: operationID,
            snapshot: makeSnapshot(
                uuid: initial.id.uuid,
                bsdName: initial.id.bsdName,
                displayName: initial.displayName,
                physicalDiskID: initial.physicalDiskID,
                mediaGeneration: initial.mediaGeneration,
                mountAccess: .unmounted
            )
        )
    )
    _ = workflow.handle(.mountCommandSucceeded(operationID: operationID))
    return (workflow, initial, operationID)
}

func incompleteOrMismatchedMountEvidenceNeverClaimsWritable() {
    let base = makeSnapshot(
        uuid: "VERIFY-FAILURE-1",
        bsdName: "disk15s1",
        displayName: "VERIFY-FAILURE",
        physicalDiskID: PhysicalDiskID(rawValue: "disk15"),
        mediaGeneration: MediaGeneration(rawValue: 9)
    )
    let cases: [(String, MountObservation, MountVerificationFailure)] = [
        (
            "wrong volume",
            MountObservation(
                volumeID: VolumeID(uuid: "OTHER", bsdName: base.id.bsdName),
                physicalDiskID: base.physicalDiskID,
                mediaGeneration: base.mediaGeneration,
                access: .readWrite,
                backend: .fsKit,
                mountPoint: "/Volumes/VERIFY-FAILURE",
                isComplete: true,
                sourceBSDName: base.id.bsdName,
                isCanonical: true,
                isSymlink: false
            ),
            .wrongVolume
        ),
        (
            "still read only",
            MountObservation(
                volumeID: base.id,
                physicalDiskID: base.physicalDiskID,
                mediaGeneration: base.mediaGeneration,
                access: .readOnly,
                backend: .fsKit,
                mountPoint: "/Volumes/VERIFY-FAILURE",
                isComplete: true,
                sourceBSDName: base.id.bsdName,
                isCanonical: true,
                isSymlink: false
            ),
            .notReadWrite
        ),
        (
            "unexpected backend",
            MountObservation(
                volumeID: base.id,
                physicalDiskID: base.physicalDiskID,
                mediaGeneration: base.mediaGeneration,
                access: .readWrite,
                backend: .kernelExtension,
                mountPoint: "/Volumes/VERIFY-FAILURE",
                isComplete: true,
                sourceBSDName: base.id.bsdName,
                isCanonical: true,
                isSymlink: false
            ),
            .unexpectedBackend
        ),
        (
            "unknown backend",
            MountObservation(
                volumeID: base.id,
                physicalDiskID: base.physicalDiskID,
                mediaGeneration: base.mediaGeneration,
                access: .readWrite,
                backend: .unknown,
                mountPoint: "/Volumes/VERIFY-FAILURE",
                isComplete: true,
                sourceBSDName: base.id.bsdName,
                isCanonical: true,
                isSymlink: false
            ),
            .unexpectedBackend
        ),
        (
            "incomplete observation",
            MountObservation(
                volumeID: base.id,
                physicalDiskID: base.physicalDiskID,
                mediaGeneration: base.mediaGeneration,
                access: .readWrite,
                backend: .fsKit,
                mountPoint: "/Volumes/VERIFY-FAILURE",
                isComplete: false,
                sourceBSDName: base.id.bsdName,
                isCanonical: true,
                isSymlink: false
            ),
            .observationIncomplete
        ),
        (
            "source device mismatch",
            MountObservation(
                volumeID: base.id,
                physicalDiskID: base.physicalDiskID,
                mediaGeneration: base.mediaGeneration,
                access: .readWrite,
                backend: .fsKit,
                mountPoint: "/Volumes/VERIFY-FAILURE",
                isComplete: true,
                sourceBSDName: "disk99s1",
                isCanonical: true,
                isSymlink: false
            ),
            .sourceDeviceMismatch
        ),
        (
            "symlink mount point",
            MountObservation(
                volumeID: base.id,
                physicalDiskID: base.physicalDiskID,
                mediaGeneration: base.mediaGeneration,
                access: .readWrite,
                backend: .fsKit,
                mountPoint: "/Volumes/VERIFY-FAILURE",
                isComplete: true,
                sourceBSDName: base.id.bsdName,
                isCanonical: false,
                isSymlink: true
            ),
            .untrustedMountPath
        ),
        (
            "invalid mount point",
            MountObservation(
                volumeID: base.id,
                physicalDiskID: base.physicalDiskID,
                mediaGeneration: base.mediaGeneration,
                access: .readWrite,
                backend: .fsKit,
                mountPoint: "/tmp/VERIFY-FAILURE",
                isComplete: true,
                sourceBSDName: base.id.bsdName,
                isCanonical: true,
                isSymlink: false
            ),
            .invalidMountPoint
        ),
        (
            "parent-directory mount point",
            MountObservation(
                volumeID: base.id,
                physicalDiskID: base.physicalDiskID,
                mediaGeneration: base.mediaGeneration,
                access: .readWrite,
                backend: .fsKit,
                mountPoint: "/Volumes/..",
                isComplete: true,
                sourceBSDName: base.id.bsdName,
                isCanonical: true,
                isSymlink: false
            ),
            .invalidMountPoint
        ),
        (
            "control character in mount point",
            MountObservation(
                volumeID: base.id,
                physicalDiskID: base.physicalDiskID,
                mediaGeneration: base.mediaGeneration,
                access: .readWrite,
                backend: .fsKit,
                mountPoint: "/Volumes/VERIFY\nFAILURE",
                isComplete: true,
                sourceBSDName: base.id.bsdName,
                isCanonical: true,
                isSymlink: false
            ),
            .invalidMountPoint
        ),
    ]

    for (index, entry) in cases.enumerated() {
        var (workflow, _, operationID) = workflowAwaitingWriteVerification(
            uuid: base.id.uuid,
            bsdName: base.id.bsdName,
            physicalDisk: base.physicalDiskID.rawValue,
            generation: base.mediaGeneration.rawValue,
            operation: "verify-failure-\(index)"
        )
        let result = workflow.handle(
            .writeMountObserved(operationID: operationID, observation: entry.1)
        )

        expect(
            result == .rejected(.mountVerificationFailed(entry.2)),
            "\(entry.0) should return its exact verification failure"
        )
        expect(
            workflow.state == .writeVerificationFailed(entry.2),
            "\(entry.0) must not expose writable state"
        )
    }

    var (changedWorkflow, _, changedOperationID) = workflowAwaitingWriteVerification(
        uuid: base.id.uuid,
        bsdName: base.id.bsdName,
        physicalDisk: base.physicalDiskID.rawValue,
        generation: base.mediaGeneration.rawValue,
        operation: "verify-new-media"
    )
    let changedObservation = MountObservation(
        volumeID: base.id,
        physicalDiskID: base.physicalDiskID,
        mediaGeneration: MediaGeneration(rawValue: 10),
        access: .readWrite,
        backend: .fsKit,
        mountPoint: "/Volumes/VERIFY-FAILURE",
        isComplete: true,
        sourceBSDName: base.id.bsdName,
        isCanonical: true,
        isSymlink: false
    )
    let mismatch = MediaInstanceMismatch(
        expected: base.diskInstanceID,
        observed: DiskInstanceID(
            physicalDiskID: changedObservation.physicalDiskID,
            mediaGeneration: changedObservation.mediaGeneration
        )
    )
    expect(
        changedWorkflow.handle(
            .writeMountObserved(
                operationID: changedOperationID,
                observation: changedObservation
            )
        ) == .rejected(.mediaChanged(mismatch)),
        "changed media during mount verification must invalidate the operation"
    )
    expect(
        changedWorkflow.state == .mediaInvalidated(mismatch),
        "changed media must never be represented as a retryable mount verification failure"
    )
}

func workflowReadyForEject(
    uuid: String,
    bsdName: String,
    physicalDisk: String,
    generation: UInt64
) -> (VolumeWorkflow, VolumeSnapshot) {
    var (workflow, initial, writeOperationID) = workflowAwaitingWriteVerification(
        uuid: uuid,
        bsdName: bsdName,
        physicalDisk: physicalDisk,
        generation: generation,
        operation: "write-before-eject"
    )
    _ = workflow.handle(
        .writeMountObserved(
            operationID: writeOperationID,
            observation: MountObservation(
                volumeID: initial.id,
                physicalDiskID: initial.physicalDiskID,
                mediaGeneration: initial.mediaGeneration,
                access: .readWrite,
                backend: .fsKit,
                mountPoint: "/Volumes/EJECT",
                isComplete: true,
                sourceBSDName: initial.id.bsdName,
                isCanonical: true,
                isSymlink: false
            )
        )
    )
    return (workflow, initial)
}

func writableVolumeEjectBeginsByUnmountingWholePhysicalDisk() {
    var (workflow, initial) = workflowReadyForEject(
        uuid: "EJECT-1",
        bsdName: "disk16s1",
        physicalDisk: "disk16",
        generation: 12
    )
    let ejectOperationID = OperationID(rawValue: "eject-1")

    let result = workflow.handle(.ejectRequested(operationID: ejectOperationID))

    expect(
        result == .accepted(
            .unmountPhysicalDiskStandard(
                operationID: ejectOperationID,
                target: initial.diskInstanceID
            )
        ),
        "eject should begin by requesting a standard unmount of every sibling volume"
    )
    expect(
        workflow.state == .unmountingForEject,
        "eject should expose the whole-disk unmount state before any eject request"
    )
}

func unmountCallbackOnlyRequestsFreshPhysicalDiskInspection() {
    var (workflow, initial) = workflowReadyForEject(
        uuid: "EJECT-INSPECT-1",
        bsdName: "disk17s1",
        physicalDisk: "disk17",
        generation: 13
    )
    let operationID = OperationID(rawValue: "eject-inspect")
    _ = workflow.handle(.ejectRequested(operationID: operationID))

    let result = workflow.handle(.ejectUnmountCommandSucceeded(operationID: operationID))

    expect(
        result == .accepted(
            .inspectPhysicalDisk(
                operationID: operationID,
                target: initial.diskInstanceID,
                phase: .afterUnmount
            )
        ),
        "unmount callback should request fresh whole-disk facts instead of ejecting immediately"
    )
    expect(
        workflow.state == .awaitingUnmountVerification,
        "unmount callback alone must not advance to the ejecting state"
    )
}

func allSiblingVolumesUnmountedAllowsStandardEject() {
    var (workflow, initial) = workflowReadyForEject(
        uuid: "EJECT-SIBLINGS-1",
        bsdName: "disk18s1",
        physicalDisk: "disk18",
        generation: 14
    )
    let operationID = OperationID(rawValue: "eject-siblings")
    _ = workflow.handle(.ejectRequested(operationID: operationID))
    _ = workflow.handle(.ejectUnmountCommandSucceeded(operationID: operationID))
    let sibling = VolumeID(uuid: "EJECT-SIBLINGS-2", bsdName: "disk18s2")

    let result = workflow.handle(
        .ejectDiskObserved(
            operationID: operationID,
            phase: .afterUnmount,
            observation: PhysicalDiskObservation(
                physicalDiskID: initial.physicalDiskID,
                mediaGeneration: initial.mediaGeneration,
                presence: .present,
                isComplete: true,
                childVolumes: [
                    ChildVolumeObservation(volumeID: initial.id, mountAccess: .unmounted),
                    ChildVolumeObservation(volumeID: sibling, mountAccess: .unmounted),
                ]
            )
        )
    )

    expect(
        result == .accepted(
            .ejectPhysicalDiskStandard(
                operationID: operationID,
                target: initial.diskInstanceID
            )
        ),
        "only a complete fresh snapshot with every sibling unmounted should request eject"
    )
    expect(workflow.state == .ejecting, "verified unmount evidence should advance to ejecting")
}

func mountedSiblingPreventsEject() {
    var (workflow, initial) = workflowReadyForEject(
        uuid: "EJECT-BUSY-SIBLING-1",
        bsdName: "disk19s1",
        physicalDisk: "disk19",
        generation: 15
    )
    let operationID = OperationID(rawValue: "eject-busy-sibling")
    _ = workflow.handle(.ejectRequested(operationID: operationID))
    _ = workflow.handle(.ejectUnmountCommandSucceeded(operationID: operationID))
    let mountedSibling = VolumeID(uuid: "EJECT-BUSY-SIBLING-2", bsdName: "disk19s2")

    let result = workflow.handle(
        .ejectDiskObserved(
            operationID: operationID,
            phase: .afterUnmount,
            observation: PhysicalDiskObservation(
                physicalDiskID: initial.physicalDiskID,
                mediaGeneration: initial.mediaGeneration,
                presence: .present,
                isComplete: true,
                childVolumes: [
                    ChildVolumeObservation(volumeID: initial.id, mountAccess: .unmounted),
                    ChildVolumeObservation(volumeID: mountedSibling, mountAccess: .readOnly),
                ]
            )
        )
    )
    let failure = EjectFailure.volumesStillMounted([mountedSibling])

    expect(
        result == .rejected(.ejectFailed(failure)),
        "a mounted sibling must fail closed without emitting an eject effect"
    )
    expect(
        workflow.state == .ejectFailed(failure),
        "mounted sibling evidence should expose the exact blocking volume"
    )
}

func busyUnmountNeverProducesAForceOperation() {
    var (workflow, initial) = workflowReadyForEject(
        uuid: "EJECT-BUSY-1",
        bsdName: "disk20s1",
        physicalDisk: "disk20",
        generation: 16
    )
    let operationID = OperationID(rawValue: "eject-busy")
    _ = workflow.handle(.ejectRequested(operationID: operationID))

    let result = workflow.handle(
        .ejectUnmountCommandFailed(operationID: operationID, failure: .busy)
    )

    expect(
        result == .accepted(
            .inspectEjectMutationReconciliation(
                operationID: operationID,
                target: initial.diskInstanceID,
                stage: .unmountingPhysicalDisk
            )
        ),
        "busy unmount should request fresh whole-disk facts without forcing another mutation"
    )
    expect(
        workflow.state
            == .awaitingEjectMutationReconciliation(
                stage: .unmountingPhysicalDisk,
                failure: .busy
            ),
        "busy unmount must remain locked until partial-unmount effects are reconciled"
    )
}

func workflowEjecting(
    uuid: String,
    bsdName: String,
    physicalDisk: String,
    generation: UInt64,
    operation: String
) -> (VolumeWorkflow, VolumeSnapshot, OperationID) {
    var (workflow, initial) = workflowReadyForEject(
        uuid: uuid,
        bsdName: bsdName,
        physicalDisk: physicalDisk,
        generation: generation
    )
    let operationID = OperationID(rawValue: operation)
    _ = workflow.handle(.ejectRequested(operationID: operationID))
    _ = workflow.handle(.ejectUnmountCommandSucceeded(operationID: operationID))
    _ = workflow.handle(
        .ejectDiskObserved(
            operationID: operationID,
            phase: .afterUnmount,
            observation: PhysicalDiskObservation(
                physicalDiskID: initial.physicalDiskID,
                mediaGeneration: initial.mediaGeneration,
                presence: .present,
                isComplete: true,
                childVolumes: [
                    ChildVolumeObservation(volumeID: initial.id, mountAccess: .unmounted)
                ]
            )
        )
    )
    return (workflow, initial, operationID)
}

func ejectCallbackDoesNotClaimSafeToRemove() {
    var (workflow, initial, operationID) = workflowEjecting(
        uuid: "EJECT-VERIFY-1",
        bsdName: "disk21s1",
        physicalDisk: "disk21",
        generation: 17,
        operation: "eject-verify"
    )

    let result = workflow.handle(.ejectCommandSucceeded(operationID: operationID))

    expect(
        result == .accepted(
            .inspectPhysicalDisk(
                operationID: operationID,
                target: initial.diskInstanceID,
                phase: .afterEject
            )
        ),
        "eject callback should request fresh absence evidence"
    )
    expect(
        workflow.state == .awaitingRemovalVerification,
        "eject callback alone must not claim the disk is safe to remove"
    )
}

func onlyFreshMatchingAbsenceMarksSafeToRemove() {
    var (workflow, initial, operationID) = workflowEjecting(
        uuid: "EJECT-ABSENT-1",
        bsdName: "disk22s1",
        physicalDisk: "disk22",
        generation: 18,
        operation: "eject-absent"
    )
    _ = workflow.handle(.ejectCommandSucceeded(operationID: operationID))
    let absent = PhysicalDiskObservation(
        physicalDiskID: initial.physicalDiskID,
        mediaGeneration: initial.mediaGeneration,
        presence: .absent,
        isComplete: true,
        childVolumes: []
    )

    expect(
        workflow.handle(
            .ejectDiskObserved(
                operationID: OperationID(rawValue: "stale-eject"),
                phase: .afterEject,
                observation: absent
            )
        ) == .ignored,
        "stale eject operation evidence must be ignored"
    )
    expect(
        workflow.handle(
            .ejectDiskObserved(
                operationID: operationID,
                phase: .afterUnmount,
                observation: absent
            )
        ) == .ignored,
        "evidence from the wrong inspection phase must be ignored"
    )
    let replacement = PhysicalDiskObservation(
        physicalDiskID: initial.physicalDiskID,
        mediaGeneration: MediaGeneration(rawValue: 19),
        presence: .absent,
        isComplete: true,
        childVolumes: []
    )
    let mismatch = MediaInstanceMismatch(
        expected: initial.diskInstanceID,
        observed: DiskInstanceID(
            physicalDiskID: replacement.physicalDiskID,
            mediaGeneration: replacement.mediaGeneration
        )
    )
    expect(
        workflow.handle(
            .ejectDiskObserved(
                operationID: operationID,
                phase: .afterEject,
                observation: replacement
            )
        ) == .rejected(.mediaChanged(mismatch)),
        "a new media generation must invalidate eject instead of being ignored"
    )
    expect(
        workflow.state == .mediaInvalidated(mismatch),
        "replacement media must require a workflow rebuilt from fresh inventory"
    )
    expect(
        workflow.handle(
            .ejectDiskObserved(
                operationID: operationID,
                phase: .afterEject,
                observation: absent
            )
        ) == .ignored,
        "delayed absence from the old media generation must not revive an invalidated operation"
    )

    var (freshWorkflow, freshInitial, freshOperationID) = workflowEjecting(
        uuid: "EJECT-ABSENT-2",
        bsdName: "disk26s1",
        physicalDisk: "disk26",
        generation: 23,
        operation: "eject-absent-fresh"
    )
    _ = freshWorkflow.handle(.ejectCommandSucceeded(operationID: freshOperationID))
    let result = freshWorkflow.handle(
        .ejectDiskObserved(
            operationID: freshOperationID,
            phase: .afterEject,
            observation: PhysicalDiskObservation(
                physicalDiskID: freshInitial.physicalDiskID,
                mediaGeneration: freshInitial.mediaGeneration,
                presence: .absent,
                isComplete: true,
                childVolumes: []
            )
        )
    )

    expect(result == .accepted(.none), "fresh matching absence should complete eject")
    expect(freshWorkflow.state == .safeToRemove, "only verified absence should expose safe to remove")
}

func failedEjectCommandNeverClaimsSafeToRemove() {
    var (workflow, initial, operationID) = workflowEjecting(
        uuid: "EJECT-COMMAND-FAIL-1",
        bsdName: "disk25s1",
        physicalDisk: "disk25",
        generation: 22,
        operation: "eject-command-fail"
    )

    let result = workflow.handle(
        .ejectCommandFailed(operationID: operationID, failure: .busy)
    )

    expect(
        result == .accepted(
            .inspectEjectMutationReconciliation(
                operationID: operationID,
                target: initial.diskInstanceID,
                stage: .ejectingPhysicalDisk
            )
        ),
        "failed eject command should request fresh whole-disk reconciliation"
    )
    expect(
        workflow.state
            == .awaitingEjectMutationReconciliation(
                stage: .ejectingPhysicalDisk,
                failure: .busy
            ),
        "failed eject command must keep the disk locked and never claim safe removal"
    )
}

func writeBlocksNeverPreventSafeEject() {
    let cases: [(String, VolumeSnapshot)] = [
        (
            "read-only ready",
            makeSnapshot(
                uuid: "EJECT-STABLE-1",
                bsdName: "disk23s1",
                displayName: "READ-ONLY",
                physicalDiskID: PhysicalDiskID(rawValue: "disk23"),
                mediaGeneration: MediaGeneration(rawValue: 20)
            )
        ),
        (
            "Windows hibernated",
            makeSnapshot(
                uuid: "EJECT-BLOCKED-1",
                bsdName: "disk24s1",
                displayName: "HIBERNATED",
                physicalDiskID: PhysicalDiskID(rawValue: "disk24"),
                mediaGeneration: MediaGeneration(rawValue: 21),
                health: .hibernated
            )
        ),
    ]

    for (index, entry) in cases.enumerated() {
        var workflow = VolumeWorkflow(snapshot: entry.1)
        let operationID = OperationID(rawValue: "safe-eject-blocked-\(index)")

        let result = workflow.handle(.ejectRequested(operationID: operationID))

        expect(
            result == .accepted(
                .unmountPhysicalDiskStandard(
                    operationID: operationID,
                    target: entry.1.diskInstanceID
                )
            ),
            "\(entry.0) should still be eligible for safe eject"
        )
        expect(
            workflow.state == .unmountingForEject,
            "\(entry.0) should enter the normal safe-eject flow"
        )
    }
}

func internalAndBootCampVolumesNeverEmitWholeDiskEjectMutations() {
    let cases: [(VolumeSnapshot, EjectBlockReason)] = [
        (
            makeSnapshot(
                uuid: "INTERNAL-EJECT-1",
                bsdName: "disk0s9",
                displayName: "INTERNAL",
                physicalDiskID: PhysicalDiskID(rawValue: "disk0"),
                location: .internal
            ),
            .internalDisk
        ),
        (
            makeSnapshot(
                uuid: "BOOTCAMP-EJECT-1",
                bsdName: "disk0s10",
                displayName: "BOOTCAMP",
                physicalDiskID: PhysicalDiskID(rawValue: "disk0"),
                location: .internal,
                role: .bootCamp
            ),
            .bootCampDisk
        ),
        (
            makeSnapshot(
                uuid: "PROTECTED-EJECT-1",
                bsdName: "disk40s1",
                displayName: "PROTECTED",
                physicalDiskID: PhysicalDiskID(rawValue: "disk40"),
                role: .protected
            ),
            .protectedDisk
        ),
    ]

    for (index, entry) in cases.enumerated() {
        var workflow = VolumeWorkflow(snapshot: entry.0)
        let result = workflow.handle(
            .ejectRequested(operationID: OperationID(rawValue: "protected-eject-\(index)"))
        )
        expect(
            result == .rejected(.ejectBlocked(entry.1)),
            "protected internal storage must reject whole-disk eject explicitly"
        )
        expect(workflow.activeOperationID == nil, "protected storage must not acquire an eject lease")

        let presentation = present(workflow.state)
        expect(
            !presentation.secondaryActions.contains(.safeEject),
            "the UI must not offer safe eject for internal or Boot Camp storage"
        )
    }
}

func ejectabilityEvidenceGatesCoordinatorAndFinalPreflight() async {
    let snapshot = makeSnapshot(
        uuid: "EJECTABILITY-1",
        bsdName: "disk70s1",
        displayName: "EJECTABILITY",
        physicalDiskID: PhysicalDiskID(rawValue: "disk70"),
        mediaGeneration: MediaGeneration(rawValue: 70)
    )
    func safety(
        ejectability: PhysicalDiskEjectability,
        removability: PhysicalDiskRemovability
    ) -> PhysicalDiskSafetySnapshot {
        PhysicalDiskSafetySnapshot(
            diskInstanceID: snapshot.diskInstanceID,
            ejectability: ejectability,
            removability: removability
        )
    }
    func coordinator(_ diskSafety: PhysicalDiskSafetySnapshot?) -> VolumeCoordinator {
        VolumeCoordinator(
            snapshots: [snapshot],
            physicalDiskSafetySnapshots: diskSafety.map { [$0] } ?? [],
            setupFactsProvider: readySetupFactsProvider()
        )
    }

    let unknown = coordinator(nil)
    await expectAsync(
        await unknown.requestEject(target: snapshot.instanceID)
            == .rejected(.volumeUnavailable),
        "missing physical-disk ejectability must keep safe eject unavailable"
    )

    let notEjectable = safety(ejectability: .notEjectable, removability: .removable)
    let blocked = coordinator(notEjectable)
    await expectAsync(
        await blocked.requestEject(target: snapshot.instanceID)
            == .rejected(.ejectBlocked(.notEjectable)),
        "known non-ejectable media must expose a durable safe-eject block"
    )

    let contradictory = coordinator(
        safety(ejectability: .ejectable, removability: .notRemovable)
    )
    await expectAsync(
        await contradictory.requestEject(target: snapshot.instanceID)
            == .rejected(.volumeUnavailable),
        "ejectable without removable contradicts Apple IOMedia evidence and must fail closed"
    )

    let initiallySafe = safety(ejectability: .ejectable, removability: .removable)
    let preflightCoordinator = coordinator(initiallySafe)
    guard case let .accepted(effect) = await preflightCoordinator.requestEject(
        target: snapshot.instanceID
    ) else {
        fatalError("CHECK FAILED: complete ejectable evidence should begin safe eject")
    }
    let probe = MutationInvocationProbe()
    await expectAsync(
        await preflightCoordinator.executeMutation(
            effect: effect,
            resolveEvidence: {
                .disk(
                    makeDiskMutationObservation(
                        target: snapshot.diskInstanceID,
                        isComplete: true,
                        childSnapshots: [snapshot],
                        physicalDiskSafety: notEjectable
                    )
                )
            },
            invoke: { _ in await probe.invokeImmediately() }
        ) == .rejected(.ejectBlocked(.notEjectable)),
        "fresh non-ejectable evidence must revoke a previously available eject intent"
    )
    await expectAsync(
        await probe.invocationCount == 0,
        "revoked ejectability must invoke no disk mutation"
    )
}

func coordinatorAndPreflightRejectAProtectedSibling() async {
    let physicalDiskID = PhysicalDiskID(rawValue: "mixed-scope-disk")
    let generation = MediaGeneration(rawValue: 35)
    let selected = makeSnapshot(
        uuid: "MIXED-SCOPE-1",
        bsdName: "disk39s1",
        displayName: "EXTERNAL-SELECTION",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let protectedSibling = makeSnapshot(
        uuid: "MIXED-SCOPE-2",
        bsdName: "disk39s2",
        displayName: "PROTECTED-SIBLING",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        role: .protected
    )
    let blockedCoordinator = makeCoordinator(
        snapshots: [selected, protectedSibling],
        setupFactsProvider: readySetupFactsProvider()
    )
    await expectAsync(
        await blockedCoordinator.requestEject(target: selected.instanceID)
            == .rejected(.ejectBlocked(.protectedSibling)),
        "whole-disk eject must inspect every known sibling before creating a lease"
    )
    guard let blockedStatus = await blockedCoordinator.status(for: selected.id) else {
        fatalError("CHECK FAILED: protected sibling should retain a presentation status")
    }
    let blockedPresentation = VolumePresenter.presentation(for: blockedStatus)
    expect(
        blockedPresentation.primaryAction != .safeEject
            && !blockedPresentation.secondaryActions.contains(.safeEject),
        "a protected sibling must hide safe eject before the user can request it"
    )

    let preflightCoordinator = makeCoordinator(
        snapshots: [selected],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(effect) = await preflightCoordinator.requestEject(
        target: selected.instanceID
    ) else {
        fatalError("CHECK FAILED: a purely external disk should begin safe eject")
    }
    let probe = MutationInvocationProbe()
    await expectAsync(
        await preflightCoordinator.executeMutation(
            effect: effect,
            resolveEvidence: {
                .disk(
                    makeDiskMutationObservation(
                        target: selected.diskInstanceID,
                        isComplete: true,
                        childSnapshots: [selected, protectedSibling]
                    )
                )
            },
            invoke: { _ in await probe.invokeImmediately() }
        ) == .rejected(.ejectBlocked(.protectedSibling)),
        "a protected sibling discovered immediately before execution must revoke eject authorization"
    )
    await expectAsync(
        await probe.invocationCount == 0,
        "protected sibling preflight must invoke no disk mutation"
    )
    await expectAsync(
        await preflightCoordinator.state(for: selected.id)
            == .ejectBlocked(.protectedSibling),
        "a newly discovered protected sibling must remain visible as the durable block reason"
    )
    await expectAsync(
        await preflightCoordinator.rebuildInventory(snapshots: [selected]) == .rebuilt,
        "a rejected protected-disk preflight must release its unexecuted lease"
    )
}

func ejectPreflightRejectsAChildThatRemountedAfterInspection() async {
    let initial = makeSnapshot(
        uuid: "EJECT-PREFLIGHT-1",
        bsdName: "disk41s1",
        displayName: "EJECT-PREFLIGHT",
        physicalDiskID: PhysicalDiskID(rawValue: "disk41"),
        mediaGeneration: MediaGeneration(rawValue: 41)
    )
    let coordinator = makeCoordinator(
        snapshots: [initial],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(unmountEffect) = await coordinator.requestEject(
        target: initial.instanceID
    ) else {
        fatalError("CHECK FAILED: external disk should begin safe eject")
    }
    guard case let .unmountPhysicalDiskStandard(operationID, _) = unmountEffect else {
        fatalError("CHECK FAILED: safe eject should begin with a whole-disk unmount")
    }
    await expectAsync(
        await coordinator.executeMutation(
            effect: unmountEffect,
            resolveEvidence: {
                .disk(
                    makeDiskMutationObservation(
                        target: initial.diskInstanceID,
                        isComplete: true,
                        childSnapshots: [initial]
                    )
                )
            },
            invoke: { _ in .exited(terminationStatus: 0) }
        ) == .executed,
        "whole-disk unmount should pass fresh external-disk preflight"
    )
    _ = await coordinator.processSystemEvent(
        .ejectUnmountCommandSucceeded(operationID: operationID),
        volumeID: initial.id
    )
    let inspection = PhysicalDiskObservation(
        physicalDiskID: initial.physicalDiskID,
        mediaGeneration: initial.mediaGeneration,
        presence: .present,
        isComplete: true,
        childVolumes: [
            ChildVolumeObservation(volumeID: initial.id, mountAccess: .unmounted)
        ]
    )
    guard case let .accepted(ejectEffect) = await coordinator.processSystemEvent(
        .ejectDiskObserved(
            operationID: operationID,
            phase: .afterUnmount,
            observation: inspection
        ),
        volumeID: initial.id
    ) else {
        fatalError("CHECK FAILED: complete unmounted inspection should produce eject")
    }

    let remounted = makeSnapshot(
        uuid: initial.id.uuid,
        bsdName: initial.id.bsdName,
        displayName: initial.displayName,
        physicalDiskID: initial.physicalDiskID,
        mediaGeneration: initial.mediaGeneration,
        mountAccess: .readOnly
    )
    let probe = MutationInvocationProbe()
    let mountedFailure = EjectFailure.volumesStillMounted([initial.id])
    await expectAsync(
        await coordinator.executeMutation(
            effect: ejectEffect,
            resolveEvidence: {
                .disk(
                    makeDiskMutationObservation(
                        target: initial.diskInstanceID,
                        isComplete: true,
                        childSnapshots: [remounted]
                    )
                )
            },
            invoke: { _ in await probe.invokeImmediately() }
        ) == .rejected(.ejectNotReady(mountedFailure)),
        "eject preflight must reject a child that remounted after the prior inspection"
    )
    await expectAsync(
        await probe.invocationCount == 0,
        "a remounted child must produce zero physical eject invocations"
    )
    await expectAsync(
        await coordinator.state(for: initial.id) == .ejectFailed(mountedFailure),
        "preflight rejection must expose the mounted child and release the consumed eject lease"
    )
    await expectAsync(
        await coordinator.rebuildInventory(snapshots: [remounted]) == .rebuilt,
        "a remounted-child preflight rejection must release its unexecuted lease"
    )
}

func coordinatorReadyForFinalEject(
    selected: VolumeSnapshot,
    sibling: VolumeSnapshot
) async -> (
    coordinator: VolumeCoordinator,
    operationID: OperationID,
    ejectEffect: VolumeEffect,
    unmountedSnapshots: [VolumeSnapshot]
) {
    let coordinator = makeCoordinator(
        snapshots: [selected, sibling],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(unmountEffect) = await coordinator.requestEject(
        target: selected.instanceID
    ) else {
        fatalError("CHECK FAILED: whole-disk eject setup should begin with unmount")
    }
    guard case let .unmountPhysicalDiskStandard(operationID, _) = unmountEffect else {
        fatalError("CHECK FAILED: expected a whole-disk unmount effect")
    }
    guard
        await coordinator.executeMutation(
            effect: unmountEffect,
            resolveEvidence: {
                .disk(
                    makeDiskMutationObservation(
                        target: selected.diskInstanceID,
                        isComplete: true,
                        childSnapshots: [selected, sibling]
                    )
                )
            },
            invoke: { _ in .exited(terminationStatus: 0) }
        ) == .executed
    else {
        fatalError("CHECK FAILED: whole-disk unmount should execute")
    }
    _ = await coordinator.processSystemEvent(
        .ejectUnmountCommandSucceeded(operationID: operationID),
        volumeID: selected.id
    )
    let unmountedSelected = makeSnapshot(
        uuid: selected.id.uuid,
        bsdName: selected.id.bsdName,
        displayName: selected.displayName,
        physicalDiskID: selected.physicalDiskID,
        mediaGeneration: selected.mediaGeneration,
        mountAccess: .unmounted
    )
    let unmountedSibling = makeSnapshot(
        uuid: sibling.id.uuid,
        bsdName: sibling.id.bsdName,
        displayName: sibling.displayName,
        physicalDiskID: sibling.physicalDiskID,
        mediaGeneration: sibling.mediaGeneration,
        mountAccess: .unmounted
    )
    let inspection = PhysicalDiskObservation(
        physicalDiskID: selected.physicalDiskID,
        mediaGeneration: selected.mediaGeneration,
        presence: .present,
        isComplete: true,
        childVolumes: [
            ChildVolumeObservation(volumeID: selected.id, mountAccess: .unmounted),
            ChildVolumeObservation(volumeID: sibling.id, mountAccess: .unmounted),
        ]
    )
    guard case let .accepted(ejectEffect) = await coordinator.processSystemEvent(
        .ejectDiskObserved(
            operationID: operationID,
            phase: .afterUnmount,
            observation: inspection
        ),
        volumeID: selected.id
    ) else {
        fatalError("CHECK FAILED: complete unmounted siblings should produce final eject")
    }
    return (
        coordinator,
        operationID,
        ejectEffect,
        [unmountedSelected, unmountedSibling]
    )
}

func verifiedWholeDiskAbsenceRevokesEverySiblingWorkflow() async {
    let physicalDiskID = PhysicalDiskID(rawValue: "disk47")
    let generation = MediaGeneration(rawValue: 48)
    let selected = makeSnapshot(
        uuid: "WHOLE-EJECT-1",
        bsdName: "disk47s1",
        displayName: "WHOLE-EJECT-1",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let sibling = makeSnapshot(
        uuid: "WHOLE-EJECT-2",
        bsdName: "disk47s2",
        displayName: "WHOLE-EJECT-2",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let prepared = await coordinatorReadyForFinalEject(
        selected: selected,
        sibling: sibling
    )
    guard let siblingStatusDuringEject = await prepared.coordinator.status(for: sibling.id) else {
        fatalError("CHECK FAILED: sibling should retain status during whole-disk eject")
    }
    let siblingPresentationDuringEject = VolumePresenter.presentation(
        for: siblingStatusDuringEject
    )
    expect(
        siblingPresentationDuringEject.isBusy
            && siblingPresentationDuringEject.primaryAction == nil
            && siblingPresentationDuringEject.secondaryActions.isEmpty
            && siblingPresentationDuringEject.detail.contains("请勿读写或断开磁盘")
            && !siblingPresentationDuringEject.detail.contains("手动启用写入"),
        "a sibling must expose no actions or cached action guidance while its disk is busy"
    )
    await expectAsync(
        await prepared.coordinator.executeMutation(
            effect: prepared.ejectEffect,
            resolveEvidence: {
                .disk(
                    makeDiskMutationObservation(
                        target: selected.diskInstanceID,
                        isComplete: true,
                        childSnapshots: prepared.unmountedSnapshots
                    )
                )
            },
            invoke: { _ in .exited(terminationStatus: 0) }
        ) == .executed,
        "final whole-disk eject should execute after every sibling remains unmounted"
    )
    _ = await prepared.coordinator.processSystemEvent(
        .ejectCommandSucceeded(operationID: prepared.operationID),
        volumeID: selected.id
    )
    let absent = PhysicalDiskObservation(
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        presence: .absent,
        isComplete: true,
        childVolumes: []
    )
    await expectAsync(
        await prepared.coordinator.processSystemEvent(
            .ejectDiskObserved(
                operationID: prepared.operationID,
                phase: .afterEject,
                observation: absent
            ),
            volumeID: selected.id
        ) == .accepted(.none),
        "complete physical-disk absence should settle the owner as safe to remove"
    )
    await expectAsync(
        await prepared.coordinator.state(for: selected.id) == .safeToRemove,
        "the selected volume should retain the verified safe-to-remove result"
    )
    await expectAsync(
        await prepared.coordinator.state(for: sibling.id) == .mediaUnavailable,
        "verified whole-disk absence must revoke every sibling workflow"
    )
    _ = await prepared.coordinator.processDiskLifecycleEvent(
        .mediaRemoved(expected: selected.diskInstanceID)
    )
    await expectAsync(
        await prepared.coordinator.state(for: selected.id) == .safeToRemove,
        "a repeated matching removal event must not erase verified safe-to-remove"
    )
}

func removalBeforeEjectCallbackStillReachesVerifiedSafeRemoval() async {
    let physicalDiskID = PhysicalDiskID(rawValue: "disk48")
    let generation = MediaGeneration(rawValue: 49)
    let selected = makeSnapshot(
        uuid: "EJECT-RACE-1",
        bsdName: "disk48s1",
        displayName: "EJECT-RACE-1",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let sibling = makeSnapshot(
        uuid: "EJECT-RACE-2",
        bsdName: "disk48s2",
        displayName: "EJECT-RACE-2",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let prepared = await coordinatorReadyForFinalEject(
        selected: selected,
        sibling: sibling
    )
    let probe = MutationInvocationProbe()
    let execution = Task {
        await prepared.coordinator.executeMutation(
            effect: prepared.ejectEffect,
            resolveEvidence: {
                .disk(
                    makeDiskMutationObservation(
                        target: selected.diskInstanceID,
                        isComplete: true,
                        childSnapshots: prepared.unmountedSnapshots
                    )
                )
            },
            invoke: { _ in await probe.invokeAndWait() }
        )
    }
    await probe.waitUntilStarted()
    await expectAsync(
        await prepared.coordinator.processDiskLifecycleEvent(
            .mediaRemoved(expected: selected.diskInstanceID)
        ) == .applied([selected.id, sibling.id]),
        "a removal event may arrive before the final eject process callback"
    )
    await probe.release()
    await expectAsync(
        await execution.value == .executed,
        "the eject process must still confirm termination after the removal event"
    )
    guard case .accepted(.inspectPhysicalDisk) = await prepared.coordinator.processSystemEvent(
        .ejectCommandSucceeded(operationID: prepared.operationID),
        volumeID: selected.id
    ) else {
        fatalError("CHECK FAILED: removal-before-callback should still request absence verification")
    }
    let stalePresent = PhysicalDiskObservation(
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        presence: .present,
        isComplete: true,
        childVolumes: [
            ChildVolumeObservation(volumeID: selected.id, mountAccess: .unmounted),
            ChildVolumeObservation(volumeID: sibling.id, mountAccess: .readOnly),
        ]
    )
    await expectAsync(
        await prepared.coordinator.processSystemEvent(
            .ejectDiskObserved(
                operationID: prepared.operationID,
                phase: .afterEject,
                observation: stalePresent
            ),
            volumeID: selected.id
        ) == .accepted(
            .inspectPhysicalDisk(
                operationID: prepared.operationID,
                target: selected.diskInstanceID,
                phase: .afterEject
            )
        ),
        "same-operation present evidence sampled before removal must trigger a fresh inspection"
    )
    await expectAsync(
        await prepared.coordinator.state(for: sibling.id) == .mediaUnavailable,
        "same-operation stale present evidence must not resurrect a removed sibling"
    )
    let absent = PhysicalDiskObservation(
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        presence: .absent,
        isComplete: true,
        childVolumes: []
    )
    _ = await prepared.coordinator.processSystemEvent(
        .ejectDiskObserved(
            operationID: prepared.operationID,
            phase: .afterEject,
            observation: absent
        ),
        volumeID: selected.id
    )
    await expectAsync(
        await prepared.coordinator.state(for: selected.id) == .safeToRemove,
        "the owner should reach safe-to-remove after fresh absence verification"
    )
    await expectAsync(
        await prepared.coordinator.state(for: sibling.id) == .mediaUnavailable,
        "the early removal event must revoke the sibling immediately"
    )
}

func failedFinalEjectKeepsEverySiblingAtItsFreshObservedMountState() async {
    let physicalDiskID = PhysicalDiskID(rawValue: "disk48-failed")
    let generation = MediaGeneration(rawValue: 491)
    let selected = makeSnapshot(
        uuid: "EJECT-FAILED-SYNC-1",
        bsdName: "disk48s3",
        displayName: "EJECT-FAILED-SYNC-1",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let sibling = makeSnapshot(
        uuid: "EJECT-FAILED-SYNC-2",
        bsdName: "disk48s4",
        displayName: "EJECT-FAILED-SYNC-2",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        mountAccess: .readWrite
    )
    let prepared = await coordinatorReadyForFinalEject(
        selected: selected,
        sibling: sibling
    )

    await expectAsync(
        await prepared.coordinator.state(for: sibling.id) == .unmountedReady,
        "a complete whole-disk observation must update every sibling before final eject"
    )
    await expectAsync(
        await prepared.coordinator.executeMutation(
            effect: prepared.ejectEffect,
            resolveEvidence: {
                .disk(
                    makeDiskMutationObservation(
                        target: selected.diskInstanceID,
                        isComplete: true,
                        childSnapshots: prepared.unmountedSnapshots
                    )
                )
            },
            invoke: { _ in .exited(terminationStatus: 0) }
        ) == .executed,
        "the final eject setup should execute"
    )
    await expectAsync(
        await prepared.coordinator.processSystemEvent(
            .ejectCommandFailed(operationID: prepared.operationID, failure: .busy),
            volumeID: selected.id
        ) == .accepted(
            .inspectEjectMutationReconciliation(
                operationID: prepared.operationID,
                target: selected.diskInstanceID,
                stage: .ejectingPhysicalDisk
            )
        ),
        "a definitive final-eject failure must request fresh whole-disk facts"
    )
    guard let siblingStatusWhileReconciling = await prepared.coordinator.status(for: sibling.id) else {
        fatalError("CHECK FAILED: sibling should remain locked during reconciliation")
    }
    expect(
        siblingStatusWhileReconciling.isPhysicalDiskBusy,
        "the final-eject failure must not release sibling actions before reconciliation"
    )
    let completePresent = PhysicalDiskObservation(
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        presence: .present,
        isComplete: true,
        childVolumes: [
            ChildVolumeObservation(volumeID: selected.id, mountAccess: .unmounted),
            ChildVolumeObservation(volumeID: sibling.id, mountAccess: .readOnly),
        ]
    )
    await expectAsync(
        await prepared.coordinator.processSystemEvent(
            .ejectMutationReconciliationObserved(
                operationID: prepared.operationID,
                observation: completePresent
            ),
            volumeID: selected.id
        ) == .rejected(.ejectFailed(.busy)),
        "complete present facts may settle the definitive final-eject failure"
    )
    await expectAsync(
        await prepared.coordinator.state(for: sibling.id) == .readOnlyReady,
        "releasing the disk lease must expose the sibling's fresh remounted state"
    )
    guard let siblingStatus = await prepared.coordinator.status(for: sibling.id) else {
        fatalError("CHECK FAILED: reconciled sibling should retain a presentation status")
    }
    let siblingPresentation = VolumePresenter.presentation(for: siblingStatus)
    expect(
        !siblingPresentation.isBusy
            && siblingPresentation.title == "当前只读"
            && siblingPresentation.primaryAction == .enableWriting,
        "after definitive eject failure, sibling actions must describe the fresh present fact"
    )
}

func malformedWholeDiskInventoriesFailClosed() async {
    let physicalDiskID = PhysicalDiskID(rawValue: "disk48-malformed")
    let generation = MediaGeneration(rawValue: 495)
    let selected = makeSnapshot(
        uuid: "EJECT-MALFORMED-1",
        bsdName: "disk48s11",
        displayName: "EJECT-MALFORMED-1",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let sibling = makeSnapshot(
        uuid: "EJECT-MALFORMED-2",
        bsdName: "disk48s12",
        displayName: "EJECT-MALFORMED-2",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let coordinator = makeCoordinator(
        snapshots: [selected, sibling],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(unmountEffect) = await coordinator.requestEject(
        target: selected.instanceID
    ), case let .unmountPhysicalDiskStandard(operationID, _) = unmountEffect else {
        fatalError("CHECK FAILED: malformed inventory setup should produce unmount")
    }
    _ = await coordinator.executeMutation(
        effect: unmountEffect,
        resolveEvidence: {
            .disk(
                makeDiskMutationObservation(
                    target: selected.diskInstanceID,
                    isComplete: true,
                    childSnapshots: [selected, sibling]
                )
            )
        },
        invoke: { _ in .exited(terminationStatus: 0) }
    )
    _ = await coordinator.processSystemEvent(
        .ejectUnmountCommandSucceeded(operationID: operationID),
        volumeID: selected.id
    )
    let duplicateObservation = PhysicalDiskObservation(
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        presence: .present,
        isComplete: true,
        childVolumes: [
            ChildVolumeObservation(volumeID: selected.id, mountAccess: .unmounted),
            ChildVolumeObservation(volumeID: selected.id, mountAccess: .unmounted),
        ]
    )
    await expectAsync(
        await coordinator.processSystemEvent(
            .ejectDiskObserved(
                operationID: operationID,
                phase: .afterUnmount,
                observation: duplicateObservation
            ),
            volumeID: selected.id
        ) == .accepted(
            .inspectPhysicalDisk(
                operationID: operationID,
                target: selected.diskInstanceID,
                phase: .afterUnmount
            )
        ),
        "duplicate child IDs cannot prove completeness and must trigger another inspection"
    )
    await expectAsync(
        await coordinator.rebuildInventory(snapshots: [selected, sibling])
            == .operationsInProgress([physicalDiskID]),
        "malformed post-unmount facts must not release the whole-disk lease"
    )

    let prepared = await coordinatorReadyForFinalEject(
        selected: selected,
        sibling: sibling
    )
    let probe = MutationInvocationProbe()
    guard let unmountedSelected = prepared.unmountedSnapshots.first else {
        fatalError("CHECK FAILED: final-eject setup should include the selected volume")
    }
    await expectAsync(
        await prepared.coordinator.executeMutation(
            effect: prepared.ejectEffect,
            resolveEvidence: {
                .disk(
                    makeDiskMutationObservation(
                        target: selected.diskInstanceID,
                        isComplete: true,
                        childSnapshots: [unmountedSelected, unmountedSelected]
                    )
                )
            },
            invoke: { _ in await probe.invokeImmediately() }
        ) == .rejected(.diskObservationIncomplete),
        "duplicate child snapshots cannot authorize the final disk mutation"
    )
    await expectAsync(
        await probe.invocationCount == 0,
        "malformed whole-disk evidence must invoke no system mutation"
    )

    let missingOwnerPrepared = await coordinatorReadyForFinalEject(
        selected: selected,
        sibling: sibling
    )
    guard let unmountedSibling = missingOwnerPrepared.unmountedSnapshots.last else {
        fatalError("CHECK FAILED: final-eject setup should include the sibling")
    }
    await expectAsync(
        await missingOwnerPrepared.coordinator.executeMutation(
            effect: missingOwnerPrepared.ejectEffect,
            resolveEvidence: {
                .disk(
                    makeDiskMutationObservation(
                        target: selected.diskInstanceID,
                        isComplete: true,
                        childSnapshots: [unmountedSibling]
                    )
                )
            },
            invoke: { _ in await probe.invokeImmediately() }
        ) == .rejected(.diskObservationIncomplete),
        "a whole-disk inventory that omits the operation owner must fail closed"
    )
    await expectAsync(
        await missingOwnerPrepared.coordinator.state(for: selected.id) == .mediaUnavailable,
        "a complete inventory that omits the owner must not offer retry for a stale target"
    )
    await expectAsync(
        await missingOwnerPrepared.coordinator.state(for: sibling.id) == .unmountedReady,
        "owner disappearance must not revoke a sibling still present in the complete inventory"
    )

    let emptyInventoryPrepared = await coordinatorReadyForFinalEject(
        selected: selected,
        sibling: sibling
    )
    let emptyInventoryProbe = MutationInvocationProbe()
    await expectAsync(
        await emptyInventoryPrepared.coordinator.executeMutation(
            effect: emptyInventoryPrepared.ejectEffect,
            resolveEvidence: {
                .disk(
                    makeDiskMutationObservation(
                        target: selected.diskInstanceID,
                        isComplete: true,
                        childSnapshots: []
                    )
                )
            },
            invoke: { _ in await emptyInventoryProbe.invokeImmediately() }
        ) == .rejected(.diskObservationIncomplete),
        "an empty whole-disk inventory cannot authorize the final disk mutation"
    )
    await expectAsync(
        await emptyInventoryProbe.invocationCount == 0,
        "empty whole-disk evidence must invoke no system mutation"
    )
    await expectAsync(
        await emptyInventoryPrepared.coordinator.state(for: selected.id) == .mediaUnavailable,
        "a complete empty inventory must revoke the missing owner target"
    )
    await expectAsync(
        await emptyInventoryPrepared.coordinator.state(for: sibling.id) == .mediaUnavailable,
        "a complete empty inventory must revoke every known missing sibling target"
    )
}

func definitiveWholeDiskUnmountFailureRequiresCompleteReconciliation() async {
    let physicalDiskID = PhysicalDiskID(rawValue: "disk48-definitive-unmount")
    let generation = MediaGeneration(rawValue: 496)
    let selected = makeSnapshot(
        uuid: "EJECT-DEFINITIVE-UNMOUNT-1",
        bsdName: "disk48s13",
        displayName: "EJECT-DEFINITIVE-UNMOUNT-1",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let sibling = makeSnapshot(
        uuid: "EJECT-DEFINITIVE-UNMOUNT-2",
        bsdName: "disk48s14",
        displayName: "EJECT-DEFINITIVE-UNMOUNT-2",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        mountAccess: .readWrite
    )
    let coordinator = makeCoordinator(
        snapshots: [selected, sibling],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(unmountEffect) = await coordinator.requestEject(
        target: selected.instanceID
    ), case let .unmountPhysicalDiskStandard(operationID, _) = unmountEffect else {
        fatalError("CHECK FAILED: definitive-unmount setup should produce a disk command")
    }
    _ = await coordinator.executeMutation(
        effect: unmountEffect,
        resolveEvidence: {
            .disk(
                makeDiskMutationObservation(
                    target: selected.diskInstanceID,
                    isComplete: true,
                    childSnapshots: [selected, sibling]
                )
            )
        },
        invoke: { _ in .exited(terminationStatus: 0) }
    )
    await expectAsync(
        await coordinator.processSystemEvent(
            .ejectUnmountCommandFailed(operationID: operationID, failure: .busy),
            volumeID: selected.id
        ) == .accepted(
            .inspectEjectMutationReconciliation(
                operationID: operationID,
                target: selected.diskInstanceID,
                stage: .unmountingPhysicalDisk
            )
        ),
        "a definitive whole-disk unmount failure must still inspect possible partial effects"
    )
    await expectAsync(
        await coordinator.state(for: selected.id)
            == .awaitingEjectMutationReconciliation(
                stage: .unmountingPhysicalDisk,
                failure: .busy
            ),
        "definitive unmount failure must keep the owner in reconciliation"
    )
    let incomplete = PhysicalDiskObservation(
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        presence: .present,
        isComplete: false,
        childVolumes: [
            ChildVolumeObservation(volumeID: selected.id, mountAccess: .unmounted)
        ]
    )
    guard case .accepted(.inspectEjectMutationReconciliation) = await coordinator
        .processSystemEvent(
            .ejectMutationReconciliationObserved(
                operationID: operationID,
                observation: incomplete
            ),
            volumeID: selected.id
        )
    else {
        fatalError("CHECK FAILED: incomplete partial-unmount facts must retry")
    }
    await expectAsync(
        await coordinator.requestEnableWriting(target: sibling.instanceID)
            == .rejected(.operationInProgress),
        "a sibling must stay locked while definitive unmount effects are unresolved"
    )
    let completePresent = PhysicalDiskObservation(
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        presence: .present,
        isComplete: true,
        childVolumes: [
            ChildVolumeObservation(volumeID: selected.id, mountAccess: .unmounted),
            ChildVolumeObservation(volumeID: sibling.id, mountAccess: .unmounted),
        ]
    )
    await expectAsync(
        await coordinator.processSystemEvent(
            .ejectMutationReconciliationObserved(
                operationID: operationID,
                observation: completePresent
            ),
            volumeID: selected.id
        ) == .rejected(.ejectFailed(.busy)),
        "complete present facts may finally settle the definitive unmount failure"
    )
    await expectAsync(
        await coordinator.state(for: sibling.id) == .unmountedReady,
        "partial whole-disk unmount effects must replace the sibling's old writable state"
    )
    guard let siblingStatus = await coordinator.status(for: sibling.id) else {
        fatalError("CHECK FAILED: reconciled sibling should remain present")
    }
    expect(
        !siblingStatus.isPhysicalDiskBusy,
        "the lease may release only after the sibling's fresh mount state is durable"
    )
}

func normalEjectInspectionsKeepTheLeaseUntilFactsAreComplete() async {
    let physicalDiskID = PhysicalDiskID(rawValue: "disk48-normal-inspection")
    let generation = MediaGeneration(rawValue: 497)
    let selected = makeSnapshot(
        uuid: "EJECT-NORMAL-INSPECTION-1",
        bsdName: "disk48s15",
        displayName: "EJECT-NORMAL-INSPECTION-1",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let sibling = makeSnapshot(
        uuid: "EJECT-NORMAL-INSPECTION-2",
        bsdName: "disk48s16",
        displayName: "EJECT-NORMAL-INSPECTION-2",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let coordinator = makeCoordinator(
        snapshots: [selected, sibling],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(unmountEffect) = await coordinator.requestEject(
        target: selected.instanceID
    ), case let .unmountPhysicalDiskStandard(operationID, _) = unmountEffect else {
        fatalError("CHECK FAILED: normal inspection setup should produce disk unmount")
    }
    _ = await coordinator.executeMutation(
        effect: unmountEffect,
        resolveEvidence: {
            .disk(
                makeDiskMutationObservation(
                    target: selected.diskInstanceID,
                    isComplete: true,
                    childSnapshots: [selected, sibling]
                )
            )
        },
        invoke: { _ in .exited(terminationStatus: 0) }
    )
    _ = await coordinator.processSystemEvent(
        .ejectUnmountCommandSucceeded(operationID: operationID),
        volumeID: selected.id
    )
    let incompleteAfterUnmount = PhysicalDiskObservation(
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        presence: .present,
        isComplete: false,
        childVolumes: []
    )
    await expectAsync(
        await coordinator.processSystemEvent(
            .ejectDiskObserved(
                operationID: operationID,
                phase: .afterUnmount,
                observation: incompleteAfterUnmount
            ),
            volumeID: selected.id
        ) == .accepted(
            .inspectPhysicalDisk(
                operationID: operationID,
                target: selected.diskInstanceID,
                phase: .afterUnmount
            )
        ),
        "incomplete post-unmount facts must retry instead of exposing cached sibling states"
    )
    await expectAsync(
        await coordinator.requestEnableWriting(target: sibling.instanceID)
            == .rejected(.operationInProgress),
        "post-unmount inspection must retain the whole-disk lease"
    )
    let absentAfterUnmount = PhysicalDiskObservation(
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        presence: .absent,
        isComplete: true,
        childVolumes: []
    )
    await expectAsync(
        await coordinator.processSystemEvent(
            .ejectDiskObserved(
                operationID: operationID,
                phase: .afterUnmount,
                observation: absentAfterUnmount
            ),
            volumeID: selected.id
        ) == .accepted(.none),
        "complete absence after whole-disk unmount should safely settle the operation"
    )
    await expectAsync(
        await coordinator.state(for: selected.id) == .safeToRemove,
        "after-unmount absence must settle the owner as safe to remove"
    )
    await expectAsync(
        await coordinator.state(for: sibling.id) == .mediaUnavailable,
        "after-unmount absence must atomically revoke every sibling"
    )

    let afterEjectDiskID = PhysicalDiskID(rawValue: "disk48-after-eject-inspection")
    let afterEjectGeneration = MediaGeneration(rawValue: 498)
    let afterEjectSelected = makeSnapshot(
        uuid: "EJECT-AFTER-INSPECTION-1",
        bsdName: "disk48s17",
        displayName: "EJECT-AFTER-INSPECTION-1",
        physicalDiskID: afterEjectDiskID,
        mediaGeneration: afterEjectGeneration
    )
    let afterEjectSibling = makeSnapshot(
        uuid: "EJECT-AFTER-INSPECTION-2",
        bsdName: "disk48s18",
        displayName: "EJECT-AFTER-INSPECTION-2",
        physicalDiskID: afterEjectDiskID,
        mediaGeneration: afterEjectGeneration
    )
    let prepared = await coordinatorReadyForFinalEject(
        selected: afterEjectSelected,
        sibling: afterEjectSibling
    )
    _ = await prepared.coordinator.executeMutation(
        effect: prepared.ejectEffect,
        resolveEvidence: {
            .disk(
                makeDiskMutationObservation(
                    target: afterEjectSelected.diskInstanceID,
                    isComplete: true,
                    childSnapshots: prepared.unmountedSnapshots
                )
            )
        },
        invoke: { _ in .exited(terminationStatus: 0) }
    )
    _ = await prepared.coordinator.processSystemEvent(
        .ejectCommandSucceeded(operationID: prepared.operationID),
        volumeID: afterEjectSelected.id
    )
    let incompleteAfterEject = PhysicalDiskObservation(
        physicalDiskID: afterEjectDiskID,
        mediaGeneration: afterEjectGeneration,
        presence: .present,
        isComplete: false,
        childVolumes: []
    )
    guard case .accepted(.inspectPhysicalDisk) = await prepared.coordinator.processSystemEvent(
        .ejectDiskObserved(
            operationID: prepared.operationID,
            phase: .afterEject,
            observation: incompleteAfterEject
        ),
        volumeID: afterEjectSelected.id
    ) else {
        fatalError("CHECK FAILED: incomplete post-eject facts must retry")
    }
    await expectAsync(
        await prepared.coordinator.requestEject(target: afterEjectSibling.instanceID)
            == .rejected(.operationInProgress),
        "post-eject inspection must retain every sibling lock"
    )
    let completePresentAfterEject = PhysicalDiskObservation(
        physicalDiskID: afterEjectDiskID,
        mediaGeneration: afterEjectGeneration,
        presence: .present,
        isComplete: true,
        childVolumes: [
            ChildVolumeObservation(volumeID: afterEjectSelected.id, mountAccess: .unmounted),
            ChildVolumeObservation(volumeID: afterEjectSibling.id, mountAccess: .readOnly),
        ]
    )
    await expectAsync(
        await prepared.coordinator.processSystemEvent(
            .ejectDiskObserved(
                operationID: prepared.operationID,
                phase: .afterEject,
                observation: completePresentAfterEject
            ),
            volumeID: afterEjectSelected.id
        ) == .rejected(.ejectFailed(.diskStillPresent)),
        "complete present facts may settle the failed post-eject verification"
    )
    await expectAsync(
        await prepared.coordinator.state(for: afterEjectSibling.id) == .readOnlyReady,
        "post-eject present facts must replace every sibling's cached mount state"
    )
}

func uncertainFinalEjectPresentReconcilesEverySibling() async {
    let physicalDiskID = PhysicalDiskID(rawValue: "disk48-present")
    let generation = MediaGeneration(rawValue: 492)
    let selected = makeSnapshot(
        uuid: "EJECT-PRESENT-SYNC-1",
        bsdName: "disk48s5",
        displayName: "EJECT-PRESENT-SYNC-1",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let sibling = makeSnapshot(
        uuid: "EJECT-PRESENT-SYNC-2",
        bsdName: "disk48s6",
        displayName: "EJECT-PRESENT-SYNC-2",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        mountAccess: .readWrite
    )
    let prepared = await coordinatorReadyForFinalEject(
        selected: selected,
        sibling: sibling
    )
    _ = await prepared.coordinator.executeMutation(
        effect: prepared.ejectEffect,
        resolveEvidence: {
            .disk(
                makeDiskMutationObservation(
                    target: selected.diskInstanceID,
                    isComplete: true,
                    childSnapshots: prepared.unmountedSnapshots
                )
            )
        },
        invoke: { _ in .exited(terminationStatus: 0) }
    )
    _ = await prepared.coordinator.processSystemEvent(
        .ejectCommandFailed(operationID: prepared.operationID, failure: .timedOut),
        volumeID: selected.id
    )
    guard case .accepted(.inspectEjectMutationReconciliation) = await prepared.coordinator
        .processSystemEvent(
            .ejectMutationQuiesced(
                operationID: prepared.operationID,
                stage: .ejectingPhysicalDisk
            ),
            volumeID: selected.id
        )
    else {
        fatalError("CHECK FAILED: uncertain final eject should request reconciliation")
    }
    let present = PhysicalDiskObservation(
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        presence: .present,
        isComplete: true,
        childVolumes: [
            ChildVolumeObservation(volumeID: selected.id, mountAccess: .unmounted),
            ChildVolumeObservation(volumeID: sibling.id, mountAccess: .readOnly),
        ]
    )
    await expectAsync(
        await prepared.coordinator.processSystemEvent(
            .ejectMutationReconciliationObserved(
                operationID: prepared.operationID,
                observation: present
            ),
            volumeID: selected.id
        ) == .rejected(.ejectFailed(.timedOut)),
        "a complete present observation should settle the uncertain final eject"
    )
    await expectAsync(
        await prepared.coordinator.state(for: sibling.id) == .readOnlyReady,
        "present reconciliation must replace the sibling's stale pre-unmount state"
    )
}

func earlyRemovalThenDefinitiveFinalEjectFailureRequiresAbsence() async {
    let physicalDiskID = PhysicalDiskID(rawValue: "disk48-removed-failure")
    let generation = MediaGeneration(rawValue: 493)
    let selected = makeSnapshot(
        uuid: "EJECT-REMOVED-FAILURE-1",
        bsdName: "disk48s7",
        displayName: "EJECT-REMOVED-FAILURE-1",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let sibling = makeSnapshot(
        uuid: "EJECT-REMOVED-FAILURE-2",
        bsdName: "disk48s8",
        displayName: "EJECT-REMOVED-FAILURE-2",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let prepared = await coordinatorReadyForFinalEject(
        selected: selected,
        sibling: sibling
    )
    let probe = MutationInvocationProbe()
    let execution = Task {
        await prepared.coordinator.executeMutation(
            effect: prepared.ejectEffect,
            resolveEvidence: {
                .disk(
                    makeDiskMutationObservation(
                        target: selected.diskInstanceID,
                        isComplete: true,
                        childSnapshots: prepared.unmountedSnapshots
                    )
                )
            },
            invoke: { _ in await probe.invokeAndWait() }
        )
    }
    await probe.waitUntilStarted()
    _ = await prepared.coordinator.processDiskLifecycleEvent(
        .mediaRemoved(expected: selected.diskInstanceID)
    )
    guard let siblingStatus = await prepared.coordinator.status(for: sibling.id) else {
        fatalError("CHECK FAILED: removed sibling should retain a presentation status")
    }
    let siblingPresentation = VolumePresenter.presentation(for: siblingStatus)
    expect(
        !siblingPresentation.isBusy && siblingPresentation.title == "磁盘已断开",
        "a removed sibling must not be hidden behind a generic same-disk busy overlay"
    )
    await probe.release()
    _ = await execution.value
    let stalePresent = PhysicalDiskObservation(
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        presence: .present,
        isComplete: true,
        childVolumes: [
            ChildVolumeObservation(volumeID: selected.id, mountAccess: .readOnly),
            ChildVolumeObservation(volumeID: sibling.id, mountAccess: .readOnly),
        ]
    )
    await expectAsync(
        await prepared.coordinator.processSystemEvent(
            .ejectDiskObserved(
                operationID: OperationID(rawValue: "stale-eject-observation"),
                phase: .afterEject,
                observation: stalePresent
            ),
            volumeID: selected.id
        ) == .ignored,
        "an old operation's present observation must be ignored"
    )
    await expectAsync(
        await prepared.coordinator.state(for: sibling.id) == .mediaUnavailable,
        "an ignored stale observation must not resurrect a removed sibling"
    )
    await expectAsync(
        await prepared.coordinator.processSystemEvent(
            .ejectCommandFailed(operationID: prepared.operationID, failure: .busy),
            volumeID: selected.id
        ) == .accepted(
            .inspectEjectMutationReconciliation(
                operationID: prepared.operationID,
                target: selected.diskInstanceID,
                stage: .ejectingPhysicalDisk
            )
        ),
        "a definitive command failure after removal must still request reconciliation"
    )
    await expectAsync(
        await prepared.coordinator.state(for: selected.id)
            == .awaitingEjectMutationReconciliation(
                stage: .ejectingPhysicalDisk,
                failure: .busy
            ),
        "the removed owner must remain locked until complete absence is consumed"
    )
    await expectAsync(
        await prepared.coordinator.state(for: sibling.id) == .mediaUnavailable,
        "every sibling must remain unavailable after the early removal"
    )
    await expectAsync(
        await prepared.coordinator.processSystemEvent(
            .ejectMutationReconciliationObserved(
                operationID: prepared.operationID,
                observation: stalePresent
            ),
            volumeID: selected.id
        ) == .accepted(
            .inspectEjectMutationReconciliation(
                operationID: prepared.operationID,
                target: selected.diskInstanceID,
                stage: .ejectingPhysicalDisk
            )
        ),
        "current-operation present evidence sampled before removal must be rejected and reread"
    )
    await expectAsync(
        await prepared.coordinator.state(for: selected.id)
            == .awaitingEjectMutationReconciliation(
                stage: .ejectingPhysicalDisk,
                failure: .busy
            ),
        "stale present evidence must not settle the removed owner"
    )
    await expectAsync(
        await prepared.coordinator.state(for: sibling.id) == .mediaUnavailable,
        "stale present reconciliation must not revive removed siblings"
    )
    let completeAbsence = PhysicalDiskObservation(
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        presence: .absent,
        isComplete: true,
        childVolumes: []
    )
    await expectAsync(
        await prepared.coordinator.processSystemEvent(
            .ejectMutationReconciliationObserved(
                operationID: prepared.operationID,
                observation: completeAbsence
            ),
            volumeID: selected.id
        ) == .accepted(.none),
        "complete absence must settle the removal/failure race"
    )
    await expectAsync(
        await prepared.coordinator.state(for: selected.id) == .safeToRemove,
        "only fresh complete absence may finish the removed owner"
    )
}

func removalDuringUncertainWholeDiskUnmountStillRequiresCompleteReconciliation() async {
    let physicalDiskID = PhysicalDiskID(rawValue: "disk48-uncertain-unmount")
    let generation = MediaGeneration(rawValue: 494)
    let selected = makeSnapshot(
        uuid: "EJECT-REMOVED-UNCERTAIN-1",
        bsdName: "disk48s9",
        displayName: "EJECT-REMOVED-UNCERTAIN-1",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let sibling = makeSnapshot(
        uuid: "EJECT-REMOVED-UNCERTAIN-2",
        bsdName: "disk48s10",
        displayName: "EJECT-REMOVED-UNCERTAIN-2",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let coordinator = makeCoordinator(
        snapshots: [selected, sibling],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(unmountEffect) = await coordinator.requestEject(
        target: selected.instanceID
    ), case let .unmountPhysicalDiskStandard(operationID, _) = unmountEffect else {
        fatalError("CHECK FAILED: uncertain unmount setup should produce a disk command")
    }
    let probe = MutationInvocationProbe()
    let execution = Task {
        await coordinator.executeMutation(
            effect: unmountEffect,
            resolveEvidence: {
                .disk(
                    makeDiskMutationObservation(
                        target: selected.diskInstanceID,
                        isComplete: true,
                        childSnapshots: [selected, sibling]
                    )
                )
            },
            invoke: { _ in await probe.invokeAndWait() }
        )
    }
    await probe.waitUntilStarted()
    _ = await coordinator.processSystemEvent(
        .ejectUnmountCommandFailed(operationID: operationID, failure: .timedOut),
        volumeID: selected.id
    )
    _ = await coordinator.processDiskLifecycleEvent(
        .mediaRemoved(expected: selected.diskInstanceID)
    )
    await expectAsync(
        await coordinator.state(for: selected.id)
            == .ejectMutationQuiescencePending(
                stage: .unmountingPhysicalDisk,
                failure: .timedOut
            ),
        "removal before quiescence must preserve the uncertain unmount owner"
    )
    await probe.release()
    _ = await execution.value
    guard case .accepted(.inspectEjectMutationReconciliation) = await coordinator
        .processSystemEvent(
            .ejectMutationQuiesced(
                operationID: operationID,
                stage: .unmountingPhysicalDisk
            ),
            volumeID: selected.id
        )
    else {
        fatalError("CHECK FAILED: stopped uncertain unmount should request reconciliation")
    }
    let incompleteAbsence = PhysicalDiskObservation(
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        presence: .absent,
        isComplete: false,
        childVolumes: []
    )
    guard case .accepted(.inspectEjectMutationReconciliation) = await coordinator
        .processSystemEvent(
            .ejectMutationReconciliationObserved(
                operationID: operationID,
                observation: incompleteAbsence
            ),
            volumeID: selected.id
        )
    else {
        fatalError("CHECK FAILED: incomplete absence must retry reconciliation")
    }
    _ = await coordinator.processDiskLifecycleEvent(
        .mediaRemoved(expected: selected.diskInstanceID)
    )
    await expectAsync(
        await coordinator.state(for: selected.id)
            == .awaitingEjectMutationReconciliation(
                stage: .unmountingPhysicalDisk,
                failure: .timedOut
            ),
        "a later removal event must not bypass an incomplete uncertainty reconciliation"
    )
    await expectAsync(
        await coordinator.rebuildInventory(snapshots: [selected, sibling])
            == .operationsInProgress([physicalDiskID]),
        "the whole-disk lease must remain held until complete reconciliation"
    )
    let stalePresentAfterRemoval = PhysicalDiskObservation(
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        presence: .present,
        isComplete: true,
        childVolumes: [
            ChildVolumeObservation(volumeID: selected.id, mountAccess: .readOnly),
            ChildVolumeObservation(volumeID: sibling.id, mountAccess: .readOnly),
        ]
    )
    await expectAsync(
        await coordinator.processSystemEvent(
            .ejectMutationReconciliationObserved(
                operationID: operationID,
                observation: stalePresentAfterRemoval
            ),
            volumeID: selected.id
        ) == .accepted(
            .inspectEjectMutationReconciliation(
                operationID: operationID,
                target: selected.diskInstanceID,
                stage: .unmountingPhysicalDisk
            )
        ),
        "same-generation present facts cannot override removal during unmount reconciliation"
    )
    await expectAsync(
        await coordinator.state(for: sibling.id) == .mediaUnavailable,
        "unmount reconciliation must keep removed siblings unavailable"
    )
    let completeAbsence = PhysicalDiskObservation(
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        presence: .absent,
        isComplete: true,
        childVolumes: []
    )
    await expectAsync(
        await coordinator.processSystemEvent(
            .ejectMutationReconciliationObserved(
                operationID: operationID,
                observation: completeAbsence
            ),
            volumeID: selected.id
        ) == .accepted(.none),
        "only complete whole-disk absence may settle the uncertain unmount"
    )
    await expectAsync(
        await coordinator.state(for: selected.id) == .safeToRemove,
        "complete absence should be the only safe-to-remove proof"
    )
}

func ejectTimeoutOrCancellationRequiresQuiescenceAndWholeDiskReconciliation() async {
    let physicalDiskID = PhysicalDiskID(rawValue: "disk49")
    let generation = MediaGeneration(rawValue: 50)
    let first = makeSnapshot(
        uuid: "EJECT-UNCERTAIN-1",
        bsdName: "disk49s1",
        displayName: "EJECT-UNCERTAIN-1",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let sibling = makeSnapshot(
        uuid: "EJECT-UNCERTAIN-2",
        bsdName: "disk49s2",
        displayName: "EJECT-UNCERTAIN-2",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let coordinator = makeCoordinator(
        snapshots: [first, sibling],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(unmountEffect) = await coordinator.requestEject(
        target: first.instanceID
    ) else {
        fatalError("CHECK FAILED: uncertain eject setup should produce whole-disk unmount")
    }
    guard case let .unmountPhysicalDiskStandard(operationID, _) = unmountEffect else {
        fatalError("CHECK FAILED: uncertain eject setup should start with unmount")
    }
    let unmountProbe = MutationInvocationProbe()
    let unmountExecution = Task {
        await coordinator.executeMutation(
            effect: unmountEffect,
            resolveEvidence: {
                .disk(
                    makeDiskMutationObservation(
                        target: first.diskInstanceID,
                        isComplete: true,
                        childSnapshots: [first, sibling]
                    )
                )
            },
            invoke: { _ in await unmountProbe.invokeAndWait() }
        )
    }
    await unmountProbe.waitUntilStarted()
    await expectAsync(
        await coordinator.processSystemEvent(
            .ejectUnmountCommandFailed(operationID: operationID, failure: .timedOut),
            volumeID: first.id
        ) == .rejected(.ejectFailed(.timedOut)),
        "a timed-out whole-disk unmount must enter uncertainty instead of releasing its lease"
    )
    await expectAsync(
        await coordinator.state(for: first.id)
            == .ejectMutationQuiescencePending(
                stage: .unmountingPhysicalDisk,
                failure: .timedOut
            ),
        "the owner must show that the timed-out disk process may still be running"
    )
    await expectAsync(
        await coordinator.requestEnableWriting(target: sibling.instanceID)
            == .rejected(.operationInProgress),
        "eject uncertainty must keep every sibling mutation blocked"
    )
    await unmountProbe.release()
    await expectAsync(
        await unmountExecution.value == .executed,
        "the timed-out unmount executor must still confirm real process exit"
    )
    guard case .accepted(.inspectEjectMutationReconciliation) = await coordinator
        .processSystemEvent(
            .ejectMutationQuiesced(
                operationID: operationID,
                stage: .unmountingPhysicalDisk
            ),
            volumeID: first.id
        )
    else {
        fatalError("CHECK FAILED: quiesced unmount must request whole-disk reconciliation")
    }
    let incomplete = PhysicalDiskObservation(
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        presence: .present,
        isComplete: false,
        childVolumes: []
    )
    guard case .accepted(.inspectEjectMutationReconciliation) = await coordinator
        .processSystemEvent(
            .ejectMutationReconciliationObserved(
                operationID: operationID,
                observation: incomplete
            ),
            volumeID: first.id
        )
    else {
        fatalError("CHECK FAILED: incomplete eject reconciliation must retry observation")
    }
    await expectAsync(
        await coordinator.rebuildInventory(snapshots: [first, sibling])
            == .operationsInProgress([physicalDiskID]),
        "incomplete whole-disk reconciliation must retain the lease"
    )
    let stillPresent = PhysicalDiskObservation(
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        presence: .present,
        isComplete: true,
        childVolumes: [
            ChildVolumeObservation(volumeID: first.id, mountAccess: .readOnly),
            ChildVolumeObservation(volumeID: sibling.id, mountAccess: .readOnly),
        ]
    )
    await expectAsync(
        await coordinator.processSystemEvent(
            .ejectMutationReconciliationObserved(
                operationID: operationID,
                observation: stillPresent
            ),
            volumeID: first.id
        ) == .rejected(.ejectFailed(.timedOut)),
        "complete present-disk reconciliation may terminally release the uncertain lease"
    )
    await expectAsync(
        await coordinator.rebuildInventory(snapshots: [first, sibling]) == .rebuilt,
        "only complete reconciliation may release the timed-out eject lease"
    )

    let finalDiskID = PhysicalDiskID(rawValue: "disk50")
    let finalGeneration = MediaGeneration(rawValue: 51)
    let finalSelected = makeSnapshot(
        uuid: "EJECT-CANCEL-1",
        bsdName: "disk50s1",
        displayName: "EJECT-CANCEL-1",
        physicalDiskID: finalDiskID,
        mediaGeneration: finalGeneration
    )
    let finalSibling = makeSnapshot(
        uuid: "EJECT-CANCEL-2",
        bsdName: "disk50s2",
        displayName: "EJECT-CANCEL-2",
        physicalDiskID: finalDiskID,
        mediaGeneration: finalGeneration
    )
    let prepared = await coordinatorReadyForFinalEject(
        selected: finalSelected,
        sibling: finalSibling
    )
    let ejectProbe = MutationInvocationProbe()
    let ejectExecution = Task {
        await prepared.coordinator.executeMutation(
            effect: prepared.ejectEffect,
            resolveEvidence: {
                .disk(
                    makeDiskMutationObservation(
                        target: finalSelected.diskInstanceID,
                        isComplete: true,
                        childSnapshots: prepared.unmountedSnapshots
                    )
                )
            },
            invoke: { _ in await ejectProbe.invokeAndWait() }
        )
    }
    await ejectProbe.waitUntilStarted()
    _ = await prepared.coordinator.processSystemEvent(
        .ejectCommandFailed(operationID: prepared.operationID, failure: .cancelled),
        volumeID: finalSelected.id
    )
    _ = await prepared.coordinator.processDiskLifecycleEvent(
        .mediaRemoved(expected: finalSelected.diskInstanceID)
    )
    await expectAsync(
        await prepared.coordinator.state(for: finalSelected.id)
            == .ejectMutationQuiescencePending(
                stage: .ejectingPhysicalDisk,
                failure: .cancelled
            ),
        "removal during uncertain final eject must preserve the owner until process exit"
    )
    await expectAsync(
        await prepared.coordinator.state(for: finalSibling.id) == .mediaUnavailable,
        "removal during uncertain final eject must immediately revoke the sibling"
    )
    await ejectProbe.release()
    _ = await ejectExecution.value
    guard case .accepted(.inspectEjectMutationReconciliation) = await prepared.coordinator
        .processSystemEvent(
            .ejectMutationQuiesced(
                operationID: prepared.operationID,
                stage: .ejectingPhysicalDisk
            ),
            volumeID: finalSelected.id
        )
    else {
        fatalError("CHECK FAILED: cancelled eject must reconcile after its process exits")
    }
    let absent = PhysicalDiskObservation(
        physicalDiskID: finalDiskID,
        mediaGeneration: finalGeneration,
        presence: .absent,
        isComplete: true,
        childVolumes: []
    )
    await expectAsync(
        await prepared.coordinator.processSystemEvent(
            .ejectMutationReconciliationObserved(
                operationID: prepared.operationID,
                observation: absent
            ),
            volumeID: finalSelected.id
        ) == .accepted(.none),
        "verified absence after cancellation should still reach safe removal"
    )
    await expectAsync(
        await prepared.coordinator.state(for: finalSelected.id) == .safeToRemove,
        "cancelled eject may claim safe removal only after fresh complete absence"
    )
    await expectAsync(
        await prepared.coordinator.state(for: finalSibling.id) == .mediaUnavailable,
        "successful uncertain-eject reconciliation must revoke every sibling"
    )
}

func volumeCoordinatorSerializesSiblingMutationsAndIgnoresStaleCompletion() async {
    let physicalDiskID = PhysicalDiskID(rawValue: "coordinator-disk")
    let generation = MediaGeneration(rawValue: 29)
    let first = makeSnapshot(
        uuid: "COORDINATOR-1",
        bsdName: "disk35s1",
        displayName: "COORDINATOR-1",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let second = makeSnapshot(
        uuid: "COORDINATOR-2",
        bsdName: "disk35s2",
        displayName: "COORDINATOR-2",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let coordinator = makeCoordinator(
        snapshots: [first, second],
        setupFactsProvider: readySetupFactsProvider()
    )

    async let firstRequest = coordinator.requestEnableWriting(target: first.instanceID)
    async let secondRequest = coordinator.requestEnableWriting(target: second.instanceID)
    let (firstResult, secondResult) = await (firstRequest, secondRequest)

    let winningVolume: VolumeSnapshot
    let losingVolume: VolumeSnapshot
    let winningOperationID: OperationID
    switch (firstResult, secondResult) {
    case let (.accepted(.unmountStandard(operationID, target)), .rejected(.operationInProgress)):
        expect(target == first.instanceID, "the accepted effect should target the first volume instance")
        winningVolume = first
        losingVolume = second
        winningOperationID = operationID
    case let (.rejected(.operationInProgress), .accepted(.unmountStandard(operationID, target))):
        expect(target == second.instanceID, "the accepted effect should target the second volume instance")
        winningVolume = second
        losingVolume = first
        winningOperationID = operationID
    default:
        fatalError("CHECK FAILED: exactly one sibling operation should acquire the physical-disk lease")
    }

    let refusedRebuild = await coordinator.rebuildInventory(snapshots: [first, second])
    expect(
        refusedRebuild == .operationsInProgress([physicalDiskID]),
        "inventory rebuild must not clear an active physical-disk lease"
    )

    let staleFailureResult = await coordinator.processSystemEvent(
        .writeOperationFailed(
            operationID: OperationID(rawValue: "stale-operation"),
            stage: .unmountingReadOnly,
            failure: .timedOut
        ),
        volumeID: winningVolume.id
    )
    expect(
        staleFailureResult == .ignored,
        "a stale failure must not release the physical-disk lease"
    )
    let blockedSiblingResult = await coordinator.requestEnableWriting(target: losingVolume.instanceID)
    expect(
        blockedSiblingResult == .rejected(.operationInProgress),
        "the sibling should remain blocked after a stale completion"
    )

    await expectAsync(
        await coordinator.executeMutation(
            effect: .unmountStandard(
                operationID: winningOperationID,
                target: winningVolume.instanceID
            ),
            resolveEvidence: { volumeMutationEvidence(winningVolume) },
            invoke: { _ in .exited(terminationStatus: 0) }
        ) == .executed,
        "the winning mutation must be claimed before a command failure can settle it"
    )

    let terminalFailureResult = await coordinator.processSystemEvent(
        .writeOperationFailed(
            operationID: winningOperationID,
            stage: .unmountingReadOnly,
            failure: .engineFailed
        ),
        volumeID: winningVolume.id
    )
    expect(
        terminalFailureResult == .rejected(
            .writeOperationFailed(stage: .unmountingReadOnly, failure: .engineFailed)
        ),
        "a definitive matching command failure should release the physical-disk lease"
    )

    let retry = await coordinator.requestEnableWriting(target: losingVolume.instanceID)
    let retryOperationID: OperationID
    if case let .accepted(.unmountStandard(operationID, target)) = retry {
        expect(target == losingVolume.instanceID, "retry should target the sibling volume instance")
        retryOperationID = operationID
    } else {
        fatalError("CHECK FAILED: sibling should acquire the lease after terminal failure")
    }
    expect(retryOperationID != winningOperationID, "the coordinator must generate a fresh operation ID")
    let delayedResult = await coordinator.processSystemEvent(
        .unmountSucceeded(operationID: winningOperationID),
        volumeID: winningVolume.id
    )
    expect(
        delayedResult == .ignored,
        "a delayed callback from the prior operation must not advance the retry"
    )
    let retryState = await coordinator.state(for: losingVolume.id)
    expect(
        retryState == .unmountingForWrite,
        "the retry should remain the only active operation on the physical disk"
    )
}

func inventoryRebuildTargetsOnlyTheCurrentMediaInstance() async {
    let physicalDiskID = PhysicalDiskID(rawValue: "inventory-disk")
    let firstGeneration = makeSnapshot(
        uuid: "INVENTORY-1",
        bsdName: "disk36s1",
        displayName: "INVENTORY",
        physicalDiskID: physicalDiskID,
        mediaGeneration: MediaGeneration(rawValue: 30)
    )
    let coordinator = makeCoordinator(
        snapshots: [firstGeneration],
        setupFactsProvider: readySetupFactsProvider()
    )
    let firstResult = await coordinator.requestEnableWriting(target: firstGeneration.instanceID)
    let firstOperationID: OperationID
    if case let .accepted(.unmountStandard(operationID, target)) = firstResult {
        expect(target == firstGeneration.instanceID, "first effect should bind the first media generation")
        firstOperationID = operationID
    } else {
        fatalError("CHECK FAILED: first inventory generation should begin write enablement")
    }

    let secondGeneration = makeSnapshot(
        uuid: firstGeneration.id.uuid,
        bsdName: firstGeneration.id.bsdName,
        displayName: firstGeneration.displayName,
        physicalDiskID: physicalDiskID,
        mediaGeneration: MediaGeneration(rawValue: 31)
    )
    _ = await coordinator.processDiskLifecycleEvent(
        .mediaReplaced(
            expected: firstGeneration.diskInstanceID,
            observed: secondGeneration.diskInstanceID
        )
    )
    let rebuildResult = await coordinator.rebuildInventory(snapshots: [secondGeneration])
    expect(rebuildResult == .rebuilt, "terminal media invalidation should allow inventory rebuild")

    let rebuiltState = await coordinator.state(for: secondGeneration.id)
    expect(
        rebuiltState == .readOnlyReady,
        "inventory rebuild should derive state from the current snapshot"
    )
    let secondResult = await coordinator.requestEnableWriting(target: secondGeneration.instanceID)
    let secondOperationID: OperationID
    if case let .accepted(.unmountStandard(operationID, target)) = secondResult {
        expect(target == secondGeneration.instanceID, "new effect must bind only the replacement generation")
        secondOperationID = operationID
    } else {
        fatalError("CHECK FAILED: rebuilt inventory should accept a new operation")
    }
    expect(secondOperationID != firstOperationID, "inventory rebuild must not reuse an operation ID")
    let delayedResult = await coordinator.processSystemEvent(
        .unmountSucceeded(operationID: firstOperationID),
        volumeID: secondGeneration.id
    )
    expect(delayedResult == .ignored, "old-generation callback must not advance the new operation")
    let currentState = await coordinator.state(for: secondGeneration.id)
    expect(
        currentState == .unmountingForWrite,
        "old-generation callback must leave the new operation unchanged"
    )
}

actor MutationInvocationProbe {
    private(set) var invocationCount = 0
    private var isReleased = false
    private var hasStarted = false

    func invokeAndWait() async -> MountEngineTermination {
        invocationCount += 1
        hasStarted = true
        while !isReleased {
            await Task.yield()
        }
        return .exited(terminationStatus: 0)
    }

    func invokeImmediately() -> MountEngineTermination {
        invocationCount += 1
        return .exited(terminationStatus: 0)
    }

    func waitUntilStarted() async {
        while !hasStarted {
            await Task.yield()
        }
    }

    func release() {
        isReleased = true
    }
}

actor MountEngineProbe {
    private let termination: MountEngineTermination
    private(set) var commands: [MutationCommand] = []

    init(termination: MountEngineTermination) {
        self.termination = termination
    }

    func execute(_ command: MutationCommand) -> MountEngineTermination {
        commands.append(command)
        return termination
    }
}

func mountEngineExecutesOnlyTheClaimedCurrentEffect() async {
    let snapshot = makeSnapshot(
        uuid: "MOUNT-ENGINE-1",
        bsdName: "disk73s1",
        displayName: "MOUNT-ENGINE",
        physicalDiskID: PhysicalDiskID(rawValue: "mount-engine-disk"),
        mediaGeneration: MediaGeneration(rawValue: 73)
    )
    let coordinator = makeCoordinator(
        snapshots: [snapshot],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(effect) = await coordinator.requestEnableWriting(
        target: snapshot.instanceID
    ) else {
        fatalError("CHECK FAILED: MountEngine setup should produce a mutation effect")
    }
    guard case let .unmountStandard(operationID, target) = effect else {
        fatalError("CHECK FAILED: MountEngine setup should begin with standard unmount")
    }
    let expectedCommand = MutationCommand.unmountVolumeStandard(
        operationID: operationID,
        target: target
    )
    let probe = MountEngineProbe(termination: .exited(terminationStatus: 0))
    let engine = MountEngine { command in
        await probe.execute(command)
    }

    await expectAsync(
        await coordinator.executeMutation(
            effect: effect,
            resolveEvidence: { volumeMutationEvidence(snapshot) },
            engine: engine
        ) == .executed(
            MountEngineResult(
                termination: .exited(terminationStatus: 0),
                requiredFreshEvidence: .volume(snapshot.instanceID)
            )
        ),
        "the named engine contract should return an explicit exit and volume evidence requirement"
    )
    await expectAsync(
        await probe.commands == [expectedCommand],
        "the exact currently claimed semantic command should reach MountEngine once"
    )
    await expectAsync(
        await coordinator.state(for: snapshot.id) == .unmountingForWrite,
        "a direct engine exit must not replace fresh system evidence with a final state"
    )
}

func mountEngineRejectsOldInstancesAndReplaysWithoutInvocation() async {
    let snapshot = makeSnapshot(
        uuid: "MOUNT-ENGINE-GATE-1",
        bsdName: "disk74s1",
        displayName: "MOUNT-ENGINE-GATE",
        physicalDiskID: PhysicalDiskID(rawValue: "mount-engine-gate-disk"),
        mediaGeneration: MediaGeneration(rawValue: 74)
    )
    let staleInstance = makeSnapshot(
        uuid: snapshot.id.uuid,
        bsdName: snapshot.id.bsdName,
        displayName: snapshot.displayName,
        physicalDiskID: snapshot.physicalDiskID,
        mediaGeneration: MediaGeneration(rawValue: 75)
    )
    let staleCoordinator = makeCoordinator(
        snapshots: [snapshot],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(staleInstanceEffect) = await staleCoordinator
        .requestEnableWriting(target: snapshot.instanceID)
    else {
        fatalError("CHECK FAILED: old-instance MountEngine setup should produce an effect")
    }
    let staleProbe = MountEngineProbe(termination: .exited(terminationStatus: 0))
    let staleEngine = MountEngine { command in
        await staleProbe.execute(command)
    }

    let staleInstanceResult = await staleCoordinator.executeMutation(
        effect: staleInstanceEffect,
        resolveEvidence: { volumeMutationEvidence(staleInstance) },
        engine: staleEngine
    )
    await expectAsync(
        {
            if case .rejected(.targetChanged) = staleInstanceResult { return true }
            return false
        }(),
        "fresh evidence for another media instance must reject the engine invocation"
    )
    await expectAsync(
        await staleProbe.commands.isEmpty,
        "an old media instance must produce zero MountEngine calls"
    )

    let coordinator = makeCoordinator(
        snapshots: [snapshot],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(effect) = await coordinator.requestEnableWriting(
        target: snapshot.instanceID
    ) else {
        fatalError("CHECK FAILED: replay MountEngine setup should produce an effect")
    }
    guard case let .unmountStandard(operationID, target) = effect else {
        fatalError("CHECK FAILED: replay MountEngine setup should begin with standard unmount")
    }
    let staleEffect = VolumeEffect.unmountStandard(
        operationID: OperationID(rawValue: "old-mount-engine-operation"),
        target: target
    )
    let expectedCommand = MutationCommand.unmountVolumeStandard(
        operationID: operationID,
        target: target
    )
    let probe = MountEngineProbe(termination: .exited(terminationStatus: 0))
    let engine = MountEngine { command in
        await probe.execute(command)
    }

    let staleOperationResult = await coordinator.executeMutation(
        effect: staleEffect,
        resolveEvidence: { volumeMutationEvidence(snapshot) },
        engine: engine
    )
    await expectAsync(
        {
            if case .rejected(.operationNotActive) = staleOperationResult { return true }
            return false
        }(),
        "an old operation must fail before reaching MountEngine"
    )
    await expectAsync(
        await probe.commands.isEmpty,
        "an old operation must produce zero MountEngine calls"
    )
    let currentResult = await coordinator.executeMutation(
        effect: effect,
        resolveEvidence: { volumeMutationEvidence(snapshot) },
        engine: engine
    )
    await expectAsync(
        {
            if case .executed = currentResult { return true }
            return false
        }(),
        "the exact current effect should still execute after a stale attempt"
    )
    await expectAsync(
        await probe.commands == [expectedCommand],
        "only the exact current semantic command should be invoked"
    )
    await expectAsync(
        await coordinator.executeMutation(
            effect: effect,
            resolveEvidence: { volumeMutationEvidence(snapshot) },
            engine: engine
        ) == .rejected(.effectNotExpected),
        "a consumed MountEngine effect must not be replayed"
    )
    await expectAsync(
        await probe.commands == [expectedCommand],
        "replay rejection must preserve exactly-once MountEngine invocation"
    )
}

func mountEngineResultsDistinguishTerminationAndFreshEvidenceScope() async {
    let volumeTerminations: [MountEngineTermination] = [
        .exited(terminationStatus: 7),
        .timedOutAfterConfirmedQuiescence,
        .cancelledAfterConfirmedQuiescence,
        .terminationUnconfirmed,
    ]
    for (index, termination) in volumeTerminations.enumerated() {
        let snapshot = makeSnapshot(
            uuid: "MOUNT-ENGINE-RESULT-\(index)",
            bsdName: "disk\(76 + index)s1",
            displayName: "MOUNT-ENGINE-RESULT",
            physicalDiskID: PhysicalDiskID(rawValue: "mount-engine-result-\(index)"),
            mediaGeneration: MediaGeneration(rawValue: UInt64(76 + index))
        )
        let coordinator = makeCoordinator(
            snapshots: [snapshot],
            setupFactsProvider: readySetupFactsProvider()
        )
        guard case let .accepted(effect) = await coordinator.requestEnableWriting(
            target: snapshot.instanceID
        ) else {
            fatalError("CHECK FAILED: typed MountEngine result setup should produce an effect")
        }
        let probe = MountEngineProbe(termination: termination)
        let engine = MountEngine { command in
            await probe.execute(command)
        }

        await expectAsync(
            await coordinator.executeMutation(
                effect: effect,
                resolveEvidence: { volumeMutationEvidence(snapshot) },
                engine: engine
            ) == .executed(
                MountEngineResult(
                    termination: termination,
                    requiredFreshEvidence: .volume(snapshot.instanceID)
                )
            ),
            "every volume-engine termination must retain its exact typed outcome and fresh volume requirement"
        )
    }

    let diskSnapshot = makeSnapshot(
        uuid: "MOUNT-ENGINE-DISK-RESULT",
        bsdName: "disk80s1",
        displayName: "MOUNT-ENGINE-DISK-RESULT",
        physicalDiskID: PhysicalDiskID(rawValue: "mount-engine-whole-disk"),
        mediaGeneration: MediaGeneration(rawValue: 80)
    )
    let diskCoordinator = makeCoordinator(
        snapshots: [diskSnapshot],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(diskEffect) = await diskCoordinator.requestEject(
        target: diskSnapshot.instanceID
    ) else {
        fatalError("CHECK FAILED: whole-disk MountEngine setup should produce an effect")
    }
    let diskProbe = MountEngineProbe(termination: .timedOutAfterConfirmedQuiescence)
    let diskEngine = MountEngine { command in
        await diskProbe.execute(command)
    }

    await expectAsync(
        await diskCoordinator.executeMutation(
            effect: diskEffect,
            resolveEvidence: {
                .disk(
                    makeDiskMutationObservation(
                        target: diskSnapshot.diskInstanceID,
                        isComplete: true,
                        childSnapshots: [diskSnapshot]
                    )
                )
            },
            engine: diskEngine
        ) == .executed(
            MountEngineResult(
                termination: .timedOutAfterConfirmedQuiescence,
                requiredFreshEvidence: .wholeDisk(diskSnapshot.diskInstanceID)
            )
        ),
        "whole-disk commands must require a fresh whole-disk observation"
    )
}

func mountEngineConfirmedQuiescenceUnlocksOnlyFreshReconciliation() async {
    for (index, pair) in [
        (MountEngineTermination.timedOutAfterConfirmedQuiescence, WriteOperationFailure.timedOut),
        (.cancelledAfterConfirmedQuiescence, .cancelled),
    ].enumerated() {
        let (termination, failure) = pair
        let snapshot = makeSnapshot(
            uuid: "MOUNT-ENGINE-QUIESCED-\(index)",
            bsdName: "disk\(81 + index)s1",
            displayName: "MOUNT-ENGINE-QUIESCED",
            physicalDiskID: PhysicalDiskID(rawValue: "mount-engine-quiesced-\(index)"),
            mediaGeneration: MediaGeneration(rawValue: UInt64(81 + index))
        )
        let coordinator = makeCoordinator(
            snapshots: [snapshot],
            setupFactsProvider: readySetupFactsProvider()
        )
        guard case let .accepted(effect) = await coordinator.requestEnableWriting(
            target: snapshot.instanceID
        ) else {
            fatalError("CHECK FAILED: confirmed-quiescence setup should produce an effect")
        }
        guard case let .unmountStandard(operationID, _) = effect else {
            fatalError("CHECK FAILED: confirmed-quiescence setup should begin with unmount")
        }
        let probe = MountEngineProbe(termination: termination)
        let engine = MountEngine { command in
            await probe.execute(command)
        }
        _ = await coordinator.executeMutation(
            effect: effect,
            resolveEvidence: { volumeMutationEvidence(snapshot) },
            engine: engine
        )
        _ = await coordinator.processSystemEvent(
            .writeOperationFailed(
                operationID: operationID,
                stage: .unmountingReadOnly,
                failure: failure
            ),
            volumeID: snapshot.id
        )

        await expectAsync(
            await coordinator.processSystemEvent(
                .writeMutationQuiesced(
                    operationID: operationID,
                    stage: .unmountingReadOnly
                ),
                volumeID: snapshot.id
            ) == .accepted(
                .inspectWriteMutationReconciliation(
                    operationID: operationID,
                    target: snapshot.instanceID
                )
            ),
            "confirmed engine quiescence must lead only to fresh volume reconciliation"
        )
    }
}

func mountEngineUnconfirmedTerminationRetainsLeaseAndCallbackGate() async {
    let physicalDiskID = PhysicalDiskID(rawValue: "mount-engine-unconfirmed-disk")
    let generation = MediaGeneration(rawValue: 83)
    let snapshot = makeSnapshot(
        uuid: "MOUNT-ENGINE-UNCONFIRMED-1",
        bsdName: "disk83s1",
        displayName: "MOUNT-ENGINE-UNCONFIRMED",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let sibling = makeSnapshot(
        uuid: "MOUNT-ENGINE-UNCONFIRMED-2",
        bsdName: "disk83s2",
        displayName: "MOUNT-ENGINE-UNCONFIRMED-SIBLING",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let coordinator = makeCoordinator(
        snapshots: [snapshot, sibling],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(effect) = await coordinator.requestEnableWriting(
        target: snapshot.instanceID
    ) else {
        fatalError("CHECK FAILED: unconfirmed-termination setup should produce an effect")
    }
    guard case let .unmountStandard(operationID, _) = effect else {
        fatalError("CHECK FAILED: unconfirmed-termination setup should begin with unmount")
    }
    let probe = MountEngineProbe(termination: .terminationUnconfirmed)
    let engine = MountEngine { command in
        await probe.execute(command)
    }

    await expectAsync(
        await coordinator.executeMutation(
            effect: effect,
            resolveEvidence: { volumeMutationEvidence(snapshot) },
            engine: engine
        ) == .executed(
            MountEngineResult(
                termination: .terminationUnconfirmed,
                requiredFreshEvidence: .volume(snapshot.instanceID)
            )
        ),
        "an unconfirmed termination must remain explicit rather than pretending quiescence"
    )
    _ = await coordinator.processSystemEvent(
        .writeOperationFailed(
            operationID: operationID,
            stage: .unmountingReadOnly,
            failure: .timedOut
        ),
        volumeID: snapshot.id
    )
    await expectAsync(
        await coordinator.processSystemEvent(
            .writeMutationQuiesced(
                operationID: operationID,
                stage: .unmountingReadOnly
            ),
            volumeID: snapshot.id
        ) == .ignored,
        "a callback cannot claim quiescence after MountEngine reports termination unconfirmed"
    )
    await expectAsync(
        await coordinator.processSystemEvent(
            .unmountSucceeded(operationID: operationID),
            volumeID: snapshot.id
        ) == .ignored,
        "a success callback cannot bypass an unconfirmed MountEngine termination"
    )
    await expectAsync(
        await coordinator.requestEnableWriting(target: sibling.instanceID)
            == .rejected(.operationInProgress),
        "the whole-disk lease must remain held while termination is unconfirmed"
    )
    await expectAsync(
        await coordinator.rebuildInventory(snapshots: [snapshot, sibling])
            == .operationsInProgress([physicalDiskID]),
        "inventory rebuild must not erase an unconfirmed MountEngine lease"
    )
    await expectAsync(
        await coordinator.executeMutation(
            effect: effect,
            resolveEvidence: { volumeMutationEvidence(snapshot) },
            engine: engine
        ) == .rejected(.effectNotExpected),
        "the unconfirmed command must remain consumed and non-replayable"
    )
    await expectAsync(
        await probe.commands.count == 1,
        "an unconfirmed termination must not cause a second MountEngine invocation"
    )
}

func closureMutationTerminationCannotBeDiscardedAsConfirmedQuiescence() async {
    let cases: [(MountEngineTermination, WriteOperationFailure)] = [
        (.cancelledAfterConfirmedQuiescence, .cancelled),
        (.terminationUnconfirmed, .timedOut),
    ]

    for (index, entry) in cases.enumerated() {
        let (termination, failure) = entry
        let physicalDiskID = PhysicalDiskID(
            rawValue: "closure-termination-disk-\(index)"
        )
        let generation = MediaGeneration(rawValue: UInt64(184 + index))
        let selected = makeSnapshot(
            uuid: "CLOSURE-TERMINATION-\(index)-1",
            bsdName: "disk\(184 + index)s1",
            displayName: "CLOSURE-TERMINATION",
            physicalDiskID: physicalDiskID,
            mediaGeneration: generation
        )
        let sibling = makeSnapshot(
            uuid: "CLOSURE-TERMINATION-\(index)-2",
            bsdName: "disk\(184 + index)s2",
            displayName: "CLOSURE-TERMINATION-SIBLING",
            physicalDiskID: physicalDiskID,
            mediaGeneration: generation
        )
        let coordinator = makeCoordinator(
            snapshots: [selected, sibling],
            setupFactsProvider: readySetupFactsProvider()
        )
        guard case let .accepted(effect) = await coordinator.requestEnableWriting(
            target: selected.instanceID
        ) else {
            fatalError("CHECK FAILED: closure termination setup should produce an effect")
        }
        guard case let .unmountStandard(operationID, _) = effect else {
            fatalError("CHECK FAILED: closure termination setup should begin with unmount")
        }

        let execution = await coordinator.executeMutation(
            effect: effect,
            resolveEvidence: { volumeMutationEvidence(selected) },
            invoke: { _ in termination }
        )
        expect(
            execution == .executed,
            "the closure adapter should execute the exact claimed mutation once"
        )
        _ = await coordinator.processSystemEvent(
            .writeOperationFailed(
                operationID: operationID,
                stage: .unmountingReadOnly,
                failure: failure
            ),
            volumeID: selected.id
        )
        await expectAsync(
            await coordinator.requestEnableWriting(target: sibling.instanceID)
                == .rejected(.operationInProgress),
            "cancelled or unknown termination must keep the whole-disk lease non-reentrant"
        )
        await expectAsync(
            await coordinator.rebuildInventory(snapshots: [selected, sibling])
                == .operationsInProgress([physicalDiskID]),
            "inventory rebuild must not erase a cancelled or unknown mutation lease"
        )

        let quiescence = await coordinator.processSystemEvent(
            .writeMutationQuiesced(
                operationID: operationID,
                stage: .unmountingReadOnly
            ),
            volumeID: selected.id
        )
        if termination == .terminationUnconfirmed {
            expect(
                quiescence == .ignored,
                "an unknown closure termination must not be coerced into confirmed quiescence"
            )
        } else {
            expect(
                quiescence == .accepted(
                    .inspectWriteMutationReconciliation(
                        operationID: operationID,
                        target: selected.instanceID
                    )
                ),
                "confirmed cancellation should advance only to fresh reconciliation"
            )
        }
        await expectAsync(
            await coordinator.requestEnableWriting(target: sibling.instanceID)
                == .rejected(.operationInProgress),
            "neither confirmed cancellation nor unknown termination may directly release the lease"
        )
    }
}

func mutationExecutionRejectsReinsertedStaleAndDuplicateEffects() async {
    let snapshot = makeSnapshot(
        uuid: "PREFLIGHT-1",
        bsdName: "disk37s1",
        displayName: "PREFLIGHT",
        physicalDiskID: PhysicalDiskID(rawValue: "disk37"),
        mediaGeneration: MediaGeneration(rawValue: 32)
    )
    let sibling = makeSnapshot(
        uuid: "PREFLIGHT-2",
        bsdName: "disk37s2",
        displayName: "PREFLIGHT-SIBLING",
        physicalDiskID: snapshot.physicalDiskID,
        mediaGeneration: snapshot.mediaGeneration
    )
    let coordinator = makeCoordinator(
        snapshots: [snapshot, sibling],
        setupFactsProvider: readySetupFactsProvider()
    )
    let result = await coordinator.requestEnableWriting(target: snapshot.instanceID)
    guard case let .accepted(effect) = result else {
        fatalError("CHECK FAILED: coordinator should produce a leased mutation effect")
    }
    guard case let .unmountStandard(originalOperationID, _) = effect else {
        fatalError("CHECK FAILED: first leased effect should be the standard volume unmount")
    }

    let replacementSnapshot = makeSnapshot(
        uuid: snapshot.id.uuid,
        bsdName: snapshot.id.bsdName,
        displayName: snapshot.displayName,
        physicalDiskID: snapshot.physicalDiskID,
        mediaGeneration: MediaGeneration(rawValue: 33)
    )
    let replacementProbe = MutationInvocationProbe()
    await expectAsync(
        await coordinator.executeMutation(
            effect: effect,
            resolveEvidence: { volumeMutationEvidence(replacementSnapshot) },
            invoke: { _ in await replacementProbe.invokeImmediately() }
        ) == .rejected(
            .targetChanged(
                expected: .volume(snapshot.instanceID),
                observed: .volume(replacementSnapshot.instanceID)
            )
        ),
        "fresh preflight must reject a reinserted target before any system mutation"
    )
    await expectAsync(
        await replacementProbe.invocationCount == 0,
        "a changed target must produce zero mutation invocations"
    )
    let replacementMismatch = MediaInstanceMismatch(
        expected: snapshot.diskInstanceID,
        observed: replacementSnapshot.diskInstanceID
    )
    await expectAsync(
        await coordinator.state(for: snapshot.id) == .mediaInvalidated(replacementMismatch),
        "a changed media generation must invalidate the selected workflow"
    )
    await expectAsync(
        await coordinator.state(for: sibling.id) == .mediaInvalidated(replacementMismatch),
        "a changed media generation found at final preflight must invalidate every sibling"
    )
    await expectAsync(
        await coordinator.executeMutation(
            effect: effect,
            resolveEvidence: { volumeMutationEvidence(snapshot) },
            invoke: { _ in await replacementProbe.invokeImmediately() }
        ) == .rejected(
            .operationNotActive(expected: nil, observed: originalOperationID)
        ),
        "a failed preflight attempt must consume the intent and terminate its lease"
    )

    let renumberedCoordinator = makeCoordinator(
        snapshots: [snapshot, sibling],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(renumberedEffect) = await renumberedCoordinator
        .requestEnableWriting(target: snapshot.instanceID)
    else {
        fatalError("CHECK FAILED: renumbered-media setup should produce a mutation effect")
    }
    let renumberedSnapshot = makeSnapshot(
        uuid: snapshot.id.uuid,
        bsdName: "disk38s1",
        displayName: snapshot.displayName,
        physicalDiskID: PhysicalDiskID(rawValue: "disk38"),
        mediaGeneration: MediaGeneration(rawValue: 34)
    )
    let renumberedMismatch = MediaInstanceMismatch(
        expected: snapshot.diskInstanceID,
        observed: renumberedSnapshot.diskInstanceID
    )
    await expectAsync(
        await renumberedCoordinator.executeMutation(
            effect: renumberedEffect,
            resolveEvidence: { volumeMutationEvidence(renumberedSnapshot) },
            invoke: { _ in await replacementProbe.invokeImmediately() }
        ) == .rejected(
            .targetChanged(
                expected: .volume(snapshot.instanceID),
                observed: .volume(renumberedSnapshot.instanceID)
            )
        ),
        "a reinserted volume renumbered to another physical disk must fail preflight"
    )
    await expectAsync(
        await renumberedCoordinator.state(for: snapshot.id)
            == .mediaInvalidated(renumberedMismatch),
        "renumbering must invalidate the old selected instance instead of offering retry"
    )
    await expectAsync(
        await renumberedCoordinator.state(for: sibling.id) == .readOnlyReady,
        "renumbering one volume must not falsely replace unrelated old-disk siblings"
    )

    let freshCoordinator = makeCoordinator(
        snapshots: [snapshot],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(freshEffect) = await freshCoordinator.requestEnableWriting(
        target: snapshot.instanceID
    ) else {
        fatalError("CHECK FAILED: fresh coordinator should produce a new leased effect")
    }
    guard case let .unmountStandard(freshOperationID, _) = freshEffect else {
        fatalError("CHECK FAILED: fresh leased effect should be the standard volume unmount")
    }
    let staleEffect = VolumeEffect.unmountStandard(
        operationID: OperationID(rawValue: "stale-operation"),
        target: snapshot.instanceID
    )
    let probe = MutationInvocationProbe()
    await expectAsync(
        await freshCoordinator.executeMutation(
            effect: staleEffect,
            resolveEvidence: { volumeMutationEvidence(snapshot) },
            invoke: { _ in await probe.invokeImmediately() }
        ) == .rejected(
            .operationNotActive(
                expected: freshOperationID,
                observed: OperationID(rawValue: "stale-operation")
            )
        ),
        "an old operation ID must not pass the current coordinator lease"
    )
    await expectAsync(
        await freshCoordinator.executeMutation(
            effect: freshEffect,
            resolveEvidence: { volumeMutationEvidence(snapshot) },
            invoke: { _ in await probe.invokeImmediately() }
        ) == .executed,
        "the exact current effect with fresh matching evidence should execute"
    )
    await expectAsync(
        await probe.invocationCount == 1,
        "the current one-shot effect should invoke exactly once"
    )
    await expectAsync(
        await freshCoordinator.executeMutation(
            effect: freshEffect,
            resolveEvidence: { volumeMutationEvidence(snapshot) },
            invoke: { _ in await probe.invokeImmediately() }
        ) == .rejected(.effectNotExpected),
        "a consumed effect must not be replayable"
    )
    await expectAsync(
        await probe.invocationCount == 1,
        "replay rejection must preserve exactly-once invocation"
    )
}

func setupAssessmentFailsClosedWithActionableIssues() {
    let readyFacts = readySetupFacts()
    expect(SetupChecker.assess(readyFacts).isReady, "the minimum supported setup should be ready")

    let observedOS = SemanticVersion(major: 15, minor: 3, patch: 9)
    let observedMacFUSE = SemanticVersion(major: 5, minor: 2, patch: 9)
    let observedNTFS3G = SemanticVersion(major: 2026, minor: 2, patch: 25)
    let failing = SetupChecker.assess(
        SetupFacts(
            macOSVersion: observedOS,
            architecture: .intel,
            macFUSEVersion: observedMacFUSE,
            ntfs3GVersion: observedNTFS3G,
            fileSystemExtensionEnabled: false,
            selectedBackend: .kernelExtension,
            authorizationStatus: .granted,
            conflictScanComplete: true,
            conflictingDrivers: ["legacy.ntfs.driver"]
        )
    )
    expect(
        failing.issues == [
            .unsupportedOperatingSystem(
                minimum: SemanticVersion(major: 15, minor: 4, patch: 0),
                observed: observedOS
            ),
            .unsupportedArchitecture(.intel),
            .macFUSETooOld(
                minimum: SemanticVersion(major: 5, minor: 3, patch: 3),
                observed: observedMacFUSE
            ),
            .fileSystemExtensionDisabled,
            .ntfs3GTooOld(
                minimum: SemanticVersion(major: 2026, minor: 7, patch: 7),
                observed: observedNTFS3G
            ),
            .unsafeBackend(.kernelExtension),
            .conflictingDrivers(["legacy.ntfs.driver"]),
        ],
        "setup assessment should return deterministic, actionable failures"
    )
    expect(!failing.isReady, "any setup issue should fail closed")
}

func setupReadinessGatesWriteRequestsAndEveryWriteMutation() async {
    let snapshot = makeSnapshot(
        uuid: "SETUP-GATE-1",
        bsdName: "disk38s1",
        displayName: "SETUP-GATE",
        physicalDiskID: PhysicalDiskID(rawValue: "disk38"),
        mediaGeneration: MediaGeneration(rawValue: 34)
    )
    let unsafeFacts = SetupFacts(
        macOSVersion: readySetupFacts().macOSVersion,
        architecture: .appleSilicon,
        macFUSEVersion: readySetupFacts().macFUSEVersion,
        ntfs3GVersion: readySetupFacts().ntfs3GVersion,
        fileSystemExtensionEnabled: true,
        selectedBackend: .kernelExtension,
        authorizationStatus: .granted,
        conflictScanComplete: true,
        conflictingDrivers: ["commercial.ntfs.driver"]
    )
    let unsafeAssessment = SetupChecker.assess(unsafeFacts)
    let initiallyUnsafeStore = MutableSetupFactsStore(unsafeFacts)
    let initiallyUnsafeCoordinator = makeCoordinator(
        snapshots: [snapshot],
        setupFactsProvider: SetupFactsProvider {
            await initiallyUnsafeStore.current()
        }
    )

    await expectAsync(
        await initiallyUnsafeCoordinator.requestEnableWriting(target: snapshot.instanceID)
            == .rejected(.setupNotReady(unsafeAssessment.issues)),
        "an unsafe live setup must reject write enablement before creating an effect"
    )
    await expectAsync(
        await initiallyUnsafeCoordinator.state(for: snapshot.id) == .readOnlyReady,
        "setup rejection must not change the volume workflow"
    )

    let externalEject = await initiallyUnsafeCoordinator.requestEject(target: snapshot.instanceID)
    expect(
        {
            if case .accepted(.unmountPhysicalDiskStandard) = externalEject { return true }
            return false
        }(),
        "missing write dependencies must not block native safe eject for an external disk"
    )

    let changingStore = MutableSetupFactsStore(readySetupFacts())
    let coordinator = makeCoordinator(
        snapshots: [snapshot],
        setupFactsProvider: SetupFactsProvider {
            await changingStore.current()
        }
    )
    guard case let .accepted(unmountEffect) = await coordinator.requestEnableWriting(
        target: snapshot.instanceID
    ) else {
        fatalError("CHECK FAILED: ready setup should allow the write workflow to begin")
    }
    await changingStore.replace(with: unsafeFacts)
    let probe = MutationInvocationProbe()
    await expectAsync(
        await coordinator.executeMutation(
            effect: unmountEffect,
            resolveEvidence: { volumeMutationEvidence(snapshot) },
            invoke: { _ in await probe.invokeImmediately() }
        ) == .rejected(.setupNotReady(unsafeAssessment.issues)),
        "setup must be re-read immediately before the first write-path mutation"
    )
    await expectAsync(
        await probe.invocationCount == 0,
        "unsafe preflight must invoke no system mutation"
    )
    await expectAsync(
        await coordinator.state(for: snapshot.id)
            == .writeOperationFailed(
                stage: .unmountingReadOnly,
                failure: .dependencyUnavailable
            ),
        "a rejected setup preflight must move the workflow into an explicit terminal state"
    )
    await expectAsync(
        await coordinator.rebuildInventory(snapshots: [snapshot]) == .rebuilt,
        "a rejected preflight with zero system mutation must release its physical-disk lease"
    )

    let beforeMountStore = MutableSetupFactsStore(readySetupFacts())
    let beforeMountCoordinator = makeCoordinator(
        snapshots: [snapshot],
        setupFactsProvider: SetupFactsProvider {
            await beforeMountStore.current()
        }
    )
    guard case let .accepted(firstEffect) = await beforeMountCoordinator.requestEnableWriting(
        target: snapshot.instanceID
    ) else {
        fatalError("CHECK FAILED: ready setup should produce an unmount effect")
    }
    await expectAsync(
        await beforeMountCoordinator.executeMutation(
            effect: firstEffect,
            resolveEvidence: { volumeMutationEvidence(snapshot) },
            invoke: { _ in await probe.invokeImmediately() }
        ) == .executed,
        "the initial unmount should execute while setup is ready"
    )
    guard case let .unmountStandard(operationID, _) = firstEffect else {
        fatalError("CHECK FAILED: expected a volume unmount effect")
    }
    _ = await beforeMountCoordinator.processSystemEvent(
        .unmountSucceeded(operationID: operationID),
        volumeID: snapshot.id
    )
    let unmounted = makeSnapshot(
        uuid: snapshot.id.uuid,
        bsdName: snapshot.id.bsdName,
        displayName: snapshot.displayName,
        physicalDiskID: snapshot.physicalDiskID,
        mediaGeneration: snapshot.mediaGeneration,
        mountAccess: .unmounted
    )
    let mountResult = await beforeMountCoordinator.processSystemEvent(
        .safetySnapshotReceived(operationID: operationID, snapshot: unmounted),
        volumeID: snapshot.id
    )
    guard case let .accepted(mountEffect) = mountResult else {
        fatalError("CHECK FAILED: fresh unmounted facts should produce a mount effect")
    }
    await beforeMountStore.replace(with: unsafeFacts)
    let callsBeforeMount = await probe.invocationCount
    await expectAsync(
        await beforeMountCoordinator.executeMutation(
            effect: mountEffect,
            resolveEvidence: { volumeMutationEvidence(unmounted) },
            invoke: { _ in await probe.invokeImmediately() }
        ) == .rejected(.setupNotReady(unsafeAssessment.issues)),
        "setup must be re-read again immediately before the writable mount"
    )
    await expectAsync(
        await probe.invocationCount == callsBeforeMount,
        "a newly unsafe backend or driver conflict must produce zero mount invocations"
    )
}

func staleWriteRequestCannotRebindToAReplacementMediaInstance() async {
    let first = makeSnapshot(
        uuid: "REQUEST-INSTANCE-1",
        bsdName: "disk45s1",
        displayName: "REQUEST-INSTANCE",
        physicalDiskID: PhysicalDiskID(rawValue: "disk45"),
        mediaGeneration: MediaGeneration(rawValue: 45)
    )
    let replacement = makeSnapshot(
        uuid: first.id.uuid,
        bsdName: first.id.bsdName,
        displayName: first.displayName,
        physicalDiskID: first.physicalDiskID,
        mediaGeneration: MediaGeneration(rawValue: 46)
    )
    let setup = SuspendedSetupFactsStore()
    let coordinator = makeCoordinator(
        snapshots: [first],
        setupFactsProvider: SetupFactsProvider { await setup.current() }
    )
    let request = Task {
        await coordinator.requestEnableWriting(target: first.instanceID)
    }
    await setup.waitUntilStarted()
    await expectAsync(
        await coordinator.rebuildInventory(snapshots: [replacement]) == .rebuilt,
        "inventory replacement should remain possible before a write request owns a lease"
    )
    await setup.release()
    await expectAsync(
        await request.value == .rejected(.volumeUnavailable),
        "an old click must not rebind to the replacement media generation"
    )
    await expectAsync(
        await coordinator.state(for: replacement.id) == .readOnlyReady,
        "the replacement instance must remain unchanged after rejecting the stale click"
    )
}

func finalVolumeEvidenceIsReadAfterPotentiallySlowSetupFacts() async {
    let initial = makeSnapshot(
        uuid: "FINAL-EVIDENCE-1",
        bsdName: "disk46s1",
        displayName: "FINAL-EVIDENCE",
        physicalDiskID: PhysicalDiskID(rawValue: "disk46"),
        mediaGeneration: MediaGeneration(rawValue: 47)
    )
    let dirty = makeSnapshot(
        uuid: initial.id.uuid,
        bsdName: initial.id.bsdName,
        displayName: initial.displayName,
        physicalDiskID: initial.physicalDiskID,
        mediaGeneration: initial.mediaGeneration,
        health: .dirty
    )
    let setup = SuspendedSecondSetupFactsStore()
    let evidence = MutableVolumeEvidenceStore(initial)
    let coordinator = makeCoordinator(
        snapshots: [initial],
        setupFactsProvider: SetupFactsProvider { await setup.current() }
    )
    guard case let .accepted(effect) = await coordinator.requestEnableWriting(
        target: initial.instanceID
    ) else {
        fatalError("CHECK FAILED: final-evidence setup should produce a write mutation")
    }
    let probe = MutationInvocationProbe()
    let execution = Task {
        await coordinator.executeMutation(
            effect: effect,
            resolveEvidence: { await evidence.current() },
            invoke: { _ in await probe.invokeImmediately() }
        )
    }
    await setup.waitUntilSecondCallStarted()
    await evidence.replace(with: dirty)
    await setup.releaseSecondCall()

    await expectAsync(
        await execution.value == .rejected(.writeSafetyChanged(.dirtyFileSystem)),
        "the last async preflight read must be the volatile volume evidence"
    )
    await expectAsync(
        await probe.invocationCount == 0,
        "a volume that changed while setup was read must produce zero mutation invocations"
    )
}

func mountPreflightRevalidatesCompleteFreshVolumeFacts() async {
    let initial = makeSnapshot(
        uuid: "MOUNT-PREFLIGHT-1",
        bsdName: "disk42s1",
        displayName: "MOUNT-PREFLIGHT",
        physicalDiskID: PhysicalDiskID(rawValue: "disk42"),
        mediaGeneration: MediaGeneration(rawValue: 42)
    )
    let coordinator = makeCoordinator(
        snapshots: [initial],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(unmountEffect) = await coordinator.requestEnableWriting(
        target: initial.instanceID
    ) else {
        fatalError("CHECK FAILED: mount preflight setup should begin write enablement")
    }
    guard case let .unmountStandard(operationID, _) = unmountEffect else {
        fatalError("CHECK FAILED: mount preflight setup should begin with unmount")
    }
    await expectAsync(
        await coordinator.executeMutation(
            effect: unmountEffect,
            resolveEvidence: { volumeMutationEvidence(initial) },
            invoke: { _ in .exited(terminationStatus: 0) }
        ) == .executed,
        "the initial read-only unmount should pass complete fresh preflight"
    )
    _ = await coordinator.processSystemEvent(
        .unmountSucceeded(operationID: operationID),
        volumeID: initial.id
    )
    let unmounted = makeSnapshot(
        uuid: initial.id.uuid,
        bsdName: initial.id.bsdName,
        displayName: initial.displayName,
        physicalDiskID: initial.physicalDiskID,
        mediaGeneration: initial.mediaGeneration,
        mountAccess: .unmounted
    )
    guard case let .accepted(mountEffect) = await coordinator.processSystemEvent(
        .safetySnapshotReceived(operationID: operationID, snapshot: unmounted),
        volumeID: initial.id
    ) else {
        fatalError("CHECK FAILED: an unmounted safety snapshot should produce a mount effect")
    }

    let remountedByAnotherTool = makeSnapshot(
        uuid: initial.id.uuid,
        bsdName: initial.id.bsdName,
        displayName: initial.displayName,
        physicalDiskID: initial.physicalDiskID,
        mediaGeneration: initial.mediaGeneration,
        mountAccess: .readOnly
    )
    let probe = MutationInvocationProbe()
    await expectAsync(
        await coordinator.executeMutation(
            effect: mountEffect,
            resolveEvidence: { volumeMutationEvidence(remountedByAnotherTool) },
            invoke: { _ in await probe.invokeImmediately() }
        ) == .rejected(
            .unexpectedMountAccess(expected: .unmounted, observed: .readOnly)
        ),
        "mount preflight must reject a same-generation volume that was remounted after planning"
    )
    await expectAsync(
        await probe.invocationCount == 0,
        "changed fresh mount facts must produce zero writable-mount invocations"
    )
    await expectAsync(
        await coordinator.state(for: initial.id)
            == .writeOperationFailed(
                stage: .mountingWrite,
                failure: .inspectionUnavailable
            ),
        "changed mount facts must terminate the consumed operation without claiming writable"
    )
}

func writePreflightFailsClosedAndPreservesFreshSafetyReasons() async {
    let initial = makeSnapshot(
        uuid: "WRITE-PREFLIGHT-FACTS-1",
        bsdName: "disk44s1",
        displayName: "WRITE-PREFLIGHT-FACTS",
        physicalDiskID: PhysicalDiskID(rawValue: "disk44"),
        mediaGeneration: MediaGeneration(rawValue: 44)
    )

    let incompleteCoordinator = makeCoordinator(
        snapshots: [initial],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(incompleteEffect) = await incompleteCoordinator
        .requestEnableWriting(target: initial.instanceID)
    else {
        fatalError("CHECK FAILED: incomplete preflight setup should produce an effect")
    }
    let incompleteProbe = MutationInvocationProbe()
    await expectAsync(
        await incompleteCoordinator.executeMutation(
            effect: incompleteEffect,
            resolveEvidence: { volumeMutationEvidence(initial, isComplete: false) },
            invoke: { _ in await incompleteProbe.invokeImmediately() }
        ) == .rejected(.volumeObservationIncomplete),
        "an incomplete final volume observation must fail closed"
    )
    await expectAsync(
        await incompleteProbe.invocationCount == 0,
        "incomplete final volume facts must produce zero system mutations"
    )
    await expectAsync(
        await incompleteCoordinator.state(for: initial.id)
            == .writeOperationFailed(
                stage: .unmountingReadOnly,
                failure: .inspectionUnavailable
            ),
        "incomplete final volume facts must leave an explicit terminal state"
    )

    let dirtyCoordinator = makeCoordinator(
        snapshots: [initial],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(dirtyEffect) = await dirtyCoordinator.requestEnableWriting(
        target: initial.instanceID
    ) else {
        fatalError("CHECK FAILED: changed-safety preflight setup should produce an effect")
    }
    let dirty = makeSnapshot(
        uuid: initial.id.uuid,
        bsdName: initial.id.bsdName,
        displayName: initial.displayName,
        physicalDiskID: initial.physicalDiskID,
        mediaGeneration: initial.mediaGeneration,
        health: .dirty
    )
    let dirtyProbe = MutationInvocationProbe()
    await expectAsync(
        await dirtyCoordinator.executeMutation(
            effect: dirtyEffect,
            resolveEvidence: { volumeMutationEvidence(dirty) },
            invoke: { _ in await dirtyProbe.invokeImmediately() }
        ) == .rejected(.writeSafetyChanged(.dirtyFileSystem)),
        "changed final safety facts must preserve the exact write block"
    )
    await expectAsync(
        await dirtyProbe.invocationCount == 0,
        "a newly dirty volume must produce zero system mutations"
    )
    await expectAsync(
        await dirtyCoordinator.state(for: initial.id) == .writeBlocked(.dirtyFileSystem),
        "the durable UI state must preserve a newly discovered dirty-file-system block"
    )
}

func workflowInitializationReflectsActualMountAccess() {
    let readOnly = makeSnapshot(
        uuid: "INIT-READ-ONLY",
        bsdName: "disk27s1",
        displayName: "READ-ONLY"
    )
    expect(
        VolumeWorkflow(snapshot: readOnly).state == .readOnlyReady,
        "a verified read-only snapshot should initialize as read-only ready"
    )

    let unmounted = makeSnapshot(
        uuid: "INIT-UNMOUNTED",
        bsdName: "disk28s1",
        displayName: "UNMOUNTED",
        mountAccess: .unmounted
    )
    expect(
        VolumeWorkflow(snapshot: unmounted).state == .unmountedReady,
        "an unmounted snapshot must not be described as read-only mounted"
    )

    let existingWritable = makeSnapshot(
        uuid: "INIT-WRITABLE",
        bsdName: "disk29s1",
        displayName: "WRITABLE",
        mountAccess: .readWrite
    )
    expect(
        VolumeWorkflow(snapshot: existingWritable).state == .existingWriteMountUnverified(nil),
        "an existing writable mount must be verified before the UI claims it is managed"
    )

    let unsafeWritable = makeSnapshot(
        uuid: "INIT-UNSAFE-WRITABLE",
        bsdName: "disk30s1",
        displayName: "UNSAFE-WRITABLE",
        health: .hibernated,
        mountAccess: .readWrite
    )
    expect(
        VolumeWorkflow(snapshot: unsafeWritable).state
            == .existingWriteMountUnverified(.windowsHibernated),
        "an unsafe writable mount must expose the unexpected writable condition"
    )
}

func verifiedWritableIsRevokedByDetachOrReplacement() {
    var (detachedWorkflow, detachedInitial) = workflowReadyForEject(
        uuid: "DETACH-WRITABLE-1",
        bsdName: "disk31s1",
        physicalDisk: "disk31",
        generation: 24
    )
    expect(
        detachedWorkflow.handleDiskLifecycleEvent(
            .mediaRemoved(expected: detachedInitial.diskInstanceID)
        )
            == .accepted(.none),
        "a matching detach event should be accepted as new system truth"
    )
    expect(
        detachedWorkflow.state == .mediaUnavailable,
        "detaching the disk must immediately revoke verified writable state"
    )
    expect(
        detachedWorkflow.handle(
            .ejectRequested(operationID: OperationID(rawValue: "eject-detached"))
        ) == .rejected(.operationInProgress),
        "an unavailable old target must not emit another disk mutation"
    )

    var (replacedWorkflow, replacedInitial) = workflowReadyForEject(
        uuid: "REPLACE-WRITABLE-1",
        bsdName: "disk32s1",
        physicalDisk: "disk32",
        generation: 25
    )
    let replacement = DiskInstanceID(
        physicalDiskID: replacedInitial.physicalDiskID,
        mediaGeneration: MediaGeneration(rawValue: 26)
    )
    let mismatch = MediaInstanceMismatch(
        expected: replacedInitial.diskInstanceID,
        observed: replacement
    )
    expect(
        replacedWorkflow.handleDiskLifecycleEvent(
            .mediaReplaced(expected: replacedInitial.diskInstanceID, observed: replacement)
        )
            == .rejected(.mediaChanged(mismatch)),
        "replacement media should invalidate a previously writable workflow"
    )
    expect(
        replacedWorkflow.state == .mediaInvalidated(mismatch),
        "replacement media must immediately revoke verified writable state"
    )
}

func physicalDiskLifecycleEventsAtomicallyInvalidateEverySibling() async {
    let physicalDiskID = PhysicalDiskID(rawValue: "lifecycle-disk")
    let generation = MediaGeneration(rawValue: 40)
    let first = makeSnapshot(
        uuid: "LIFECYCLE-1",
        bsdName: "disk40s1",
        displayName: "LIFECYCLE-1",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let second = makeSnapshot(
        uuid: "LIFECYCLE-2",
        bsdName: "disk40s2",
        displayName: "LIFECYCLE-2",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation,
        mountAccess: .readWrite
    )
    let removedCoordinator = makeCoordinator(
        snapshots: [first, second],
        setupFactsProvider: readySetupFactsProvider()
    )
    _ = await removedCoordinator.requestEnableWriting(target: first.instanceID)
    let removedResult = await removedCoordinator.processDiskLifecycleEvent(
        .mediaRemoved(expected: first.diskInstanceID)
    )
    expect(
        removedResult == .applied([first.id, second.id]),
        "one disk removal event should atomically identify every sibling"
    )
    await expectAsync(
        await removedCoordinator.state(for: first.id) == .mediaUnavailable,
        "the active sibling must be invalidated by a whole-disk removal"
    )
    await expectAsync(
        await removedCoordinator.state(for: second.id) == .mediaUnavailable,
        "every other sibling must be invalidated in the same actor turn"
    )
    await expectAsync(
        await removedCoordinator.rebuildInventory(snapshots: []) == .rebuilt,
        "whole-disk removal must release the physical-disk lease after all siblings are invalidated"
    )

    let replacedCoordinator = makeCoordinator(
        snapshots: [first, second],
        setupFactsProvider: readySetupFactsProvider()
    )
    let replacement = DiskInstanceID(
        physicalDiskID: physicalDiskID,
        mediaGeneration: MediaGeneration(rawValue: 41)
    )
    let replacedResult = await replacedCoordinator.processDiskLifecycleEvent(
        .mediaReplaced(expected: first.diskInstanceID, observed: replacement)
    )
    expect(
        replacedResult == .applied([first.id, second.id]),
        "one replacement event should atomically invalidate every old-generation sibling"
    )
    let mismatch = MediaInstanceMismatch(expected: first.diskInstanceID, observed: replacement)
    await expectAsync(
        await replacedCoordinator.state(for: first.id) == .mediaInvalidated(mismatch),
        "the first sibling should expose the replacement generation"
    )
    await expectAsync(
        await replacedCoordinator.state(for: second.id) == .mediaInvalidated(mismatch),
        "the second sibling should expose the same replacement generation"
    )

    let newGenerationFirst = makeSnapshot(
        uuid: first.id.uuid,
        bsdName: first.id.bsdName,
        displayName: first.displayName,
        physicalDiskID: physicalDiskID,
        mediaGeneration: replacement.mediaGeneration
    )
    await expectAsync(
        await replacedCoordinator.rebuildInventory(snapshots: [newGenerationFirst]) == .rebuilt,
        "replacement invalidation should permit a fresh inventory rebuild"
    )
    await expectAsync(
        await replacedCoordinator.processDiskLifecycleEvent(
            .mediaRemoved(expected: first.diskInstanceID)
        ) == .ignored,
        "a delayed old-generation removal must not invalidate the rebuilt media instance"
    )
    await expectAsync(
        await replacedCoordinator.state(for: newGenerationFirst.id) == .readOnlyReady,
        "late lifecycle callbacks must leave the current media generation intact"
    )
}

func systemEvidenceMediaChangeInvalidatesEverySibling() async {
    let physicalDiskID = PhysicalDiskID(rawValue: "disk51")
    let generation = MediaGeneration(rawValue: 52)
    let first = makeSnapshot(
        uuid: "EVIDENCE-MEDIA-1",
        bsdName: "disk51s1",
        displayName: "EVIDENCE-MEDIA-1",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let sibling = makeSnapshot(
        uuid: "EVIDENCE-MEDIA-2",
        bsdName: "disk51s2",
        displayName: "EVIDENCE-MEDIA-2",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let coordinator = makeCoordinator(
        snapshots: [first, sibling],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(effect) = await coordinator.requestEnableWriting(
        target: first.instanceID
    ) else {
        fatalError("CHECK FAILED: evidence-media setup should produce unmount")
    }
    guard case let .unmountStandard(operationID, _) = effect else {
        fatalError("CHECK FAILED: evidence-media setup should start with unmount")
    }
    _ = await coordinator.executeMutation(
        effect: effect,
        resolveEvidence: { volumeMutationEvidence(first) },
        invoke: { _ in .exited(terminationStatus: 0) }
    )
    _ = await coordinator.processSystemEvent(
        .unmountSucceeded(operationID: operationID),
        volumeID: first.id
    )
    let replacement = makeSnapshot(
        uuid: first.id.uuid,
        bsdName: first.id.bsdName,
        displayName: first.displayName,
        physicalDiskID: physicalDiskID,
        mediaGeneration: MediaGeneration(rawValue: 53),
        mountAccess: .unmounted
    )
    let mismatch = MediaInstanceMismatch(
        expected: first.diskInstanceID,
        observed: replacement.diskInstanceID
    )
    await expectAsync(
        await coordinator.processSystemEvent(
            .safetySnapshotReceived(operationID: operationID, snapshot: replacement),
            volumeID: first.id
        ) == .rejected(.mediaChanged(mismatch)),
        "a changed generation found in system evidence must reject the operation"
    )
    await expectAsync(
        await coordinator.state(for: first.id) == .mediaInvalidated(mismatch),
        "system evidence must invalidate the selected workflow"
    )
    await expectAsync(
        await coordinator.state(for: sibling.id) == .mediaInvalidated(mismatch),
        "system evidence must broadcast the generation change to every sibling"
    )
}

func diskRemovalKeepsAnExecutingMutationTombstoneUntilTheProcessStops() async {
    let initial = makeSnapshot(
        uuid: "LIFECYCLE-EXECUTING-1",
        bsdName: "disk43s1",
        displayName: "LIFECYCLE-EXECUTING",
        physicalDiskID: PhysicalDiskID(rawValue: "disk43"),
        mediaGeneration: MediaGeneration(rawValue: 43)
    )
    let coordinator = makeCoordinator(
        snapshots: [initial],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(effect) = await coordinator.requestEnableWriting(
        target: initial.instanceID
    ) else {
        fatalError("CHECK FAILED: lifecycle tombstone setup should produce a mutation")
    }
    let probe = MutationInvocationProbe()
    let execution = Task {
        await coordinator.executeMutation(
            effect: effect,
            resolveEvidence: { volumeMutationEvidence(initial) },
            invoke: { _ in await probe.invokeAndWait() }
        )
    }
    await probe.waitUntilStarted()

    await expectAsync(
        await coordinator.processDiskLifecycleEvent(
            .mediaRemoved(expected: initial.diskInstanceID)
        ) == .applied([initial.id]),
        "disk removal should immediately revoke the old workflow state"
    )
    await expectAsync(
        await coordinator.state(for: initial.id) == .mediaUnavailable,
        "removal must revoke writable claims even while the old process is still running"
    )
    await expectAsync(
        await coordinator.rebuildInventory(snapshots: [])
            == .operationsInProgress([initial.physicalDiskID]),
        "an executing old mutation must leave a tombstone that blocks inventory rebuild"
    )

    await probe.release()
    await expectAsync(
        await execution.value == .executed,
        "the old invocation should eventually confirm real process termination"
    )
    await expectAsync(
        await coordinator.rebuildInventory(snapshots: []) == .rebuilt,
        "only real process termination may release a lifecycle tombstone"
    )
}

func settledWriteFailuresAndInspectionTimeoutsReachATerminalState() {
    let initial = makeSnapshot(
        uuid: "WRITE-FAILURE-1",
        bsdName: "disk33s1",
        displayName: "WRITE-FAILURE",
        physicalDiskID: PhysicalDiskID(rawValue: "disk33"),
        mediaGeneration: MediaGeneration(rawValue: 27)
    )
    let cases: [(WriteOperationStage, WriteOperationFailure)] = [
        (.unmountingReadOnly, .engineFailed),
        (.inspectingSafety, .timedOut),
        (.mountingWrite, .engineFailed),
        (.inspectingWriteMount, .timedOut),
    ]

    for (index, entry) in cases.enumerated() {
        let (stage, failure) = entry
        var workflow = VolumeWorkflow(snapshot: initial)
        let operationID = OperationID(rawValue: "write-failure-\(index)")
        _ = workflow.handle(.enableWritingRequested(operationID: operationID))
        if stage != .unmountingReadOnly {
            _ = workflow.handle(.unmountSucceeded(operationID: operationID))
        }
        if stage == .mountingWrite || stage == .inspectingWriteMount {
            _ = workflow.handle(
                .safetySnapshotReceived(
                    operationID: operationID,
                    snapshot: makeSnapshot(
                        uuid: initial.id.uuid,
                        bsdName: initial.id.bsdName,
                        displayName: initial.displayName,
                        physicalDiskID: initial.physicalDiskID,
                        mediaGeneration: initial.mediaGeneration,
                        mountAccess: .unmounted
                    )
                )
            )
        }
        if stage == .inspectingWriteMount {
            _ = workflow.handle(.mountCommandSucceeded(operationID: operationID))
        }

        let result = workflow.handle(
            .writeOperationFailed(
                operationID: operationID,
                stage: stage,
                failure: failure
            )
        )

        expect(
            result == .rejected(.writeOperationFailed(stage: stage, failure: failure)),
            "a settled matching failure at \(stage) should terminate the operation"
        )
        expect(
            workflow.state == .writeOperationFailed(stage: stage, failure: failure),
            "a settled matching failure at \(stage) should expose a recoverable terminal state"
        )
        expect(workflow.activeOperationID == nil, "a settled terminal failure should clear the active operation")
    }

    var staleWorkflow = VolumeWorkflow(snapshot: initial)
    let current = OperationID(rawValue: "current-write-failure")
    _ = staleWorkflow.handle(.enableWritingRequested(operationID: current))
    expect(
        staleWorkflow.handle(
            .writeOperationFailed(
                operationID: OperationID(rawValue: "stale-write-failure"),
                stage: .unmountingReadOnly,
                failure: .timedOut
            )
        ) == .ignored,
        "a stale failure must not terminate the current operation"
    )
    expect(staleWorkflow.activeOperationID == current, "stale failure must not clear the current operation")
}

func commandTimeoutOrCancellationKeepsTheDiskLeaseUntilQuiescedAndReconciled() async {
    for (index, failure) in [WriteOperationFailure.timedOut, .cancelled].enumerated() {
        let physicalDiskID = PhysicalDiskID(rawValue: "uncertain-disk-\(index)")
        let generation = MediaGeneration(rawValue: UInt64(50 + index))
        let first = makeSnapshot(
            uuid: "UNCERTAIN-\(index)-1",
            bsdName: "disk\(50 + index)s1",
            displayName: "UNCERTAIN-FIRST",
            physicalDiskID: physicalDiskID,
            mediaGeneration: generation
        )
        let sibling = makeSnapshot(
            uuid: "UNCERTAIN-\(index)-2",
            bsdName: "disk\(50 + index)s2",
            displayName: "UNCERTAIN-SIBLING",
            physicalDiskID: physicalDiskID,
            mediaGeneration: generation
        )
        let coordinator = makeCoordinator(
            snapshots: [first, sibling],
            setupFactsProvider: readySetupFactsProvider()
        )
        guard case let .accepted(effect) = await coordinator.requestEnableWriting(
            target: first.instanceID
        ) else {
            fatalError("CHECK FAILED: uncertainty setup should begin a write operation")
        }
        guard case let .unmountStandard(operationID, _) = effect else {
            fatalError("CHECK FAILED: uncertainty setup should begin with unmount")
        }
        let probe = MutationInvocationProbe()
        let execution = Task {
            await coordinator.executeMutation(
                effect: effect,
                resolveEvidence: { volumeMutationEvidence(first) },
                invoke: { _ in await probe.invokeAndWait() }
            )
        }
        await probe.waitUntilStarted()

        let uncertainResult = await coordinator.processSystemEvent(
            .writeOperationFailed(
                operationID: operationID,
                stage: .unmountingReadOnly,
                failure: failure
            ),
            volumeID: first.id
        )
        expect(
            uncertainResult == .rejected(
                .writeOperationFailed(stage: .unmountingReadOnly, failure: failure)
            ),
            "timeout or cancellation should be reported without pretending the command stopped"
        )
        await expectAsync(
            await coordinator.state(for: first.id)
                == .writeMutationQuiescencePending(stage: .unmountingReadOnly, failure: failure),
            "an executing command with uncertain outcome must remain in a quiescence state"
        )
        await expectAsync(
            await coordinator.requestEnableWriting(target: sibling.instanceID)
                == .rejected(.operationInProgress),
            "a sibling write must stay blocked while the old command may still mutate"
        )
        await expectAsync(
            await coordinator.requestEject(target: sibling.instanceID)
                == .rejected(.operationInProgress),
            "safe eject must not overlap a timed-out or cancelled command that is still alive"
        )
        await expectAsync(
            await coordinator.rebuildInventory(snapshots: [first, sibling])
                == .operationsInProgress([physicalDiskID]),
            "inventory rebuild must not erase an uncertain mutation lease"
        )
        await expectAsync(
            await coordinator.processSystemEvent(
                .writeMutationQuiesced(
                    operationID: operationID,
                    stage: .unmountingReadOnly
                ),
                volumeID: first.id
            ) == .ignored,
            "a quiescence claim must be ignored while the mutation executor is still running"
        )

        await probe.release()
        await expectAsync(
            await execution.value == .executed,
            "the one-shot executor should eventually settle"
        )
        await expectAsync(
            await coordinator.processSystemEvent(
                .writeMutationQuiesced(
                    operationID: operationID,
                    stage: .unmountingReadOnly
                ),
                volumeID: first.id
            ) == .accepted(
                .inspectWriteMutationReconciliation(
                    operationID: operationID,
                    target: first.instanceID
                )
            ),
            "process termination should trigger a fresh reconciliation observation"
        )
        await expectAsync(
            await coordinator.state(for: first.id)
                == .awaitingWriteMutationReconciliation(
                    stage: .unmountingReadOnly,
                    failure: failure
                ),
            "termination alone must not release the physical-disk lease"
        )
        await expectAsync(
            await coordinator.processSystemEvent(
                .writeMutationReconciliationObserved(
                    operationID: operationID,
                    observation: WriteMutationReconciliationObservation(
                        snapshot: first,
                        isComplete: false
                    )
                ),
                volumeID: first.id
            ) == .accepted(
                .inspectWriteMutationReconciliation(
                    operationID: operationID,
                    target: first.instanceID
                )
            ),
            "incomplete reconciliation evidence must keep waiting fail-closed"
        )
        let settledSnapshot = makeSnapshot(
            uuid: first.id.uuid,
            bsdName: first.id.bsdName,
            displayName: first.displayName,
            physicalDiskID: physicalDiskID,
            mediaGeneration: generation,
            mountAccess: .unmounted
        )
        await expectAsync(
            await coordinator.processSystemEvent(
                .writeMutationReconciliationObserved(
                    operationID: operationID,
                    observation: WriteMutationReconciliationObservation(
                        snapshot: settledSnapshot,
                        isComplete: true
                    )
                ),
                volumeID: first.id
            ) == .rejected(
                .writeOperationFailed(stage: .unmountingReadOnly, failure: failure)
            ),
            "only complete fresh facts after real process exit may settle the uncertainty"
        )
        await expectAsync(
            await coordinator.state(for: first.id)
                == .writeOperationFailed(stage: .unmountingReadOnly, failure: failure),
            "reconciliation should end in a non-writable terminal failure state"
        )
        let retry = await coordinator.requestEnableWriting(target: sibling.instanceID)
        expect(
            {
                if case .accepted(.unmountStandard) = retry { return true }
                return false
            }(),
            "a sibling may begin only after quiescence and complete reconciliation"
        )
    }
}

func mutationCallbacksCannotBypassOrOutrunTheOneShotExecutor() async {
    let physicalDiskID = PhysicalDiskID(rawValue: "callback-gate-disk")
    let generation = MediaGeneration(rawValue: 60)
    let first = makeSnapshot(
        uuid: "CALLBACK-GATE-1",
        bsdName: "disk60s1",
        displayName: "CALLBACK-GATE-1",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let sibling = makeSnapshot(
        uuid: "CALLBACK-GATE-2",
        bsdName: "disk60s2",
        displayName: "CALLBACK-GATE-2",
        physicalDiskID: physicalDiskID,
        mediaGeneration: generation
    )
    let coordinator = makeCoordinator(
        snapshots: [first, sibling],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(effect) = await coordinator.requestEnableWriting(
        target: first.instanceID
    ) else {
        fatalError("CHECK FAILED: callback gate setup should produce an effect")
    }
    guard case let .unmountStandard(operationID, _) = effect else {
        fatalError("CHECK FAILED: callback gate should begin with unmount")
    }

    await expectAsync(
        await coordinator.processSystemEvent(
            .unmountSucceeded(operationID: operationID),
            volumeID: first.id
        ) == .ignored,
        "a success callback must not advance a mutation that was never claimed by the executor"
    )
    await expectAsync(
        await coordinator.processSystemEvent(
            .writeOperationFailed(
                operationID: operationID,
                stage: .unmountingReadOnly,
                failure: .engineFailed
            ),
            volumeID: first.id
        ) == .ignored,
        "a failure callback must not settle a mutation that was never claimed by the executor"
    )
    await expectAsync(
        await coordinator.state(for: first.id) == .unmountingForWrite,
        "unclaimed callbacks must leave the one-shot mutation intent active"
    )

    let probe = MutationInvocationProbe()
    let execution = Task {
        await coordinator.executeMutation(
            effect: effect,
            resolveEvidence: { volumeMutationEvidence(first) },
            invoke: { _ in await probe.invokeAndWait() }
        )
    }
    await probe.waitUntilStarted()
    await expectAsync(
        await coordinator.processSystemEvent(
            .writeOperationFailed(
                operationID: operationID,
                stage: .unmountingReadOnly,
                failure: .engineFailed
            ),
            volumeID: first.id
        ) == .ignored,
        "a definitive failure callback must not release the lease while its executor is still alive"
    )
    await expectAsync(
        await coordinator.requestEnableWriting(target: sibling.instanceID)
            == .rejected(.operationInProgress),
        "a premature failure callback must not permit an overlapping sibling mutation"
    )

    await probe.release()
    await expectAsync(
        await execution.value == .executed,
        "the claimed executor should settle exactly once"
    )
    await expectAsync(
        await coordinator.processSystemEvent(
            .writeOperationFailed(
                operationID: operationID,
                stage: .unmountingReadOnly,
                failure: .engineFailed
            ),
            volumeID: first.id
        ) == .rejected(
            .writeOperationFailed(stage: .unmountingReadOnly, failure: .engineFailed)
        ),
        "the same definitive failure may settle the workflow only after the executor exits"
    )

    let settledCoordinator = makeCoordinator(
        snapshots: [first, sibling],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(settledEffect) = await settledCoordinator.requestEnableWriting(
        target: first.instanceID
    ) else {
        fatalError("CHECK FAILED: settled-timeout setup should produce an effect")
    }
    guard case let .unmountStandard(settledOperationID, _) = settledEffect else {
        fatalError("CHECK FAILED: settled-timeout setup should begin with unmount")
    }
    await expectAsync(
        await settledCoordinator.executeMutation(
            effect: settledEffect,
            resolveEvidence: { volumeMutationEvidence(first) },
            invoke: { _ in .exited(terminationStatus: 0) }
        ) == .executed,
        "the mutation invocation should be known to have exited"
    )
    _ = await settledCoordinator.processSystemEvent(
        .writeOperationFailed(
            operationID: settledOperationID,
            stage: .unmountingReadOnly,
            failure: .timedOut
        ),
        volumeID: first.id
    )
    await expectAsync(
        await settledCoordinator.state(for: first.id)
            == .writeMutationQuiescencePending(
                stage: .unmountingReadOnly,
                failure: .timedOut
            ),
        "a timeout after process exit must still require a fresh reconciliation observation"
    )
}

func delayedUnmountObservationRetriesUntilFreshFactsOrTimeout() {
    let initial = makeSnapshot(
        uuid: "UNMOUNT-DELAY-1",
        bsdName: "disk34s1",
        displayName: "UNMOUNT-DELAY",
        physicalDiskID: PhysicalDiskID(rawValue: "disk34"),
        mediaGeneration: MediaGeneration(rawValue: 28)
    )
    var workflow = VolumeWorkflow(snapshot: initial)
    let operationID = OperationID(rawValue: "unmount-delay")
    _ = workflow.handle(.enableWritingRequested(operationID: operationID))
    _ = workflow.handle(.unmountSucceeded(operationID: operationID))

    let notSettled = workflow.handle(
        .safetySnapshotReceived(operationID: operationID, snapshot: initial)
    )
    expect(
        notSettled == .accepted(
            .inspectSafetySnapshot(operationID: operationID, target: initial.instanceID)
        ),
        "a not-yet-settled unmount should request another fresh observation"
    )
    expect(
        workflow.state == .awaitingSafetySnapshot,
        "a transient observation should keep waiting under the same operation"
    )

    let settled = makeSnapshot(
        uuid: initial.id.uuid,
        bsdName: initial.id.bsdName,
        displayName: initial.displayName,
        physicalDiskID: initial.physicalDiskID,
        mediaGeneration: initial.mediaGeneration,
        mountAccess: .unmounted
    )
    expect(
        workflow.handle(
            .safetySnapshotReceived(operationID: operationID, snapshot: settled)
        ) == .accepted(
            .mountReadWrite(
                MountPlan(
                    operationID: operationID,
                    target: initial.instanceID,
                    policy: .fsKitCurrentUserNoRecovery
                )
            )
        ),
        "a later fresh unmounted snapshot should continue the same write operation"
    )
}

func presentationLayerKeepsSafetyActionsExplicit() {
    let presentationMismatch = MediaInstanceMismatch(
        expected: DiskInstanceID(
            physicalDiskID: PhysicalDiskID(rawValue: "presentation-disk"),
            mediaGeneration: MediaGeneration(rawValue: 1)
        ),
        observed: DiskInstanceID(
            physicalDiskID: PhysicalDiskID(rawValue: "presentation-disk"),
            mediaGeneration: MediaGeneration(rawValue: 2)
        )
    )
    let everyState: [VolumeState] = [
        .readOnlyReady,
        .unmountedReady,
        .existingWriteMountUnverified(nil),
        .unmountingForWrite,
        .awaitingSafetySnapshot,
        .mountingWrite,
        .awaitingWriteVerification,
        .writable,
        .writeVerificationFailed(.unexpectedBackend),
        .unmountingForEject,
        .awaitingUnmountVerification,
        .ejecting,
        .awaitingRemovalVerification,
        .safeToRemove,
        .ejectFailed(.busy),
        .ejectBlocked(.protectedSibling),
        .writeBlocked(.windowsHibernated),
        .mediaInvalidated(presentationMismatch),
        .mediaUnavailable,
        .writeOperationFailed(stage: .mountingWrite, failure: .timedOut),
        .writeMutationQuiescencePending(stage: .mountingWrite, failure: .timedOut),
        .awaitingWriteMutationReconciliation(stage: .mountingWrite, failure: .timedOut),
        .ejectMutationQuiescencePending(
            stage: .ejectingPhysicalDisk,
            failure: .timedOut
        ),
        .awaitingEjectMutationReconciliation(
            stage: .ejectingPhysicalDisk,
            failure: .cancelled
        ),
    ]
    for state in everyState {
        let presentation = present(state)
        expect(!presentation.title.isEmpty, "every state should have a text title")
        expect(!presentation.detail.isEmpty, "every state should explain what it means")
    }

    let readOnly = present(.readOnlyReady)
    expect(readOnly.primaryAction == .enableWriting, "read-only state should offer explicit write enablement")
    expect(
        readOnly.secondaryActions == [.openInFinder, .safeEject],
        "read-only state should retain native access and safe eject"
    )

    let blocked = present(.writeBlocked(.windowsHibernated))
    expect(blocked.primaryAction == .viewResolution, "blocked state should lead with remediation")
    expect(
        blocked.secondaryActions == [.safeEject, .copyDiagnostics],
        "a write block must never hide safe eject"
    )

    let busyStates: [VolumeState] = [
        .unmountingForWrite,
        .awaitingSafetySnapshot,
        .mountingWrite,
        .awaitingWriteVerification,
        .unmountingForEject,
        .awaitingUnmountVerification,
        .ejecting,
        .awaitingRemovalVerification,
        .writeMutationQuiescencePending(stage: .mountingWrite, failure: .timedOut),
        .awaitingWriteMutationReconciliation(stage: .mountingWrite, failure: .timedOut),
        .ejectMutationQuiescencePending(
            stage: .ejectingPhysicalDisk,
            failure: .timedOut
        ),
        .awaitingEjectMutationReconciliation(
            stage: .ejectingPhysicalDisk,
            failure: .cancelled
        ),
    ]
    for state in busyStates {
        let presentation = present(state)
        expect(presentation.isBusy, "in-flight state should expose progress semantics")
        expect(presentation.primaryAction == nil, "in-flight state must not offer a duplicate action")
    }

    let writable = present(.writable)
    expect(writable.primaryAction == .openInFinder, "verified writable state should lead to Finder")
    expect(writable.secondaryActions == [.safeEject], "verified writable state should expose safe eject")

    let safe = present(.safeToRemove)
    expect(safe.primaryAction == .finish, "verified absence should provide a completion action")

    let ejectFailure = present(.ejectFailed(.busy))
    expect(ejectFailure.primaryAction == .retryEject, "recoverable eject failure should offer retry")

    let ejectBlock = present(.ejectBlocked(.protectedSibling))
    expect(
        ejectBlock.primaryAction == .viewResolution,
        "a protected physical disk must explain the block instead of offering blind retry"
    )
    expect(
        !ejectBlock.secondaryActions.contains(.safeEject),
        "a protected physical disk must not expose another eject action"
    )
    expect(
        ejectFailure.secondaryActions == [.copyDiagnostics],
        "eject failure should make diagnostics available without offering force"
    )

    let invalidated = present(.mediaInvalidated(presentationMismatch))
    expect(invalidated.primaryAction == nil, "invalidated media must not offer an old-target mutation")
    expect(
        invalidated.secondaryActions == [.copyDiagnostics],
        "invalidated media should wait for inventory rebuild instead of offering eject"
    )

    let unverifiedWritable = present(
        .existingWriteMountUnverified(.windowsHibernated)
    )
    expect(
        unverifiedWritable.primaryAction == .viewResolution,
        "an existing unverified writable mount must lead with a safety explanation"
    )
    expect(
        unverifiedWritable.secondaryActions == [.safeEject, .copyDiagnostics],
        "an existing unverified writable mount should only offer safe recovery actions"
    )
}

func volumePresentationUsesAFixedActionAndDisableMatrix() {
    struct MatrixRow {
        let name: String
        let state: VolumeState
        let primaryAction: PresentationAction?
        let secondaryActions: [PresentationAction]
        let isBusy: Bool
    }

    let mismatch = MediaInstanceMismatch(
        expected: DiskInstanceID(
            physicalDiskID: PhysicalDiskID(rawValue: "matrix-disk"),
            mediaGeneration: MediaGeneration(rawValue: 1)
        ),
        observed: DiskInstanceID(
            physicalDiskID: PhysicalDiskID(rawValue: "matrix-disk"),
            mediaGeneration: MediaGeneration(rawValue: 2)
        )
    )
    let rows: [MatrixRow] = [
        MatrixRow(name: "readOnlyReady", state: .readOnlyReady, primaryAction: .enableWriting, secondaryActions: [.openInFinder, .safeEject], isBusy: false),
        MatrixRow(name: "unmountedReady", state: .unmountedReady, primaryAction: .enableWriting, secondaryActions: [.safeEject], isBusy: false),
        MatrixRow(name: "existingWriteMountUnverified", state: .existingWriteMountUnverified(nil), primaryAction: .viewResolution, secondaryActions: [.safeEject, .copyDiagnostics], isBusy: false),
        MatrixRow(name: "unmountingForWrite", state: .unmountingForWrite, primaryAction: nil, secondaryActions: [], isBusy: true),
        MatrixRow(name: "awaitingSafetySnapshot", state: .awaitingSafetySnapshot, primaryAction: nil, secondaryActions: [], isBusy: true),
        MatrixRow(name: "mountingWrite", state: .mountingWrite, primaryAction: nil, secondaryActions: [], isBusy: true),
        MatrixRow(name: "awaitingWriteVerification", state: .awaitingWriteVerification, primaryAction: nil, secondaryActions: [], isBusy: true),
        MatrixRow(name: "writable", state: .writable, primaryAction: .openInFinder, secondaryActions: [.safeEject], isBusy: false),
        MatrixRow(name: "writeVerificationFailed", state: .writeVerificationFailed(.unexpectedBackend), primaryAction: .viewResolution, secondaryActions: [.safeEject, .copyDiagnostics], isBusy: false),
        MatrixRow(name: "unmountingForEject", state: .unmountingForEject, primaryAction: nil, secondaryActions: [], isBusy: true),
        MatrixRow(name: "awaitingUnmountVerification", state: .awaitingUnmountVerification, primaryAction: nil, secondaryActions: [], isBusy: true),
        MatrixRow(name: "ejecting", state: .ejecting, primaryAction: nil, secondaryActions: [], isBusy: true),
        MatrixRow(name: "awaitingRemovalVerification", state: .awaitingRemovalVerification, primaryAction: nil, secondaryActions: [], isBusy: true),
        MatrixRow(name: "safeToRemove", state: .safeToRemove, primaryAction: .finish, secondaryActions: [], isBusy: false),
        MatrixRow(name: "ejectFailed", state: .ejectFailed(.busy), primaryAction: .retryEject, secondaryActions: [.copyDiagnostics], isBusy: false),
        MatrixRow(name: "ejectBlocked", state: .ejectBlocked(.protectedSibling), primaryAction: .viewResolution, secondaryActions: [.copyDiagnostics], isBusy: false),
        MatrixRow(name: "writeBlocked", state: .writeBlocked(.windowsHibernated), primaryAction: .viewResolution, secondaryActions: [.safeEject, .copyDiagnostics], isBusy: false),
        MatrixRow(name: "mediaInvalidated", state: .mediaInvalidated(mismatch), primaryAction: nil, secondaryActions: [.copyDiagnostics], isBusy: false),
        MatrixRow(name: "mediaUnavailable", state: .mediaUnavailable, primaryAction: .finish, secondaryActions: [], isBusy: false),
        MatrixRow(name: "writeOperationFailed", state: .writeOperationFailed(stage: .mountingWrite, failure: .timedOut), primaryAction: .viewResolution, secondaryActions: [.safeEject, .copyDiagnostics], isBusy: false),
        MatrixRow(name: "writeMutationQuiescencePending", state: .writeMutationQuiescencePending(stage: .mountingWrite, failure: .timedOut), primaryAction: nil, secondaryActions: [], isBusy: true),
        MatrixRow(name: "awaitingWriteMutationReconciliation", state: .awaitingWriteMutationReconciliation(stage: .mountingWrite, failure: .timedOut), primaryAction: nil, secondaryActions: [], isBusy: true),
        MatrixRow(name: "ejectMutationQuiescencePending", state: .ejectMutationQuiescencePending(stage: .ejectingPhysicalDisk, failure: .timedOut), primaryAction: nil, secondaryActions: [], isBusy: true),
        MatrixRow(name: "awaitingEjectMutationReconciliation", state: .awaitingEjectMutationReconciliation(stage: .ejectingPhysicalDisk, failure: .cancelled), primaryAction: nil, secondaryActions: [], isBusy: true),
    ]

    for row in rows {
        let presentation = present(row.state)
        expect(
            presentation.primaryAction == row.primaryAction,
            "\(row.name) must keep its fixed primary action"
        )
        expect(
            presentation.secondaryActions == row.secondaryActions,
            "\(row.name) must keep its fixed ordered secondary actions"
        )
        expect(
            presentation.isBusy == row.isBusy,
            "\(row.name) must keep its fixed busy state"
        )
        expect(
            presentation.actionsEnabled == !row.isBusy,
            "\(row.name) must expose one explicit action-disable rule"
        )
        if row.isBusy {
            expect(
                presentation.primaryAction == nil && presentation.secondaryActions.isEmpty,
                "\(row.name) must not retain an action while busy"
            )
        }
    }

    let diskBusy = VolumePresenter.presentation(
        for: VolumeStatusSnapshot(
            state: .readOnlyReady,
            safeEjectAvailability: .available,
            isPhysicalDiskBusy: true
        )
    )
    expect(
        diskBusy.isBusy
            && !diskBusy.actionsEnabled
            && diskBusy.primaryAction == nil
            && diskBusy.secondaryActions.isEmpty,
        "a sibling lease must disable and remove every stale action"
    )

    let blockedEject = present(
        .readOnlyReady,
        safeEjectAvailability: .blocked(.protectedSibling)
    )
    expect(
        blockedEject.primaryAction == .enableWriting
            && blockedEject.secondaryActions == [.openInFinder]
            && blockedEject.actionsEnabled,
        "safe-eject unavailability must remove only that action"
    )
}

func setupPresentationShowsReadyEnvironment() {
    let presentation = SetupPresenter.presentation(
        for: SetupChecker.assess(readySetupFacts()),
        isRefreshing: false
    )

    expect(presentation.title == "首次设置已完成", "ready setup should have a precise title")
    expect(presentation.isReady, "ready setup should expose readiness")
    expect(!presentation.isBusy, "ready setup should not be busy")
    expect(presentation.primaryAction == .recheck, "ready setup should only offer recheck")
    expect(
        presentation.requirements.map(\.id) == [
            .operatingSystem,
            .architecture,
            .macFUSE,
            .fileSystemExtension,
            .ntfs3G,
            .backend,
            .authorization,
            .conflictingDrivers,
        ],
        "setup requirements should use one stable UI order"
    )
    expect(
        presentation.requirements.allSatisfy {
            $0.state == .satisfied && $0.statusText == "已满足"
        },
        "ready setup should mark every requirement as satisfied in text"
    )
    let conflictRequirement = presentation.requirements.first { $0.id == .conflictingDrivers }
    expect(
        conflictRequirement?.detail.contains("范围") == true
            && conflictRequirement?.detail.contains("未检测到其他 NTFS 写入驱动") == false,
        "successful conflict evidence must describe its approved scope rather than global absence"
    )
}

func setupPresentationNormalizesActionableFailuresWithoutLeakingDriverNames() {
    let assessment = SetupAssessment(
        issues: [
            .conflictingDrivers([
                "/Users/private-account/Library/secret.driver",
                "secret.driver",
                "",
                "other.driver",
            ]),
            .unsafeBackend(.kernelExtension),
            .requiredAuthorizationUnavailable(.denied),
            .ntfs3GTooOld(
                minimum: SemanticVersion(major: 2026, minor: 7, patch: 7),
                observed: SemanticVersion(major: 2026, minor: 2, patch: 25)
            ),
            .fileSystemExtensionDisabled,
            .macFUSETooOld(
                minimum: SemanticVersion(major: 5, minor: 3, patch: 3),
                observed: SemanticVersion(major: 5, minor: 2, patch: 9)
            ),
            .macFUSEMissing,
            .unsupportedArchitecture(.intel),
            .unsupportedOperatingSystem(
                minimum: SemanticVersion(major: 15, minor: 4, patch: 0),
                observed: SemanticVersion(major: 15, minor: 3, patch: 9)
            ),
        ]
    )

    let presentation = SetupPresenter.presentation(for: assessment, isRefreshing: false)
    let rows = Dictionary(uniqueKeysWithValues: presentation.requirements.map { ($0.id, $0) })

    expect(!presentation.isReady, "any setup issue should keep setup presentation unready")
    expect(!presentation.isBusy, "settled setup failures should not be busy")
    expect(
        presentation.primaryAction == .continueSetup,
        "settled failures should lead to the in-window setup guide"
    )
    expect(
        presentation.primaryAction?.title == "继续设置",
        "the setup action should use explicit user-facing text"
    )
    expect(
        presentation.secondaryActions == [.copyDiagnostics],
        "settled failures should offer one diagnostics action"
    )
    expect(presentation.requirements.count == 8, "duplicate issues must still produce eight rows")
    expect(
        presentation.requirements.map(\.id) == [
            .operatingSystem,
            .architecture,
            .macFUSE,
            .fileSystemExtension,
            .ntfs3G,
            .backend,
            .authorization,
            .conflictingDrivers,
        ],
        "failure rows should keep the stable UI order"
    )
    expect(
        presentation.requirements.allSatisfy {
            $0.state == .actionRequired
                && $0.statusText == "待处理"
                && !$0.title.isEmpty
                && !$0.detail.isEmpty
        },
        "every failed category should provide explicit text"
    )
    expect(
        rows[.operatingSystem]?.detail.contains("15.3.9") == true
            && rows[.operatingSystem]?.detail.contains("15.4.0") == true,
        "operating system guidance should show observed and minimum versions"
    )
    expect(
        rows[.macFUSE]?.title == "确认官方 macFUSE",
        "a missing dependency should deterministically outrank an old-version duplicate"
    )
    expect(
        rows[.ntfs3G]?.detail.contains("2026.2.25") == true
            && rows[.ntfs3G]?.detail.contains("2026.7.7") == true,
        "NTFS-3G guidance should show observed and minimum versions"
    )
    expect(
        rows[.conflictingDrivers]?.detail.contains("2 个") == true,
        "conflict guidance should count unique nonempty driver names"
    )
    let visibleText = presentation.requirements
        .map { "\($0.title) \($0.detail)" }
        .joined(separator: " ")
    expect(
        !visibleText.contains("private-account")
            && !visibleText.contains("secret.driver")
            && !visibleText.contains("other.driver"),
        "setup presentation must not expose raw driver names or paths"
    )
}

func setupPresentationFailsClosedWhileRefreshing() {
    let presentation = SetupPresenter.presentation(
        for: SetupAssessment(issues: []),
        isRefreshing: true
    )

    expect(presentation.title == "正在检查运行环境", "refresh should replace the old result title")
    expect(!presentation.isReady, "refresh must not reuse an old ready result")
    expect(presentation.isBusy, "refresh should expose its busy state")
    expect(presentation.primaryAction == nil, "refresh should hide the primary action")
    expect(presentation.secondaryActions.isEmpty, "refresh should hide all secondary actions")
    expect(
        presentation.detail.contains("写入保持关闭"),
        "refresh should explicitly say that writing stays disabled"
    )
    expect(presentation.requirements.count == 8, "refresh should preserve the stable eight-row shape")
    expect(
        presentation.requirements.allSatisfy {
            $0.state == .checking
                && $0.statusText == "检查中"
                && !$0.title.isEmpty
                && !$0.detail.isEmpty
        },
        "refresh should replace every stale row with explicit checking text"
    )
}

func readOnlySetupGuideLeadsToRecheckAndReportsCompletion() {
    let incomplete = SetupPresenter.presentation(
        for: SetupAssessment(issues: [.macFUSEMissing]),
        isRefreshing: false
    )
    expect(
        ReadOnlySetupInteractionPresenter.primaryAction(
            for: incomplete,
            guideRequirementID: nil
        ) == .continueSetup,
        "an incomplete setup should initially lead to the next manual step"
    )
    expect(
        ReadOnlySetupInteractionPresenter.primaryAction(
            for: incomplete,
            guideRequirementID: .macFUSE
        ) == .recheck,
        "opening an actionable guide must change the primary action to recheck"
    )

    let checking = SetupPresenter.presentation(
        for: SetupAssessment(issues: [.macFUSEMissing]),
        isRefreshing: true
    )
    expect(
        ReadOnlySetupInteractionPresenter.primaryAction(
            for: checking,
            guideRequirementID: .macFUSE
        ) == nil,
        "an in-flight recheck must not retain an actionable primary button"
    )

    let ready = SetupPresenter.presentation(
        for: SetupChecker.assess(readySetupFacts()),
        isRefreshing: false
    )
    expect(
        ReadOnlySetupInteractionPresenter.completedRecheckStatus(for: ready)
            == "重新检查完成，运行环境已满足当前要求。",
        "a successful recheck should report a precise ready result"
    )
    expect(
        ReadOnlySetupInteractionPresenter.completedRecheckStatus(for: incomplete)
            == "重新检查完成，仍有 1 项需要处理。",
        "an incomplete recheck should report the remaining actionable count"
    )
}

func readOnlySetupFeedbackUsesStableVisibleAndAccessibleText() {
    let ready = SetupPresenter.presentation(
        for: SetupChecker.assess(readySetupFacts()),
        isRefreshing: false
    )
    let incomplete = SetupPresenter.presentation(
        for: SetupAssessment(issues: [.macFUSEMissing]),
        isRefreshing: false
    )

    let cases: [(ReadOnlyActionFeedback, String)] = [
        (
            ReadOnlySetupInteractionPresenter.guideFeedback(requirementID: .macFUSE),
            "已展开首个待处理项目。"
        ),
        (
            ReadOnlySetupInteractionPresenter.guideFeedback(requirementID: nil),
            "当前没有可继续的设置步骤，请重新检查。"
        ),
        (
            ReadOnlySetupInteractionPresenter.recheckStartedFeedback,
            "正在重新检查运行环境。"
        ),
        (
            ReadOnlySetupInteractionPresenter.completedRecheckFeedback(for: ready),
            "重新检查完成，运行环境已满足当前要求。"
        ),
        (
            ReadOnlySetupInteractionPresenter.completedRecheckFeedback(for: incomplete),
            "重新检查完成，仍有 1 项需要处理。"
        ),
    ]

    for (feedback, expectedText) in cases {
        expect(
            feedback.visibleText == expectedText,
            "Setup feedback must keep its stable visible result"
        )
        expect(
            feedback.accessibilityAnnouncement == expectedText,
            "Setup feedback must announce the same complete result"
        )
    }
}

func matchingReadOnlySystemEvidenceProducesAnUnknownHealthSnapshot() {
    let volume = ReadOnlyVolumeEvidence(
        bsdName: "disk9s1",
        volumeUUID: "11111111-2222-3333-4444-555555555555",
        physicalDiskBSDName: "disk9",
        displayName: "ARCHIVE",
        fileSystemName: "ntfs",
        isInternal: false,
        roleEvidence: .trustedData,
        diskArbitrationMountPoint: "/Volumes/ARCHIVE"
    )
    let mount = ReadOnlyMountEvidence(
        sourceBSDName: "disk9s1",
        mountPoint: "/Volumes/ARCHIVE",
        access: .readOnly,
        backend: .unknown,
        isComplete: true,
        isCanonical: true,
        isSymlink: false
    )

    let record = ReadOnlyVolumeMapper.map(
        volume,
        mount: mount,
        mediaGeneration: MediaGeneration(rawValue: 7)
    )

    expect(record.isComplete, "matching read-only system facts should produce a complete record")
    expect(record.issues.isEmpty, "matching read-only system facts should have no issues")
    expect(record.candidate == nil, "trusted role evidence should not also produce a candidate")
    expect(
        record.snapshot == VolumeSnapshot(
            id: VolumeID(
                uuid: "11111111-2222-3333-4444-555555555555",
                bsdName: "disk9s1"
            ),
            physicalDiskID: PhysicalDiskID(rawValue: "disk9"),
            mediaGeneration: MediaGeneration(rawValue: 7),
            displayName: "ARCHIVE",
            fileSystem: .ntfs,
            location: .external,
            role: .data,
            health: .unknown,
            mountAccess: .readOnly
        ),
        "the observation layer must preserve identity and leave health unknown"
    )
}

func volumeNameAloneNeverClaimsBootCampIdentity() {
    let externalDescription = DiskArbitrationDescription(
        bsdName: "disk9s3",
        physicalDiskBSDName: "disk9",
        isWholeDisk: false,
        isInternal: false,
        isEjectable: true,
        isRemovable: true,
        mediaSize: 1_000,
        mediaUUID: nil,
        volumeUUID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        volumeName: "BOOTCAMP",
        fileSystemName: "ntfs",
        mountPoint: nil
    )
    guard let evidence = externalDescription.volumeEvidence else {
        fatalError("CHECK FAILED: a partition description should produce volume evidence")
    }
    expect(
        evidence.roleEvidence == .unknown,
        "an external NTFS volume name must not become trusted role evidence"
    )

    let record = ReadOnlyVolumeMapper.map(
        evidence,
        mount: nil,
        mediaGeneration: MediaGeneration(rawValue: 4)
    )
    expect(
        record.snapshot == nil && record.issues.contains(.unknownVolumeRole),
        "an external NTFS volume with no trusted role source must remain incomplete"
    )

    let observation = DiskInventoryObservation(
        physicalDisks: [
            ReadOnlyPhysicalDiskRecord(
                instanceID: DiskInstanceID(
                    physicalDiskID: PhysicalDiskID(rawValue: "disk9"),
                    mediaGeneration: MediaGeneration(rawValue: 4)
                ),
                description: DiskArbitrationDescription(
                    bsdName: "disk9",
                    physicalDiskBSDName: "disk9",
                    isWholeDisk: true,
                    isInternal: false,
                    isEjectable: true,
                    isRemovable: true,
                    mediaSize: 2_000,
                    mediaUUID: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff",
                    volumeUUID: nil,
                    volumeName: nil,
                    fileSystemName: nil,
                    mountPoint: nil
                ),
                volumes: [record],
                issues: []
            ),
        ],
        issues: []
    )
    expect(
        observation.coordinatorInventory == nil,
        "an external unknown role must not project write or whole-disk eject inventory"
    )

    let internalDescription = DiskArbitrationDescription(
        bsdName: "disk1s3",
        physicalDiskBSDName: "disk1",
        isWholeDisk: false,
        isInternal: true,
        isEjectable: false,
        isRemovable: false,
        mediaSize: 1_000,
        mediaUUID: nil,
        volumeUUID: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff",
        volumeName: "WINDOWS",
        fileSystemName: "ntfs",
        mountPoint: nil
    )
    guard let internalEvidence = internalDescription.volumeEvidence else {
        fatalError("CHECK FAILED: an internal partition should produce volume evidence")
    }
    expect(
        internalEvidence.roleEvidence == .protected,
        "trusted internal location should map to generic protection without claiming Boot Camp"
    )
    let internalRecord = ReadOnlyVolumeMapper.map(
        internalEvidence,
        mount: nil,
        mediaGeneration: MediaGeneration(rawValue: 5)
    )
    expect(
        internalRecord.snapshot?.role == .protected,
        "an internal volume must preserve a generic protected role"
    )
}

func unknownExternalNTFSIsVisibleOnlyAsAReadOnlyCandidate() {
    let evidence = ReadOnlyVolumeEvidence(
        bsdName: "disk73s1",
        volumeUUID: "73000000-0000-0000-0000-000000000001",
        physicalDiskBSDName: "disk73",
        displayName: "TRANSFER",
        fileSystemName: "ntfs",
        isInternal: false,
        roleEvidence: .unknown,
        diskArbitrationMountPoint: "/Volumes/TRANSFER"
    )
    let record = ReadOnlyVolumeMapper.map(
        evidence,
        mount: ReadOnlyMountEvidence(
            sourceBSDName: "disk73s1",
            mountPoint: "/Volumes/TRANSFER",
            access: .readOnly,
            backend: .unknown,
            isComplete: true,
            isCanonical: true,
            isSymlink: false
        ),
        mediaGeneration: MediaGeneration(rawValue: 73)
    )

    guard let candidate = record.candidate else {
        fatalError("CHECK FAILED: fully verified non-role facts should produce a candidate")
    }
    expect(record.snapshot == nil, "an unknown role must not produce a mutation snapshot")
    expect(
        record.issues == [.unknownVolumeRole],
        "the candidate path must preserve its sole unknown-role issue"
    )
    expect(
        candidate.instanceID == VolumeInstanceID(
            volumeID: VolumeID(
                uuid: "73000000-0000-0000-0000-000000000001",
                bsdName: "disk73s1"
            ),
            diskInstanceID: DiskInstanceID(
                physicalDiskID: PhysicalDiskID(rawValue: "disk73"),
                mediaGeneration: MediaGeneration(rawValue: 73)
            )
        )
            && candidate.fileSystem == .ntfs
            && candidate.location == .external
            && candidate.mountAccess == .readOnly,
        "a candidate must preserve only verified current-instance display facts"
    )

    let observation = DiskInventoryObservation(
        physicalDisks: [
            ReadOnlyPhysicalDiskRecord(
                instanceID: candidate.diskInstanceID,
                description: DiskArbitrationDescription(
                    bsdName: "disk73",
                    physicalDiskBSDName: "disk73",
                    isWholeDisk: true,
                    isInternal: false,
                    isEjectable: true,
                    isRemovable: true,
                    mediaSize: 1_000,
                    mediaUUID: nil,
                    volumeUUID: nil,
                    volumeName: nil,
                    fileSystemName: nil,
                    mountPoint: nil
                ),
                volumes: [record],
                issues: []
            ),
        ],
        issues: []
    )
    expect(
        observation.coordinatorInventory == nil,
        "a display candidate must never enter coordinator mutation inventory"
    )

    let dashboard = ReadOnlyDashboardPresenter.presentation(
        for: observation,
        setupAssessment: SetupChecker.assess(readySetupFacts()),
        isSetupRefreshing: false
    )
    expect(
        dashboard.phase == .limited && dashboard.volumes.count == 1,
        "an unknown-role candidate should remain visible in a limited read-only dashboard"
    )
    expect(
        dashboard.volumes[0].id == candidate.instanceID
            && dashboard.volumes[0].title == "TRANSFER"
            && dashboard.volumes[0].accessText == "只读"
            && dashboard.volumes[0].detail.contains("用途未确认"),
        "the candidate presentation must explain its unconfirmed purpose in plain text"
    )
    expect(
        !dashboard.writeControlsAvailable,
        "candidate visibility must not enable any mutation control"
    )
}

func conflictingParentLocationRemovesAReadOnlyCandidate() async {
    let inventory = ReadOnlyDiskInventory(
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [])
        }
    )
    let wholeDisk = DiskArbitrationDescription(
        bsdName: "disk74",
        physicalDiskBSDName: "disk74",
        isWholeDisk: true,
        isInternal: true,
        isEjectable: false,
        isRemovable: false,
        mediaSize: 1_000,
        mediaUUID: nil,
        volumeUUID: nil,
        volumeName: nil,
        fileSystemName: nil,
        mountPoint: nil
    )
    let conflictingChild = DiskArbitrationDescription(
        bsdName: "disk74s1",
        physicalDiskBSDName: "disk74",
        isWholeDisk: false,
        isInternal: false,
        isEjectable: false,
        isRemovable: false,
        mediaSize: 900,
        mediaUUID: nil,
        volumeUUID: "74000000-0000-0000-0000-000000000001",
        volumeName: "CONFLICT",
        fileSystemName: "ntfs",
        mountPoint: nil
    )

    await inventory.handle(DiskArbitrationEvent(kind: .appeared, description: wholeDisk))
    await inventory.handle(
        DiskArbitrationEvent(kind: .appeared, description: conflictingChild)
    )
    _ = await inventory.verifyEnumerationCoverage(
        using: IOMediaEnumerationSnapshot(bsdNames: ["disk74", "disk74s1"])
    )
    let observation = await inventory.currentInventory()
    guard let disk = observation.physicalDisks.first,
          let record = disk.volumes.first
    else {
        fatalError("CHECK FAILED: the conflicting child should remain observable")
    }
    expect(
        disk.issues.contains(.childLocationMismatch(bsdName: "disk74s1")),
        "the parent/child location conflict must keep its fixed inventory issue"
    )
    expect(
        record.candidate == nil,
        "a child whose external location conflicts with its parent must not remain a candidate"
    )
}

func conflictingWholeDiskIdentityRemovesAReadOnlyCandidate() async {
    let inventory = ReadOnlyDiskInventory(
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [])
        }
    )
    let malformedWholeDisk = DiskArbitrationDescription(
        bsdName: "disk75",
        physicalDiskBSDName: "disk999",
        isWholeDisk: true,
        isInternal: false,
        isEjectable: true,
        isRemovable: true,
        mediaSize: 1_000,
        mediaUUID: nil,
        volumeUUID: nil,
        volumeName: nil,
        fileSystemName: nil,
        mountPoint: nil
    )
    let child = DiskArbitrationDescription(
        bsdName: "disk75s1",
        physicalDiskBSDName: "disk75",
        isWholeDisk: false,
        isInternal: false,
        isEjectable: true,
        isRemovable: true,
        mediaSize: 900,
        mediaUUID: nil,
        volumeUUID: "75000000-0000-0000-0000-000000000001",
        volumeName: "BAD PARENT",
        fileSystemName: "ntfs",
        mountPoint: nil
    )

    await inventory.handle(
        DiskArbitrationEvent(kind: .appeared, description: malformedWholeDisk)
    )
    await inventory.handle(DiskArbitrationEvent(kind: .appeared, description: child))
    _ = await inventory.verifyEnumerationCoverage(
        using: IOMediaEnumerationSnapshot(bsdNames: ["disk75", "disk75s1"])
    )
    let observation = await inventory.currentInventory()
    guard let disk = observation.physicalDisks.first,
          let record = disk.volumes.first
    else {
        fatalError("CHECK FAILED: malformed topology should stay observable")
    }
    expect(
        disk.issues.contains(.physicalParentMismatch(bsdName: "disk75")),
        "the malformed whole-disk identity must preserve its topology issue"
    )
    expect(
        record.candidate == nil,
        "a whole-disk identity conflict must suppress every child candidate"
    )
}

func unverifiedEnumerationCoverageDoesNotExposeAReadOnlyCandidate() async {
    let inventory = ReadOnlyDiskInventory(
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [])
        }
    )
    let wholeDisk = DiskArbitrationDescription(
        bsdName: "disk76",
        physicalDiskBSDName: "disk76",
        isWholeDisk: true,
        isInternal: false,
        isEjectable: true,
        isRemovable: true,
        mediaSize: 1_000,
        mediaUUID: nil,
        volumeUUID: nil,
        volumeName: nil,
        fileSystemName: nil,
        mountPoint: nil
    )
    let child = DiskArbitrationDescription(
        bsdName: "disk76s1",
        physicalDiskBSDName: "disk76",
        isWholeDisk: false,
        isInternal: false,
        isEjectable: true,
        isRemovable: true,
        mediaSize: 900,
        mediaUUID: nil,
        volumeUUID: "76000000-0000-0000-0000-000000000001",
        volumeName: "UNSETTLED",
        fileSystemName: "ntfs",
        mountPoint: nil
    )

    await inventory.handle(DiskArbitrationEvent(kind: .appeared, description: wholeDisk))
    await inventory.handle(DiskArbitrationEvent(kind: .appeared, description: child))
    await inventory.markEnumerationSettledWithoutCoverage()
    let observation = await inventory.currentInventory()
    guard let record = observation.physicalDisks.first?.volumes.first else {
        fatalError("CHECK FAILED: unverified coverage should preserve observable facts")
    }
    expect(
        observation.issues.contains(.enumerationCoverageUnverified),
        "quiet settlement without independent enumeration must remain unverified"
    )
    expect(
        record.candidate == nil,
        "an incomplete topology must not expose a read-only candidate"
    )
}

func unresolvedSiblingTopologyDoesNotExposeAReadOnlyCandidate() async {
    let inventory = ReadOnlyDiskInventory(
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [])
        }
    )
    let wholeDisk = DiskArbitrationDescription(
        bsdName: "disk78",
        physicalDiskBSDName: "disk78",
        isWholeDisk: true,
        isInternal: false,
        isEjectable: true,
        isRemovable: true,
        mediaSize: 1_000,
        mediaUUID: nil,
        volumeUUID: nil,
        volumeName: nil,
        fileSystemName: nil,
        mountPoint: nil
    )
    let child = DiskArbitrationDescription(
        bsdName: "disk78s1",
        physicalDiskBSDName: "disk78",
        isWholeDisk: false,
        isInternal: false,
        isEjectable: true,
        isRemovable: true,
        mediaSize: 900,
        mediaUUID: nil,
        volumeUUID: "78000000-0000-0000-0000-000000000001",
        volumeName: "KNOWN CHILD",
        fileSystemName: "ntfs",
        mountPoint: nil
    )
    let unresolvedSibling = DiskArbitrationDescription(
        bsdName: "disk78s2",
        physicalDiskBSDName: "disk78",
        isWholeDisk: nil,
        isInternal: false,
        isEjectable: true,
        isRemovable: true,
        mediaSize: 100,
        mediaUUID: nil,
        volumeUUID: nil,
        volumeName: nil,
        fileSystemName: nil,
        mountPoint: nil
    )

    await inventory.handle(DiskArbitrationEvent(kind: .appeared, description: wholeDisk))
    await inventory.handle(DiskArbitrationEvent(kind: .appeared, description: child))
    await inventory.handle(
        DiskArbitrationEvent(kind: .appeared, description: unresolvedSibling)
    )
    _ = await inventory.verifyEnumerationCoverage(
        using: IOMediaEnumerationSnapshot(
            bsdNames: ["disk78", "disk78s1", "disk78s2"]
        )
    )
    let observation = await inventory.currentInventory()
    guard let record = observation.physicalDisks.first?.volumes.first else {
        fatalError("CHECK FAILED: the verified child should remain observable")
    }
    expect(
        observation.issues.contains(.unknownDiskKind(bsdName: "disk78s2")),
        "an unresolved sibling kind must preserve its topology issue"
    )
    expect(
        record.candidate == nil,
        "an unresolved sibling topology must suppress every read-only candidate"
    )
}

func readOnlyCandidatesRejectEveryAdditionalFactProblem() {
    func evidence(
        volumeUUID: String? = "77000000-0000-0000-0000-000000000001",
        displayName: String? = "CHECKED",
        fileSystemName: String? = "ntfs",
        isInternal: Bool? = false,
        roleEvidence: VolumeRoleEvidence = .unknown,
        mountPoint: String? = nil
    ) -> ReadOnlyVolumeEvidence {
        ReadOnlyVolumeEvidence(
            bsdName: "disk77s1",
            volumeUUID: volumeUUID,
            physicalDiskBSDName: "disk77",
            displayName: displayName,
            fileSystemName: fileSystemName,
            isInternal: isInternal,
            roleEvidence: roleEvidence,
            diskArbitrationMountPoint: mountPoint
        )
    }

    let invalidEvidence: [(ReadOnlyVolumeEvidence, MediaGeneration)] = [
        (evidence(volumeUUID: "not-a-uuid"), MediaGeneration(rawValue: 77)),
        (evidence(displayName: nil), MediaGeneration(rawValue: 77)),
        (evidence(fileSystemName: nil), MediaGeneration(rawValue: 77)),
        (evidence(fileSystemName: "exfat"), MediaGeneration(rawValue: 77)),
        (evidence(isInternal: nil), MediaGeneration(rawValue: 77)),
        (evidence(isInternal: true), MediaGeneration(rawValue: 77)),
        (evidence(roleEvidence: .conflicting), MediaGeneration(rawValue: 77)),
        (evidence(), MediaGeneration(rawValue: 0)),
    ]
    for (invalid, generation) in invalidEvidence {
        expect(
            ReadOnlyVolumeMapper.map(
                invalid,
                mount: nil,
                mediaGeneration: generation
            ).candidate == nil,
            "identity, filesystem, location, role, and generation problems must suppress candidates"
        )
    }

    let mountProblems = [
        ReadOnlyMountEvidence(
            sourceBSDName: "disk78s1",
            mountPoint: "/Volumes/CHECKED",
            access: .readOnly,
            backend: .unknown,
            isComplete: true,
            isCanonical: true,
            isSymlink: false
        ),
        ReadOnlyMountEvidence(
            sourceBSDName: "disk77s1",
            mountPoint: "/Volumes/OTHER",
            access: .readOnly,
            backend: .unknown,
            isComplete: true,
            isCanonical: true,
            isSymlink: false
        ),
        ReadOnlyMountEvidence(
            sourceBSDName: "disk77s1",
            mountPoint: "/Volumes/CHECKED",
            access: .readOnly,
            backend: .unknown,
            isComplete: false,
            isCanonical: true,
            isSymlink: false
        ),
        ReadOnlyMountEvidence(
            sourceBSDName: "disk77s1",
            mountPoint: "/Volumes/CHECKED",
            access: .readOnly,
            backend: .unknown,
            isComplete: true,
            isCanonical: false,
            isSymlink: false
        ),
        ReadOnlyMountEvidence(
            sourceBSDName: "disk77s1",
            mountPoint: "/Volumes/CHECKED",
            access: .readOnly,
            backend: .unknown,
            isComplete: true,
            isCanonical: true,
            isSymlink: true
        ),
    ]
    for invalidMount in mountProblems {
        let record = ReadOnlyVolumeMapper.map(
            evidence(mountPoint: "/Volumes/CHECKED"),
            mount: invalidMount,
            mediaGeneration: MediaGeneration(rawValue: 77)
        )
        expect(
            record.candidate == nil,
            "incomplete, mismatched, noncanonical, or symbolic-link mount facts must suppress candidates"
        )
        expect(
            record.issues != [.unknownVolumeRole],
            "a rejected candidate must preserve the additional fixed mount issue"
        )
    }
}

func existingReadWriteMountRemainsUnverifiedForAReadOnlyCandidate() {
    let record = ReadOnlyVolumeMapper.map(
        ReadOnlyVolumeEvidence(
            bsdName: "disk78s1",
            volumeUUID: "78000000-0000-0000-0000-000000000001",
            physicalDiskBSDName: "disk78",
            displayName: "EXISTING WRITE",
            fileSystemName: "ntfs",
            isInternal: false,
            roleEvidence: .unknown,
            diskArbitrationMountPoint: "/Volumes/EXISTING WRITE"
        ),
        mount: ReadOnlyMountEvidence(
            sourceBSDName: "disk78s1",
            mountPoint: "/Volumes/EXISTING WRITE",
            access: .readWrite,
            backend: .kernelExtension,
            isComplete: true,
            isCanonical: true,
            isSymlink: false
        ),
        mediaGeneration: MediaGeneration(rawValue: 78)
    )
    guard let candidate = record.candidate else {
        fatalError("CHECK FAILED: a verified existing mount should remain displayable")
    }
    let observation = DiskInventoryObservation(
        physicalDisks: [
            ReadOnlyPhysicalDiskRecord(
                instanceID: candidate.diskInstanceID,
                description: DiskArbitrationDescription(
                    bsdName: "disk78",
                    physicalDiskBSDName: "disk78",
                    isWholeDisk: true,
                    isInternal: false,
                    isEjectable: true,
                    isRemovable: true,
                    mediaSize: 1_000,
                    mediaUUID: nil,
                    volumeUUID: nil,
                    volumeName: nil,
                    fileSystemName: nil,
                    mountPoint: nil
                ),
                volumes: [record],
                issues: []
            ),
        ],
        issues: []
    )
    let dashboard = ReadOnlyDashboardPresenter.presentation(
        for: observation,
        setupAssessment: SetupChecker.assess(readySetupFacts()),
        isSetupRefreshing: false
    )
    expect(
        dashboard.volumes.first?.accessText == "已有可写挂载",
        "an existing read-write mount must be reported as an observed fact"
    )
    expect(
        dashboard.volumes.first?.detail.contains("本应用未验证其来源或安全性") == true,
        "an existing read-write mount must never be presented as this app's verified success"
    )
    expect(
        observation.coordinatorInventory == nil && !dashboard.writeControlsAvailable,
        "an existing read-write candidate must retain zero mutation eligibility"
    )
}

func reinsertedCandidateDoesNotReuseTheOldSelection() {
    func dashboard(
        generation: UInt64,
        title: String
    ) -> (ReadOnlyDashboardPresentation, VolumeInstanceID) {
        let record = ReadOnlyVolumeMapper.map(
            ReadOnlyVolumeEvidence(
                bsdName: "disk79s1",
                volumeUUID: "79000000-0000-0000-0000-000000000001",
                physicalDiskBSDName: "disk79",
                displayName: title,
                fileSystemName: "ntfs",
                isInternal: false,
                roleEvidence: .unknown,
                diskArbitrationMountPoint: nil
            ),
            mount: nil,
            mediaGeneration: MediaGeneration(rawValue: generation)
        )
        guard let candidate = record.candidate else {
            fatalError("CHECK FAILED: candidate fixture should map")
        }
        let observation = DiskInventoryObservation(
            physicalDisks: [
                ReadOnlyPhysicalDiskRecord(
                    instanceID: candidate.diskInstanceID,
                    description: DiskArbitrationDescription(
                        bsdName: "disk79",
                        physicalDiskBSDName: "disk79",
                        isWholeDisk: true,
                        isInternal: false,
                        isEjectable: true,
                        isRemovable: true,
                        mediaSize: 1_000,
                        mediaUUID: nil,
                        volumeUUID: nil,
                        volumeName: nil,
                        fileSystemName: nil,
                        mountPoint: nil
                    ),
                    volumes: [record],
                    issues: []
                ),
            ],
            issues: []
        )
        return (
            ReadOnlyDashboardPresenter.presentation(
                for: observation,
                setupAssessment: SetupChecker.assess(readySetupFacts()),
                isSetupRefreshing: false
            ),
            candidate.instanceID
        )
    }

    let old = dashboard(generation: 79, title: "OLD CANDIDATE")
    let reinserted = dashboard(generation: 80, title: "NEW CANDIDATE")
    expect(old.1 != reinserted.1, "reinsertion must produce a different candidate instance")
    let oldSelection = ReadOnlyDashboardSelection.volume(old.1)
    expect(
        ReadOnlySelectionPresenter.reconciledSelection(
            oldSelection,
            for: reinserted.0
        ) == .overview,
        "a stable replacement projection must reset the old candidate selection"
    )
    expect(
        ReadOnlySelectionPresenter.detail(
            for: oldSelection,
            in: reinserted.0
        ) == .overview,
        "an old candidate selection must never resolve the reinserted candidate's content"
    )
}

func confirmedCurrentDataVolumeDeclarationProducesOnlyARequestApproval() async {
    let diskInstanceID = DiskInstanceID(
        physicalDiskID: PhysicalDiskID(rawValue: "disk81"),
        mediaGeneration: MediaGeneration(rawValue: 81)
    )
    let candidate = ReadOnlyVolumeCandidate(
        id: VolumeID(
            uuid: "81000000-0000-0000-0000-000000000001",
            bsdName: "disk81s1"
        ),
        physicalDiskID: diskInstanceID.physicalDiskID,
        mediaGeneration: diskInstanceID.mediaGeneration,
        displayName: "PERSONAL DATA",
        fileSystem: .ntfs,
        location: .external,
        mountAccess: .readOnly
    )
    let sibling = SiblingVolumeRoleFact(
        instanceID: VolumeInstanceID(
            volumeID: VolumeID(
                uuid: "81000000-0000-0000-0000-000000000002",
                bsdName: "disk81s2"
            ),
            diskInstanceID: diskInstanceID
        ),
        location: .external,
        roleEvidence: .unknown
    )
    let resolver = DataVolumeDeclarationResolver()
    let request = await resolver.beginRequest(
        observing: DataVolumeRoleObservation(
            candidate: candidate,
            siblingFacts: [sibling],
            isComplete: true
        )
    )
    expect(
        request.target == candidate.instanceID
            && request.diskInstanceID == diskInstanceID
            && request.siblingInstanceIDs == [sibling.instanceID],
        "a declaration request must bind the complete current target and sibling topology"
    )

    let declaration = request.confirmSelectedVolumeIsDataAndNotWindowsBootOrSystemVolume()
    expect(
        declaration.meaning
            == .selectedVolumeIsDataAndNotWindowsBootOrSystemVolume,
        "the declaration must expose only the fixed data-not-Windows-system meaning"
    )
    let resolution = await resolver.resolve(declaration)
    guard case let .approved(approval) = resolution else {
        fatalError("CHECK FAILED: the current confirmed safe declaration should be approved")
    }
    expect(
        approval.target == candidate.instanceID
            && approval.diskInstanceID == diskInstanceID
            && approval.siblingInstanceIDs == [sibling.instanceID]
            && approval.sessionID == request.sessionID
            && approval.observationRevision == request.observationRevision
            && approval.requestNonce == request.requestNonce,
        "an approval must prove only the exact current one-shot role-policy request"
    )
}

func dataVolumeDeclarationRequestCannotBeConsumedTwice() async {
    let candidate = ReadOnlyVolumeCandidate(
        id: VolumeID(
            uuid: "82000000-0000-0000-0000-000000000001",
            bsdName: "disk82s1"
        ),
        physicalDiskID: PhysicalDiskID(rawValue: "disk82"),
        mediaGeneration: MediaGeneration(rawValue: 82),
        displayName: "ONE SHOT",
        fileSystem: .ntfs,
        location: .external,
        mountAccess: .unmounted
    )
    let resolver = DataVolumeDeclarationResolver()
    let request = await resolver.beginRequest(
        observing: DataVolumeRoleObservation(
            candidate: candidate,
            siblingFacts: [],
            isComplete: true
        )
    )
    let declaration = request.confirmSelectedVolumeIsDataAndNotWindowsBootOrSystemVolume()
    guard case .approved = await resolver.resolve(declaration) else {
        fatalError("CHECK FAILED: the first current declaration consumption should pass")
    }
    let replay = await resolver.resolve(declaration)
    expect(
        replay == .rejected(.requestAlreadyConsumed),
        "a declaration request nonce must be consumed at most once"
    )
}

func dataVolumeDeclarationDoesNotCrossSessionRotationOrApplicationRestart() async {
    let candidate = ReadOnlyVolumeCandidate(
        id: VolumeID(
            uuid: "83000000-0000-0000-0000-000000000001",
            bsdName: "disk83s1"
        ),
        physicalDiskID: PhysicalDiskID(rawValue: "disk83"),
        mediaGeneration: MediaGeneration(rawValue: 83),
        displayName: "SESSION DATA",
        fileSystem: .ntfs,
        location: .external,
        mountAccess: .readOnly
    )
    let observation = DataVolumeRoleObservation(
        candidate: candidate,
        siblingFacts: [],
        isComplete: true
    )
    let resolver = DataVolumeDeclarationResolver()
    let request = await resolver.beginRequest(observing: observation)
    let declaration = request.confirmSelectedVolumeIsDataAndNotWindowsBootOrSystemVolume()

    await resolver.rotateSession()
    let afterResubscribe = await resolver.resolve(declaration)
    expect(
        afterResubscribe == .rejected(.sessionChanged),
        "wake or resubscribe must invalidate every declaration from the prior session"
    )

    let restartedResolver = DataVolumeDeclarationResolver()
    _ = await restartedResolver.beginRequest(observing: observation)
    let afterRestart = await restartedResolver.resolve(declaration)
    expect(
        afterRestart == .rejected(.sessionChanged),
        "a new application resolver must not accept a declaration from the old session"
    )
}

func dataVolumeDeclarationRequiresTheCurrentObservationRevision() async {
    let candidate = ReadOnlyVolumeCandidate(
        id: VolumeID(
            uuid: "84000000-0000-0000-0000-000000000001",
            bsdName: "disk84s1"
        ),
        physicalDiskID: PhysicalDiskID(rawValue: "disk84"),
        mediaGeneration: MediaGeneration(rawValue: 84),
        displayName: "REVISION DATA",
        fileSystem: .ntfs,
        location: .external,
        mountAccess: .readOnly
    )
    let observation = DataVolumeRoleObservation(
        candidate: candidate,
        siblingFacts: [],
        isComplete: true
    )
    let resolver = DataVolumeDeclarationResolver()
    let oldRequest = await resolver.beginRequest(observing: observation)
    let oldDeclaration = oldRequest
        .confirmSelectedVolumeIsDataAndNotWindowsBootOrSystemVolume()
    let currentRequest = await resolver.beginRequest(observing: observation)
    expect(
        currentRequest.observationRevision != oldRequest.observationRevision,
        "each fresh observation must receive a distinct revision"
    )

    let staleResolution = await resolver.resolve(oldDeclaration)
    expect(
        staleResolution == .rejected(.staleObservation),
        "an otherwise identical declaration from an older observation must be rejected"
    )
}

func dataVolumeDeclarationRejectsInstanceAndSiblingTopologyDrift() async {
    func candidate(
        diskName: String,
        generation: UInt64,
        bsdName: String,
        uuid: String = "85000000-0000-0000-0000-000000000001"
    ) -> ReadOnlyVolumeCandidate {
        ReadOnlyVolumeCandidate(
            id: VolumeID(uuid: uuid, bsdName: bsdName),
            physicalDiskID: PhysicalDiskID(rawValue: diskName),
            mediaGeneration: MediaGeneration(rawValue: generation),
            displayName: "BOUND DATA",
            fileSystem: .ntfs,
            location: .external,
            mountAccess: .readOnly
        )
    }

    let inserted = candidate(
        diskName: "disk85",
        generation: 85,
        bsdName: "disk85s1"
    )
    let reinsertResolver = DataVolumeDeclarationResolver()
    let insertedRequest = await reinsertResolver.beginRequest(
        observing: DataVolumeRoleObservation(
            candidate: inserted,
            siblingFacts: [],
            isComplete: true
        )
    )
    let insertedDeclaration = insertedRequest
        .confirmSelectedVolumeIsDataAndNotWindowsBootOrSystemVolume()
    _ = await reinsertResolver.beginRequest(
        observing: DataVolumeRoleObservation(
            candidate: candidate(
                diskName: "disk85",
                generation: 86,
                bsdName: "disk85s1"
            ),
            siblingFacts: [],
            isComplete: true
        )
    )
    let afterReinsert = await reinsertResolver.resolve(insertedDeclaration)
    expect(
        afterReinsert == .rejected(.targetChanged),
        "a declaration must not survive a changed media generation"
    )

    let cloneResolver = DataVolumeDeclarationResolver()
    let originalRequest = await cloneResolver.beginRequest(
        observing: DataVolumeRoleObservation(
            candidate: inserted,
            siblingFacts: [],
            isComplete: true
        )
    )
    let originalDeclaration = originalRequest
        .confirmSelectedVolumeIsDataAndNotWindowsBootOrSystemVolume()
    _ = await cloneResolver.beginRequest(
        observing: DataVolumeRoleObservation(
            candidate: candidate(
                diskName: "disk185",
                generation: 185,
                bsdName: "disk185s1"
            ),
            siblingFacts: [],
            isComplete: true
        )
    )
    let clonedUUID = await cloneResolver.resolve(originalDeclaration)
    expect(
        clonedUUID == .rejected(.targetChanged),
        "a cloned UUID on a different volume and disk instance must not reuse a declaration"
    )

    let topologyResolver = DataVolumeDeclarationResolver()
    let diskInstanceID = inserted.diskInstanceID
    let firstSibling = SiblingVolumeRoleFact(
        instanceID: VolumeInstanceID(
            volumeID: VolumeID(
                uuid: "85000000-0000-0000-0000-000000000002",
                bsdName: "disk85s2"
            ),
            diskInstanceID: diskInstanceID
        ),
        location: .external,
        roleEvidence: .unknown
    )
    let topologyRequest = await topologyResolver.beginRequest(
        observing: DataVolumeRoleObservation(
            candidate: inserted,
            siblingFacts: [firstSibling],
            isComplete: true
        )
    )
    let topologyDeclaration = topologyRequest
        .confirmSelectedVolumeIsDataAndNotWindowsBootOrSystemVolume()
    let secondSibling = SiblingVolumeRoleFact(
        instanceID: VolumeInstanceID(
            volumeID: VolumeID(
                uuid: "85000000-0000-0000-0000-000000000003",
                bsdName: "disk85s3"
            ),
            diskInstanceID: diskInstanceID
        ),
        location: .external,
        roleEvidence: .trustedData
    )
    _ = await topologyResolver.beginRequest(
        observing: DataVolumeRoleObservation(
            candidate: inserted,
            siblingFacts: [firstSibling, secondSibling],
            isComplete: true
        )
    )
    let changedTopology = await topologyResolver.resolve(topologyDeclaration)
    expect(
        changedTopology == .rejected(.siblingTopologyChanged),
        "a declaration must bind the exact current sibling identity set"
    )
}

func incompleteDataVolumeRoleObservationCannotApproveADeclaration() async {
    let candidate = ReadOnlyVolumeCandidate(
        id: VolumeID(
            uuid: "86000000-0000-0000-0000-000000000001",
            bsdName: "disk86s1"
        ),
        physicalDiskID: PhysicalDiskID(rawValue: "disk86"),
        mediaGeneration: MediaGeneration(rawValue: 86),
        displayName: "INCOMPLETE DATA",
        fileSystem: .ntfs,
        location: .external,
        mountAccess: .readOnly
    )
    let resolver = DataVolumeDeclarationResolver()
    let request = await resolver.beginRequest(
        observing: DataVolumeRoleObservation(
            candidate: candidate,
            siblingFacts: [],
            isComplete: false
        )
    )
    let declaration = request.confirmSelectedVolumeIsDataAndNotWindowsBootOrSystemVolume()
    let resolution = await resolver.resolve(declaration)
    expect(
        resolution == .rejected(.observationIncomplete),
        "human confirmation must never override incomplete sibling role or topology facts"
    )
}

func dataVolumeDeclarationCannotOverrideCandidateEligibility() async {
    let invalidCandidates = [
        ReadOnlyVolumeCandidate(
            id: VolumeID(
                uuid: "87000000-0000-0000-0000-000000000001",
                bsdName: "disk87s1"
            ),
            physicalDiskID: PhysicalDiskID(rawValue: "disk87"),
            mediaGeneration: MediaGeneration(rawValue: 87),
            displayName: "INTERNAL",
            fileSystem: .ntfs,
            location: .internal,
            mountAccess: .readOnly
        ),
        ReadOnlyVolumeCandidate(
            id: VolumeID(
                uuid: "88000000-0000-0000-0000-000000000001",
                bsdName: "disk88s1"
            ),
            physicalDiskID: PhysicalDiskID(rawValue: "disk88"),
            mediaGeneration: MediaGeneration(rawValue: 88),
            displayName: "NOT NTFS",
            fileSystem: .other,
            location: .external,
            mountAccess: .readOnly
        ),
    ]

    for candidate in invalidCandidates {
        let resolver = DataVolumeDeclarationResolver()
        let request = await resolver.beginRequest(
            observing: DataVolumeRoleObservation(
                candidate: candidate,
                siblingFacts: [],
                isComplete: true
            )
        )
        let declaration = request
            .confirmSelectedVolumeIsDataAndNotWindowsBootOrSystemVolume()
        let resolution = await resolver.resolve(declaration)
        expect(
            resolution == .rejected(.candidateNotEligible),
            "human confirmation must not override external-NTFS candidate eligibility"
        )
    }
}

func protectedOrConflictingSiblingFactsOverrideDataVolumeDeclaration() async {
    let diskInstanceID = DiskInstanceID(
        physicalDiskID: PhysicalDiskID(rawValue: "disk89"),
        mediaGeneration: MediaGeneration(rawValue: 89)
    )
    let candidate = ReadOnlyVolumeCandidate(
        id: VolumeID(
            uuid: "89000000-0000-0000-0000-000000000001",
            bsdName: "disk89s1"
        ),
        physicalDiskID: diskInstanceID.physicalDiskID,
        mediaGeneration: diskInstanceID.mediaGeneration,
        displayName: "SELECTED DATA",
        fileSystem: .ntfs,
        location: .external,
        mountAccess: .readOnly
    )
    func sibling(
        suffix: Int,
        location: VolumeLocation,
        roleEvidence: VolumeRoleEvidence
    ) -> SiblingVolumeRoleFact {
        SiblingVolumeRoleFact(
            instanceID: VolumeInstanceID(
                volumeID: VolumeID(
                    uuid: "89000000-0000-0000-0000-00000000000\(suffix)",
                    bsdName: "disk89s\(suffix)"
                ),
                diskInstanceID: diskInstanceID
            ),
            location: location,
            roleEvidence: roleEvidence
        )
    }
    let blockedFacts: [(SiblingVolumeRoleFact, DataVolumeDeclarationRejection)] = [
        (sibling(suffix: 2, location: .external, roleEvidence: .protected), .protectedSibling),
        (sibling(suffix: 3, location: .internal, roleEvidence: .unknown), .protectedSibling),
        (
            sibling(suffix: 4, location: .external, roleEvidence: .conflicting),
            .conflictingSiblingEvidence
        ),
    ]

    for (blockedSibling, expectedRejection) in blockedFacts {
        let resolver = DataVolumeDeclarationResolver()
        let request = await resolver.beginRequest(
            observing: DataVolumeRoleObservation(
                candidate: candidate,
                siblingFacts: [blockedSibling],
                isComplete: true
            )
        )
        let declaration = request
            .confirmSelectedVolumeIsDataAndNotWindowsBootOrSystemVolume()
        let resolution = await resolver.resolve(declaration)
        expect(
            resolution == .rejected(expectedRejection),
            "internal, protected, or conflicting sibling facts must override a declaration"
        )
    }
}

func invalidSiblingTopologyCannotApproveADataVolumeDeclaration() async {
    let diskInstanceID = DiskInstanceID(
        physicalDiskID: PhysicalDiskID(rawValue: "disk90"),
        mediaGeneration: MediaGeneration(rawValue: 90)
    )
    let candidate = ReadOnlyVolumeCandidate(
        id: VolumeID(
            uuid: "90000000-0000-0000-0000-000000000001",
            bsdName: "disk90s1"
        ),
        physicalDiskID: diskInstanceID.physicalDiskID,
        mediaGeneration: diskInstanceID.mediaGeneration,
        displayName: "TOPOLOGY DATA",
        fileSystem: .ntfs,
        location: .external,
        mountAccess: .readOnly
    )
    let validSibling = SiblingVolumeRoleFact(
        instanceID: VolumeInstanceID(
            volumeID: VolumeID(
                uuid: "90000000-0000-0000-0000-000000000002",
                bsdName: "disk90s2"
            ),
            diskInstanceID: diskInstanceID
        ),
        location: .external,
        roleEvidence: .unknown
    )
    let wrongDiskSibling = SiblingVolumeRoleFact(
        instanceID: VolumeInstanceID(
            volumeID: VolumeID(
                uuid: "90000000-0000-0000-0000-000000000003",
                bsdName: "disk190s1"
            ),
            diskInstanceID: DiskInstanceID(
                physicalDiskID: PhysicalDiskID(rawValue: "disk190"),
                mediaGeneration: MediaGeneration(rawValue: 190)
            )
        ),
        location: .external,
        roleEvidence: .unknown
    )
    let targetAsSibling = SiblingVolumeRoleFact(
        instanceID: candidate.instanceID,
        location: .external,
        roleEvidence: .unknown
    )
    let invalidSiblingSets = [
        [wrongDiskSibling],
        [validSibling, validSibling],
        [targetAsSibling],
    ]

    for siblingFacts in invalidSiblingSets {
        let resolver = DataVolumeDeclarationResolver()
        let request = await resolver.beginRequest(
            observing: DataVolumeRoleObservation(
                candidate: candidate,
                siblingFacts: siblingFacts,
                isComplete: true
            )
        )
        let declaration = request
            .confirmSelectedVolumeIsDataAndNotWindowsBootOrSystemVolume()
        let resolution = await resolver.resolve(declaration)
        expect(
            resolution == .rejected(.invalidSiblingTopology),
            "sibling facts must be unique, same-instance, and exclude the selected target"
        )
    }
}

func externalWindowsSystemCandidateRemainsUnknownWithoutConfirmation() async {
    let candidate = ReadOnlyVolumeCandidate(
        id: VolumeID(
            uuid: "91000000-0000-0000-0000-000000000001",
            bsdName: "disk91s1"
        ),
        physicalDiskID: PhysicalDiskID(rawValue: "disk91"),
        mediaGeneration: MediaGeneration(rawValue: 91),
        displayName: "WINDOWS SYSTEM",
        fileSystem: .ntfs,
        location: .external,
        mountAccess: .readOnly
    )
    let resolver = DataVolumeDeclarationResolver()
    _ = await resolver.beginRequest(
        observing: DataVolumeRoleObservation(
            candidate: candidate,
            siblingFacts: [],
            isComplete: true
        )
    )
    let resolution = await resolver.resolve(nil)
    expect(
        resolution == .rejected(.confirmationRequired),
        "an external Windows system candidate must remain unknown without confirmation"
    )
}

func trustedProtectedAndDataRolesMapWhileUnknownOrConflictingRolesFailClosed() {
    func evidence(
        roleEvidence: VolumeRoleEvidence,
        isInternal: Bool
    ) -> ReadOnlyVolumeEvidence {
        ReadOnlyVolumeEvidence(
            bsdName: "disk9s1",
            volumeUUID: "11111111-2222-3333-4444-555555555555",
            physicalDiskBSDName: "disk9",
            displayName: "ARCHIVE",
            fileSystemName: "ntfs",
            isInternal: isInternal,
            roleEvidence: roleEvidence,
            diskArbitrationMountPoint: nil
        )
    }

    let data = ReadOnlyVolumeMapper.map(
        evidence(roleEvidence: .trustedData, isInternal: false),
        mount: nil,
        mediaGeneration: MediaGeneration(rawValue: 4)
    )
    expect(
        data.snapshot?.role == .data && data.isComplete,
        "explicit trusted data evidence should map to a complete data snapshot"
    )

    let protected = ReadOnlyVolumeMapper.map(
        evidence(roleEvidence: .protected, isInternal: true),
        mount: nil,
        mediaGeneration: MediaGeneration(rawValue: 4)
    )
    guard let protectedSnapshot = protected.snapshot else {
        fatalError("CHECK FAILED: trusted internal protection should preserve a snapshot")
    }
    expect(
        protectedSnapshot.role == .protected,
        "trusted protection must not be mislabeled as data or exact Boot Camp identity"
    )
    expect(
        VolumeWorkflow(snapshot: protectedSnapshot).state == .writeBlocked(.protectedVolume),
        "an internal protected NTFS volume must never become write eligible"
    )

    let unknown = ReadOnlyVolumeMapper.map(
        evidence(roleEvidence: .unknown, isInternal: false),
        mount: nil,
        mediaGeneration: MediaGeneration(rawValue: 4)
    )
    expect(
        unknown.snapshot == nil && unknown.issues.contains(.unknownVolumeRole),
        "unknown role evidence must fail closed before a snapshot reaches a coordinator"
    )

    let conflicting = ReadOnlyVolumeMapper.map(
        evidence(roleEvidence: .conflicting, isInternal: false),
        mount: nil,
        mediaGeneration: MediaGeneration(rawValue: 4)
    )
    expect(
        conflicting.snapshot == nil && conflicting.issues.contains(.conflictingVolumeRole),
        "conflicting role evidence must fail closed before a snapshot reaches a coordinator"
    )
}

func contradictoryMountedEvidenceFailsClosed() {
    let volume = ReadOnlyVolumeEvidence(
        bsdName: "disk9s1",
        volumeUUID: "11111111-2222-3333-4444-555555555555",
        physicalDiskBSDName: "disk9",
        displayName: "ARCHIVE",
        fileSystemName: "ntfs",
        isInternal: false,
        roleEvidence: .trustedData,
        diskArbitrationMountPoint: "/Volumes/ARCHIVE"
    )
    let contradictoryMount = ReadOnlyMountEvidence(
        sourceBSDName: "disk9s1",
        mountPoint: "/Volumes/ARCHIVE",
        access: .unmounted,
        backend: .unknown,
        isComplete: true,
        isCanonical: true,
        isSymlink: false
    )

    let record = ReadOnlyVolumeMapper.map(
        volume,
        mount: contradictoryMount,
        mediaGeneration: MediaGeneration(rawValue: 7)
    )

    expect(!record.isComplete, "contradictory mount facts must make the record incomplete")
    expect(record.snapshot == nil, "contradictory mount facts must not fabricate a snapshot")
    expect(
        record.issues.contains(.mountAccessMismatch),
        "mounted paths reported as unmounted must expose the specific mismatch"
    )
}

func malformedReadOnlyIdentitiesNeverProduceTrustedSnapshots() {
    let fixtures: [(ReadOnlyVolumeEvidence, MediaGeneration, ReadOnlyObservationIssue)] = [
        (
            ReadOnlyVolumeEvidence(
                bsdName: "../disk9s1",
                volumeUUID: "11111111-2222-3333-4444-555555555555",
                physicalDiskBSDName: "disk9",
                displayName: "INVALID",
                fileSystemName: "ntfs",
                isInternal: false,
                roleEvidence: .trustedData,
                diskArbitrationMountPoint: nil
            ),
            MediaGeneration(rawValue: 7),
            .invalidBSDName
        ),
        (
            ReadOnlyVolumeEvidence(
                bsdName: "disk9s1",
                volumeUUID: "not-a-volume-uuid",
                physicalDiskBSDName: "disk9",
                displayName: "INVALID",
                fileSystemName: "ntfs",
                isInternal: false,
                roleEvidence: .trustedData,
                diskArbitrationMountPoint: nil
            ),
            MediaGeneration(rawValue: 7),
            .invalidVolumeUUID
        ),
        (
            ReadOnlyVolumeEvidence(
                bsdName: "disk9s1",
                volumeUUID: "11111111-2222-3333-4444-555555555555",
                physicalDiskBSDName: "disk9s1",
                displayName: "INVALID",
                fileSystemName: "ntfs",
                isInternal: false,
                roleEvidence: .trustedData,
                diskArbitrationMountPoint: nil
            ),
            MediaGeneration(rawValue: 7),
            .invalidPhysicalDiskBSDName
        ),
        (
            ReadOnlyVolumeEvidence(
                bsdName: "disk9s1",
                volumeUUID: "11111111-2222-3333-4444-555555555555",
                physicalDiskBSDName: "disk9",
                displayName: "INVALID",
                fileSystemName: "ntfs",
                isInternal: false,
                roleEvidence: .trustedData,
                diskArbitrationMountPoint: nil
            ),
            MediaGeneration(rawValue: 0),
            .invalidMediaGeneration
        ),
    ]

    for (evidence, generation, expectedIssue) in fixtures {
        let record = ReadOnlyVolumeMapper.map(
            evidence,
            mount: nil,
            mediaGeneration: generation
        )
        expect(!record.isComplete, "malformed identities must make observation incomplete")
        expect(record.snapshot == nil, "malformed identities must never produce a snapshot")
        expect(
            record.issues.contains(expectedIssue),
            "each malformed identity should expose its fixed failure category"
        )
    }
}

func mountSourceParserAcceptsOnlyCanonicalLocalDiskDevices() {
    expect(
        MountSourceParser.bsdName(from: "/dev/disk9s1") == "disk9s1",
        "a canonical local disk source should expose its BSD name"
    )
    expect(
        MountSourceParser.bsdName(from: "/dev/rdisk9s1") == nil,
        "raw devices must not be accepted as mounted volume sources"
    )
    expect(
        MountSourceParser.bsdName(from: "/tmp/dev/disk9s1") == nil,
        "a path that merely contains a device-looking suffix must be rejected"
    )
    expect(
        MountSourceParser.bsdName(from: "server:/archive") == nil,
        "network mount sources must not be treated as local disks"
    )
}

func liveMountTableReaderProducesReadOnlyFacts() {
    let table: SystemMountTableSnapshot
    do {
        table = try SystemMountTableReader().currentSnapshot()
    } catch {
        fatalError("CHECK FAILED: live mount table should be readable: \(error)")
    }

    expect(!table.records.isEmpty, "the running system should expose at least its root mount")
    expect(
        table.records.contains { $0.mountPoint == "/" },
        "the read-only snapshot should include the root mount"
    )
    expect(
        table.records.allSatisfy {
            !$0.sourcePath.isEmpty
                && !$0.mountPoint.isEmpty
                && !$0.fileSystemName.isEmpty
                && $0.access != .unmounted
        },
        "every copied mount record should preserve source, target, filesystem, and access"
    )
}

func mountTableReaderRequiresTwoConsecutiveStableSnapshots() {
    func record(_ source: String, _ mountPoint: String) -> SystemMountRecord {
        SystemMountRecord(
            sourcePath: source,
            sourceBSDName: MountSourceParser.bsdName(from: source),
            mountPoint: mountPoint,
            fileSystemName: "ntfs",
            access: .readOnly,
            backend: .unknown,
            isCanonical: true,
            isSymlink: false
        )
    }

    let first = SystemMountTableSnapshot(
        records: [record("/dev/disk71s1", "/Volumes/FIRST")]
    )
    let replacement = SystemMountTableSnapshot(
        records: [record("/dev/disk72s1", "/Volumes/SECOND")]
    )
    let settlingSource = LockedMountTableSnapshotSource([
        .success(first),
        .success(replacement),
        .success(replacement),
    ])
    let settlingReader = SystemMountTableReader(maximumSamples: 3) {
        try settlingSource.next()
    }
    do {
        let settledSnapshot = try settlingReader.currentSnapshot()
        expect(
            settledSnapshot == replacement,
            "a same-count mount replacement must settle twice before becoming trusted"
        )
    } catch {
        fatalError("CHECK FAILED: a stable replacement should settle: \(error)")
    }

    let changingSource = LockedMountTableSnapshotSource([
        .success(first),
        .success(replacement),
        .success(first),
        .success(replacement),
    ])
    let changingReader = SystemMountTableReader(maximumSamples: 4) {
        try changingSource.next()
    }
    do {
        _ = try changingReader.currentSnapshot()
        fatalError("CHECK FAILED: an unstable mount table must fail closed")
    } catch let error as SystemMountTableReadError {
        expect(
            error == .changedDuringRead,
            "an unstable mount table should retain its fixed failure reason"
        )
    } catch {
        fatalError("CHECK FAILED: unexpected mount table failure: \(error)")
    }

    let truncatedThenStableSource = LockedMountTableSnapshotSource([
        .failure(.changedDuringRead),
        .success(replacement),
        .success(replacement),
    ])
    let truncatedThenStableReader = SystemMountTableReader(maximumSamples: 3) {
        try truncatedThenStableSource.next()
    }
    do {
        let settledSnapshot = try truncatedThenStableReader.currentSnapshot()
        expect(
            settledSnapshot == replacement,
            "a truncated sample must be discarded before two stable samples are accepted"
        )
    } catch {
        fatalError("CHECK FAILED: stable samples after truncation should settle: \(error)")
    }
}

func firstLocalDiskArbitrationEvent(
    from stream: AsyncStream<DiskArbitrationEvent>
) async -> DiskArbitrationEvent? {
    await withTaskGroup(of: DiskArbitrationEvent?.self) { group in
        group.addTask {
            for await event in stream {
                if event.description.bsdName?.isEmpty == false,
                   event.description.physicalDiskBSDName?.isEmpty == false
                {
                    return event
                }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(2))
            return nil
        }

        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

func liveDiskArbitrationStreamProducesReadOnlyDescriptions() async {
    let stream: AsyncStream<DiskArbitrationEvent>
    do {
        stream = try DiskArbitrationEventSource().events()
    } catch {
        fatalError("CHECK FAILED: Disk Arbitration read-only session should start: \(error)")
    }

    guard let event = await firstLocalDiskArbitrationEvent(from: stream) else {
        fatalError("CHECK FAILED: Disk Arbitration should report an existing disk within two seconds")
    }
    expect(event.kind == .appeared, "the initial Disk Arbitration callback should be an appearance")
    expect(
        event.description.bsdName?.isEmpty == false,
        "a normalized disk event should preserve its BSD name"
    )
    expect(
        event.description.physicalDiskBSDName?.isEmpty == false,
        "a normalized disk event should preserve its whole-disk parent"
    )
}

func liveIOMediaEnumerationProducesAStableReadOnlySnapshot() {
    do {
        let snapshot = try SystemIOMediaEnumerationReader().currentSnapshot()
        expect(
            !snapshot.bsdNames.isEmpty,
            "the current Mac should expose at least one BSD-named IOMedia service"
        )
        expect(
            snapshot.bsdNames.allSatisfy { !$0.isEmpty },
            "the live independent snapshot must contain only usable BSD names"
        )
    } catch {
        fatalError("CHECK FAILED: live IOMedia enumeration should stabilize: \(error)")
    }
}

func diskDescription(
    bsdName: String,
    physicalDiskBSDName: String,
    isWholeDisk: Bool,
    volumeUUID: String? = nil,
    volumeName: String? = nil,
    fileSystemName: String? = nil
) -> DiskArbitrationDescription {
    DiskArbitrationDescription(
        bsdName: bsdName,
        physicalDiskBSDName: physicalDiskBSDName,
        isWholeDisk: isWholeDisk,
        isInternal: false,
        isEjectable: true,
        isRemovable: true,
        mediaSize: 1_000_000,
        mediaUUID: isWholeDisk ? "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" : nil,
        volumeUUID: volumeUUID,
        volumeName: volumeName,
        fileSystemName: fileSystemName,
        mountPoint: nil,
        roleEvidence: .trustedData
    )
}

func gate1UnknownCandidateObservation(
    diskBSDName: String,
    volumeBSDName: String,
    volumeUUID: String,
    volumeName: String,
    mountPoint: String
) async -> DiskInventoryObservation {
    let mountRecord = SystemMountRecord(
        sourcePath: "/dev/\(volumeBSDName)",
        sourceBSDName: volumeBSDName,
        mountPoint: mountPoint,
        fileSystemName: "ntfs",
        access: .readOnly,
        backend: .unknown,
        isCanonical: true,
        isSymlink: false
    )
    let inventory = ReadOnlyDiskInventory(
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [mountRecord])
        }
    )
    let wholeDisk = DiskArbitrationDescription(
        bsdName: diskBSDName,
        physicalDiskBSDName: diskBSDName,
        isWholeDisk: true,
        isInternal: false,
        isEjectable: true,
        isRemovable: true,
        mediaSize: 1_000_000,
        mediaUUID: "71000000-0000-0000-0000-000000000000",
        volumeUUID: nil,
        volumeName: nil,
        fileSystemName: nil,
        mountPoint: nil
    )
    let volume = DiskArbitrationDescription(
        bsdName: volumeBSDName,
        physicalDiskBSDName: diskBSDName,
        isWholeDisk: false,
        isInternal: false,
        isEjectable: true,
        isRemovable: true,
        mediaSize: 1_000_000,
        mediaUUID: nil,
        volumeUUID: volumeUUID,
        volumeName: volumeName,
        fileSystemName: "ntfs",
        mountPoint: mountPoint
    )
    await inventory.handle(DiskArbitrationEvent(kind: .appeared, description: wholeDisk))
    await inventory.handle(DiskArbitrationEvent(kind: .appeared, description: volume))
    _ = await inventory.verifyEnumerationCoverage(
        using: IOMediaEnumerationSnapshot(bsdNames: [diskBSDName, volumeBSDName])
    )
    let observation = await inventory.currentInventory()
    guard observation.issues.isEmpty,
          observation.physicalDisks.count == 1,
          observation.physicalDisks[0].volumes.count == 1,
          observation.physicalDisks[0].volumes[0].candidate != nil,
          observation.physicalDisks[0].volumes[0].snapshot == nil,
          observation.coordinatorInventory == nil
    else {
        fatalError("CHECK FAILED: Gate 1 fixture must be one exact unknown-role candidate")
    }
    return observation
}

func gate1Observation(
    _ base: DiskInventoryObservation,
    replacingMediaGeneration generation: UInt64
) -> DiskInventoryObservation {
    guard let disk = base.physicalDisks.first,
          base.physicalDisks.count == 1
    else {
        fatalError("CHECK FAILED: generation fixture should contain exactly one disk")
    }
    let mediaGeneration = MediaGeneration(rawValue: generation)
    let volumes = disk.volumes.map { volume in
        let candidate = volume.candidate.map {
            ReadOnlyVolumeCandidate(
                id: $0.id,
                physicalDiskID: $0.physicalDiskID,
                mediaGeneration: mediaGeneration,
                displayName: $0.displayName,
                fileSystem: $0.fileSystem,
                location: $0.location,
                mountAccess: $0.mountAccess
            )
        }
        let snapshot = volume.snapshot.map {
            VolumeSnapshot(
                id: $0.id,
                physicalDiskID: $0.physicalDiskID,
                mediaGeneration: mediaGeneration,
                displayName: $0.displayName,
                fileSystem: $0.fileSystem,
                location: $0.location,
                role: $0.role,
                health: $0.health,
                mountAccess: $0.mountAccess
            )
        }
        return ReadOnlyVolumeRecord(
            evidence: volume.evidence,
            candidate: candidate,
            snapshot: snapshot,
            mountObservation: volume.mountObservation,
            issues: volume.issues
        )
    }
    return DiskInventoryObservation(
        physicalDisks: [
            ReadOnlyPhysicalDiskRecord(
                instanceID: DiskInstanceID(
                    physicalDiskID: disk.instanceID.physicalDiskID,
                    mediaGeneration: mediaGeneration
                ),
                description: disk.description,
                volumes: volumes,
                issues: disk.issues
            ),
        ],
        issues: base.issues
    )
}

func multiVolumeInventorySharesOneGenerationAndDeduplicatesCallbacks() async {
    let inventory = ReadOnlyDiskInventory(
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [])
        }
    )
    let wholeDisk = diskDescription(
        bsdName: "disk20",
        physicalDiskBSDName: "disk20",
        isWholeDisk: true
    )
    let firstVolume = diskDescription(
        bsdName: "disk20s1",
        physicalDiskBSDName: "disk20",
        isWholeDisk: false,
        volumeUUID: "10000000-0000-0000-0000-000000000001",
        volumeName: "ONE",
        fileSystemName: "ntfs"
    )
    let secondVolume = diskDescription(
        bsdName: "disk20s2",
        physicalDiskBSDName: "disk20",
        isWholeDisk: false,
        volumeUUID: "20000000-0000-0000-0000-000000000002",
        volumeName: "TWO",
        fileSystemName: "exfat"
    )

    await inventory.handle(DiskArbitrationEvent(kind: .appeared, description: wholeDisk))
    await inventory.handle(DiskArbitrationEvent(kind: .appeared, description: firstVolume))
    await inventory.handle(DiskArbitrationEvent(kind: .appeared, description: secondVolume))
    await inventory.handle(DiskArbitrationEvent(kind: .appeared, description: firstVolume))
    _ = await inventory.verifyEnumerationCoverage(
        using: IOMediaEnumerationSnapshot(
            bsdNames: ["disk20", "disk20s1", "disk20s2"]
        )
    )

    let observation = await inventory.currentInventory()
    expect(observation.physicalDisks.count == 1, "one whole disk should produce one group")
    guard let physicalDisk = observation.physicalDisks.first else {
        fatalError("CHECK FAILED: grouped inventory should contain its physical disk")
    }
    expect(physicalDisk.volumes.count == 2, "duplicate child callbacks must not duplicate volumes")
    expect(
        Set(physicalDisk.volumes.compactMap(\.snapshot?.mediaGeneration)).count == 1,
        "all sibling volumes must capture the same active media generation"
    )
    expect(physicalDisk.isComplete, "complete unmounted child facts should form a complete group")
    let expectedSafety = PhysicalDiskSafetySnapshot(
        diskInstanceID: physicalDisk.instanceID,
        ejectability: .ejectable,
        removability: .removable
    )
    expect(
        physicalDisk.safetySnapshot == expectedSafety,
        "the physical-disk group must retain confirmed ejectability and removability"
    )
    expect(
        observation.coordinatorInventory?.physicalDiskSafetySnapshots == [expectedSafety],
        "complete inventory output must carry disk safety facts beside volume snapshots"
    )
}

func inventoryNeverTreatsStartupSilenceAsACompleteEmptySystem() async {
    let inventory = ReadOnlyDiskInventory(
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [])
        }
    )

    let pending = await inventory.currentInventory()
    expect(!pending.isComplete, "an inventory with no completed DA enumeration must stay incomplete")
    expect(
        pending.issues.contains(.initialEnumerationPending),
        "startup silence should expose an explicit enumeration gap"
    )

    _ = await inventory.verifyEnumerationCoverage(
        using: IOMediaEnumerationSnapshot(bsdNames: [])
    )
    let settled = await inventory.currentInventory()
    expect(settled.isComplete, "an explicitly settled empty enumeration may be complete")
    expect(settled.physicalDisks.isEmpty, "settling must not invent physical disks")
}

func independentIOMediaCoverageMustExactlyMatchTheDAInventory() async {
    let inventory = ReadOnlyDiskInventory(
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [])
        }
    )
    let wholeDisk = diskDescription(
        bsdName: "disk30",
        physicalDiskBSDName: "disk30",
        isWholeDisk: true
    )
    let volume = diskDescription(
        bsdName: "disk30s1",
        physicalDiskBSDName: "disk30",
        isWholeDisk: false,
        volumeUUID: "30000000-0000-0000-0000-000000000001",
        volumeName: "COVERED",
        fileSystemName: "ntfs"
    )
    await inventory.handle(DiskArbitrationEvent(kind: .appeared, description: wholeDisk))
    await inventory.handle(DiskArbitrationEvent(kind: .appeared, description: volume))
    await inventory.markEnumerationSettledWithoutCoverage()

    let mismatchAccepted = await inventory.verifyEnumerationCoverage(
        using: IOMediaEnumerationSnapshot(bsdNames: ["disk30"])
    )
    expect(!mismatchAccepted, "a partial independent media set must not prove DA coverage")
    let mismatchedObservation = await inventory.currentInventory()
    expect(
        mismatchedObservation.issues.contains(.enumerationCoverageUnverified),
        "a coverage mismatch must remain explicitly unverified"
    )

    let exactMatchAccepted = await inventory.verifyEnumerationCoverage(
        using: IOMediaEnumerationSnapshot(bsdNames: ["disk30", "disk30s1"])
    )
    expect(exactMatchAccepted, "an exact independent media set should prove DA coverage")
    let exactObservation = await inventory.currentInventory()
    expect(
        exactObservation.isComplete,
        "only an exact independent set should produce a complete inventory"
    )
}

func iOMediaEnumerationRequiresTwoConsecutiveStableSnapshots() {
    let original = IOMediaEnumerationSnapshot(bsdNames: ["disk1", "disk1s1"])
    let replacement = IOMediaEnumerationSnapshot(bsdNames: ["disk2", "disk2s1"])
    let settlingSource = LockedIOMediaSnapshotSource([
        .success(original),
        .success(replacement),
        .success(replacement),
    ])
    let settlingReader = SystemIOMediaEnumerationReader(
        maximumSamples: 3,
        sampler: settlingSource.next
    )
    do {
        let settledSnapshot = try settlingReader.currentSnapshot()
        expect(
            settledSnapshot == replacement,
            "two equal consecutive independent snapshots should settle"
        )
    } catch {
        fatalError("CHECK FAILED: stable IOMedia snapshots should be accepted: \(error)")
    }

    let oscillatingSource = LockedIOMediaSnapshotSource([
        .success(original),
        .success(replacement),
        .success(original),
        .success(replacement),
    ])
    let oscillatingReader = SystemIOMediaEnumerationReader(
        maximumSamples: 4,
        sampler: oscillatingSource.next
    )
    do {
        _ = try oscillatingReader.currentSnapshot()
        fatalError("CHECK FAILED: changing IOMedia snapshots must fail closed")
    } catch let error as IOMediaEnumerationReadError {
        expect(error == .changedDuringRead, "an unstable IOMedia set needs a fixed error")
    } catch {
        fatalError("CHECK FAILED: IOMedia instability should use a typed error: \(error)")
    }

    let invalidatedThenStableSource = LockedIOMediaSnapshotSource([
        .failure(.iteratorInvalidated),
        .success(replacement),
        .success(replacement),
    ])
    let invalidatedThenStableReader = SystemIOMediaEnumerationReader(
        maximumSamples: 3,
        sampler: invalidatedThenStableSource.next
    )
    do {
        let settledSnapshot = try invalidatedThenStableReader.currentSnapshot()
        expect(
            settledSnapshot == replacement,
            "an invalidated iterator must be discarded before stable samples are accepted"
        )
    } catch {
        fatalError("CHECK FAILED: stable evidence after iterator invalidation should settle: \(error)")
    }
}

func inventoryFailsClosedAfterUnidentifiableOrParentlessDiskEvents() async {
    let inventory = ReadOnlyDiskInventory(
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [])
        }
    )
    let unidentified = DiskArbitrationDescription(
        bsdName: nil,
        physicalDiskBSDName: nil,
        isWholeDisk: nil,
        isInternal: nil,
        isEjectable: nil,
        isRemovable: nil,
        mediaSize: nil,
        mediaUUID: nil,
        volumeUUID: nil,
        volumeName: nil,
        fileSystemName: nil,
        mountPoint: nil
    )
    await inventory.handle(
        DiskArbitrationEvent(kind: .appeared, description: unidentified)
    )
    _ = await inventory.verifyEnumerationCoverage(
        using: IOMediaEnumerationSnapshot(bsdNames: [])
    )

    let afterUnidentified = await inventory.currentInventory()
    expect(
        !afterUnidentified.isComplete
            && afterUnidentified.issues.contains(.unidentifiedDiskEvent),
        "an event without a BSD identity must leave the observation fail-closed"
    )

    let parentless = DiskArbitrationDescription(
        bsdName: "disk20s9",
        physicalDiskBSDName: nil,
        isWholeDisk: false,
        isInternal: false,
        isEjectable: true,
        isRemovable: true,
        mediaSize: 1_000_000,
        mediaUUID: nil,
        volumeUUID: "90000000-0000-0000-0000-000000000009",
        volumeName: "PARENTLESS",
        fileSystemName: "ntfs",
        mountPoint: nil
    )
    await inventory.handle(
        DiskArbitrationEvent(kind: .appeared, description: parentless)
    )
    _ = await inventory.verifyEnumerationCoverage(
        using: IOMediaEnumerationSnapshot(bsdNames: ["disk20s9"])
    )

    let afterParentless = await inventory.currentInventory()
    expect(
        !afterParentless.isComplete
            && afterParentless.issues.contains(
                .missingPhysicalDiskDescription(childBSDName: "disk20s9")
            ),
        "a child without a physical parent must not disappear from a complete empty inventory"
    )
}

func inventoryExcludesOnlyExplicitNetworkVolumeEvents() async {
    let inventory = ReadOnlyDiskInventory(
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [])
        }
    )
    let networkVolume = DiskArbitrationDescription(
        bsdName: nil,
        physicalDiskBSDName: nil,
        isWholeDisk: nil,
        isInternal: nil,
        isEjectable: nil,
        isRemovable: nil,
        mediaSize: nil,
        mediaUUID: nil,
        volumeUUID: nil,
        volumeName: nil,
        fileSystemName: nil,
        mountPoint: "/Volumes/NETWORK",
        isNetworkVolume: true
    )
    await inventory.handle(
        DiskArbitrationEvent(kind: .appeared, description: networkVolume)
    )
    _ = await inventory.verifyEnumerationCoverage(
        using: IOMediaEnumerationSnapshot(bsdNames: [])
    )

    let observation = await inventory.currentInventory()
    expect(
        observation.isComplete && observation.physicalDisks.isEmpty,
        "an explicitly identified network volume must stay outside physical-disk inventory"
    )

    for networkFlag in [false, nil] as [Bool?] {
        let failClosedInventory = ReadOnlyDiskInventory(
            mountTableProvider: MountTableSnapshotProvider {
                SystemMountTableSnapshot(records: [])
            }
        )
        let ambiguous = DiskArbitrationDescription(
            bsdName: nil,
            physicalDiskBSDName: nil,
            isWholeDisk: nil,
            isInternal: nil,
            isEjectable: nil,
            isRemovable: nil,
            mediaSize: nil,
            mediaUUID: nil,
            volumeUUID: nil,
            volumeName: nil,
            fileSystemName: nil,
            mountPoint: nil,
            isNetworkVolume: networkFlag
        )
        await failClosedInventory.handle(
            DiskArbitrationEvent(kind: .appeared, description: ambiguous)
        )
        _ = await failClosedInventory.verifyEnumerationCoverage(
            using: IOMediaEnumerationSnapshot(bsdNames: [])
        )
        let failedClosed = await failClosedInventory.currentInventory()
        expect(
            failedClosed.issues.contains(.unidentifiedDiskEvent),
            "a missing or false network flag must not excuse an unidentified disk event"
        )
    }

    let mismatchInventory = ReadOnlyDiskInventory(
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [])
        }
    )
    let incorrectlyFlaggedPhysicalMedia = DiskArbitrationDescription(
        bsdName: "disk98",
        physicalDiskBSDName: "disk98",
        isWholeDisk: true,
        isInternal: false,
        isEjectable: true,
        isRemovable: true,
        mediaSize: 1_000_000,
        mediaUUID: "98000000-0000-0000-0000-000000000000",
        volumeUUID: nil,
        volumeName: nil,
        fileSystemName: nil,
        mountPoint: nil,
        isNetworkVolume: true
    )
    await mismatchInventory.handle(
        DiskArbitrationEvent(
            kind: .appeared,
            description: incorrectlyFlaggedPhysicalMedia
        )
    )
    let coverageVerified = await mismatchInventory.verifyEnumerationCoverage(
        using: IOMediaEnumerationSnapshot(bsdNames: ["disk98"])
    )
    let mismatchObservation = await mismatchInventory.currentInventory()
    expect(
        !coverageVerified
            && mismatchObservation.issues.contains(.enumerationCoverageUnverified),
        "independent IOMedia coverage must expose an incorrectly excluded physical identity"
    )
}

func diskArbitrationBooleanDecoderAcceptsOnlyCFBoolean() {
    expect(
        DiskArbitrationDescriptionValueDecoder.boolean(true) == true,
        "a true CFBoolean-backed value should decode"
    )
    expect(
        DiskArbitrationDescriptionValueDecoder.boolean(false) == false,
        "a false CFBoolean-backed value should decode"
    )
    expect(
        DiskArbitrationDescriptionValueDecoder.boolean(NSNumber(value: 1)) == nil,
        "a numeric one must not masquerade as a Disk Arbitration boolean"
    )
    expect(
        DiskArbitrationDescriptionValueDecoder.boolean("true") == nil,
        "a string must not masquerade as a Disk Arbitration boolean"
    )
    expect(
        DiskArbitrationDescriptionValueDecoder.boolean(nil) == nil,
        "a missing Disk Arbitration boolean must remain unknown"
    )
}

func readOnlyObserverSettlesWithoutClaimingEnumerationCoverage() async {
    let wholeDisk = diskDescription(
        bsdName: "disk21",
        physicalDiskBSDName: "disk21",
        isWholeDisk: true
    )
    let volume = diskDescription(
        bsdName: "disk21s1",
        physicalDiskBSDName: "disk21",
        isWholeDisk: false,
        volumeUUID: "21000000-0000-0000-0000-000000000001",
        volumeName: "SETTLED",
        fileSystemName: "ntfs"
    )
    let eventProvider = DiskEventStreamProvider {
        AsyncStream { continuation in
            continuation.yield(DiskArbitrationEvent(kind: .appeared, description: wholeDisk))
            continuation.yield(DiskArbitrationEvent(kind: .appeared, description: volume))
            continuation.finish()
        }
    }
    let observer = ReadOnlyDiskObserver(
        eventProvider: eventProvider,
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [])
        },
        settleInterval: .milliseconds(20)
    )

    let stream: AsyncStream<DiskInventoryObservation>
    do {
        stream = try observer.observations()
    } catch {
        fatalError("CHECK FAILED: injected read-only observer should start: \(error)")
    }
    guard let settled = await firstSettledInventory(from: stream) else {
        fatalError("CHECK FAILED: injected read-only events should settle within two seconds")
    }
    expect(settled.physicalDisks.count == 1, "settled observer output should contain one disk")
    expect(
        settled.physicalDisks.first?.volumes.count == 1,
        "settled observer output should contain the complete child list"
    )
    expect(
        !settled.isComplete
            && settled.issues.contains(.enumerationCoverageUnverified),
        "a quiet callback window must not be promoted to complete enumeration evidence"
    )
}

func readOnlyObserverPromotesOnlyExactIndependentCoverage() async {
    let wholeDisk = diskDescription(
        bsdName: "disk31",
        physicalDiskBSDName: "disk31",
        isWholeDisk: true
    )
    let volume = diskDescription(
        bsdName: "disk31s1",
        physicalDiskBSDName: "disk31",
        isWholeDisk: false,
        volumeUUID: "31000000-0000-0000-0000-000000000001",
        volumeName: "VERIFIED",
        fileSystemName: "ntfs"
    )

    func completedOutput(
        independentBSDNames: Set<String>
    ) async -> [DiskInventoryObservation] {
        let observer = ReadOnlyDiskObserver(
            eventProvider: DiskEventStreamProvider {
                AsyncStream { continuation in
                    continuation.yield(
                        DiskArbitrationEvent(kind: .appeared, description: wholeDisk)
                    )
                    continuation.yield(
                        DiskArbitrationEvent(kind: .appeared, description: volume)
                    )
                    continuation.finish()
                }
            },
            mountTableProvider: MountTableSnapshotProvider {
                SystemMountTableSnapshot(records: [])
            },
            mediaEnumerationProvider: IOMediaEnumerationSnapshotProvider {
                IOMediaEnumerationSnapshot(bsdNames: independentBSDNames)
            },
            settleInterval: .milliseconds(10),
            enumerationTimeout: .milliseconds(100)
        )
        do {
            guard let output = await finishedObserverOutput(try observer.observations()) else {
                fatalError("CHECK FAILED: covered observer output should finish")
            }
            return output
        } catch {
            fatalError("CHECK FAILED: injected covered observer should start: \(error)")
        }
    }

    let exactOutput = await completedOutput(
        independentBSDNames: ["disk31", "disk31s1"]
    )
    expect(
        exactOutput.contains(where: \.isComplete),
        "exact independent coverage should promote a settled DA inventory"
    )

    let partialOutput = await completedOutput(independentBSDNames: ["disk31"])
    expect(
        !partialOutput.contains(where: \.isComplete),
        "partial independent coverage must never promote the DA inventory"
    )
    expect(
        partialOutput.last?.issues.contains(.enumerationCoverageUnverified) == true,
        "coverage mismatch must finish in an explicitly unverified state"
    )
}

func readOnlyObserverCoverageTimeoutFailsClosed() async {
    let observer = ReadOnlyDiskObserver(
        eventProvider: DiskEventStreamProvider {
            AsyncStream { continuation in
                continuation.finish()
            }
        },
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [])
        },
        mediaEnumerationProvider: IOMediaEnumerationSnapshotProvider {
            Thread.sleep(forTimeInterval: 0.1)
            return IOMediaEnumerationSnapshot(bsdNames: [])
        },
        settleInterval: .milliseconds(1),
        enumerationTimeout: .milliseconds(5)
    )

    do {
        guard let output = await finishedObserverOutput(try observer.observations()),
              let final = output.last
        else {
            fatalError("CHECK FAILED: timed-out coverage output should finish")
        }
        expect(
            !final.isComplete
                && final.issues.contains(.enumerationCoverageUnverified),
            "a timed-out independent enumeration must remain fail-closed"
        )
    } catch {
        fatalError("CHECK FAILED: injected timeout observer should start: \(error)")
    }
}

func firstSettledInventory(
    from stream: AsyncStream<DiskInventoryObservation>
) async -> DiskInventoryObservation? {
    await withTaskGroup(of: DiskInventoryObservation?.self) { group in
        group.addTask {
            for await observation in stream
            where !observation.issues.contains(.initialEnumerationPending) {
                return observation
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(2))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

func observerPublishesSettledIncompleteEvidenceWithoutFabricatingSnapshots() async {
    let wholeDisk = diskDescription(
        bsdName: "disk22",
        physicalDiskBSDName: "disk22",
        isWholeDisk: true
    )
    let volumeMissingUUID = diskDescription(
        bsdName: "disk22s1",
        physicalDiskBSDName: "disk22",
        isWholeDisk: false,
        volumeName: "INCOMPLETE",
        fileSystemName: "ntfs"
    )
    let observer = ReadOnlyDiskObserver(
        eventProvider: DiskEventStreamProvider {
            AsyncStream { continuation in
                continuation.yield(
                    DiskArbitrationEvent(kind: .appeared, description: wholeDisk)
                )
                continuation.yield(
                    DiskArbitrationEvent(kind: .appeared, description: volumeMissingUUID)
                )
                continuation.finish()
            }
        },
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [])
        },
        settleInterval: .milliseconds(20)
    )

    let stream: AsyncStream<DiskInventoryObservation>
    do {
        stream = try observer.observations()
    } catch {
        fatalError("CHECK FAILED: injected incomplete observer should start: \(error)")
    }
    guard let settled = await firstSettledInventory(from: stream) else {
        fatalError("CHECK FAILED: settled incomplete evidence should still be published")
    }
    expect(!settled.isComplete, "a missing volume UUID must keep the inventory incomplete")
    expect(settled.volumeSnapshots == nil, "incomplete evidence must not project snapshots")
    expect(
        settled.physicalDisks.first?.volumes.first?.issues.contains(.missingVolumeUUID) == true,
        "the settled result should preserve the exact evidence gap"
    )
}

func liveReadOnlyObserverSettlesTheCurrentSystem() async {
    let stream: AsyncStream<DiskInventoryObservation>
    do {
        stream = try ReadOnlyDiskObserver().observations()
    } catch {
        fatalError("CHECK FAILED: live read-only observer should start: \(error)")
    }
    guard let settled = await firstSettledInventory(from: stream) else {
        fatalError("CHECK FAILED: live read-only inventory should settle within two seconds")
    }
    expect(
        !settled.physicalDisks.isEmpty,
        "the current Mac should expose at least one physical disk group"
    )
    expect(
        !settled.issues.contains(.initialEnumerationPending),
        "a settled live observation must clear its enumeration marker"
    )
    expect(
        !settled.isComplete
            && settled.issues.contains(.enumerationCoverageUnverified),
        "live Disk Arbitration silence cannot prove full enumeration coverage"
    )
}

func liveReadOnlyObserverVerifiesIndependentEnumerationCoverage() async {
    let stream: AsyncStream<DiskInventoryObservation>
    do {
        stream = try ReadOnlyDiskObserver().observations()
    } catch {
        fatalError("CHECK FAILED: live covered observer should start: \(error)")
    }

    let covered = await withTaskGroup(of: DiskInventoryObservation?.self) { group in
        group.addTask {
            for await observation in stream
            where observation.issues.isEmpty
            {
                return observation
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(2))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }

    guard let covered else {
        fatalError("CHECK FAILED: live IOKit and DA enumeration should agree within two seconds")
    }
    expect(
        !covered.physicalDisks.isEmpty,
        "verified live enumeration coverage should retain current physical disks"
    )
}

func mountPathValidatorSeparatesCanonicalPathsFromSymlinksAndDotSegments() {
    let root = MountPathValidator.assess("/")
    expect(root.isCanonical, "the filesystem root should be canonical")
    expect(!root.isSymlink, "the filesystem root should not be a symlink")

    let dotSegment = MountPathValidator.assess("/System/Volumes/Data/../Data")
    expect(!dotSegment.isCanonical, "a path containing dot segments must not be canonical")
    expect(!dotSegment.isSymlink, "dot-segment normalization alone is not a symlink")

    let fixtureRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("NTFSLite-MountPath-\(UUID().uuidString)")
    let target = fixtureRoot.appendingPathComponent("target")
    let alias = fixtureRoot.appendingPathComponent("alias")
    do {
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: target
        )
    } catch {
        fatalError("CHECK FAILED: mount path symlink fixture should be creatable: \(error)")
    }
    defer {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }
    let symbolicAlias = MountPathValidator.assess(alias.path)
    expect(!symbolicAlias.isCanonical, "a symbolic alias must not be canonical")
    expect(symbolicAlias.isSymlink, "a symbolic alias should be identified as a symlink")
}

func wholeDiskDisappearanceRotatesGenerationAfterAnIncompleteChange() async {
    let inventory = ReadOnlyDiskInventory(
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [])
        }
    )
    let wholeDisk = diskDescription(
        bsdName: "disk23",
        physicalDiskBSDName: "disk23",
        isWholeDisk: true
    )
    let volume = diskDescription(
        bsdName: "disk23s1",
        physicalDiskBSDName: "disk23",
        isWholeDisk: false,
        volumeUUID: "23000000-0000-0000-0000-000000000001",
        volumeName: "REINSERT",
        fileSystemName: "ntfs"
    )
    await inventory.handle(DiskArbitrationEvent(kind: .appeared, description: wholeDisk))
    await inventory.handle(DiskArbitrationEvent(kind: .appeared, description: volume))
    guard let firstGeneration = await inventory.currentInventory()
        .physicalDisks.first?.instanceID.mediaGeneration
    else {
        fatalError("CHECK FAILED: first physical appearance should have a generation")
    }

    let incompleteWholeChange = DiskArbitrationDescription(
        bsdName: "disk23",
        physicalDiskBSDName: "disk23",
        isWholeDisk: nil,
        isInternal: nil,
        isEjectable: nil,
        isRemovable: nil,
        mediaSize: nil,
        mediaUUID: nil,
        volumeUUID: nil,
        volumeName: nil,
        fileSystemName: nil,
        mountPoint: nil
    )
    await inventory.handle(
        DiskArbitrationEvent(kind: .descriptionChanged, description: incompleteWholeChange)
    )
    await inventory.handle(
        DiskArbitrationEvent(kind: .disappeared, description: incompleteWholeChange)
    )
    await inventory.handle(DiskArbitrationEvent(kind: .appeared, description: wholeDisk))
    await inventory.handle(DiskArbitrationEvent(kind: .appeared, description: volume))

    guard let secondGeneration = await inventory.currentInventory()
        .physicalDisks.first?.instanceID.mediaGeneration
    else {
        fatalError("CHECK FAILED: reinserted physical media should have a generation")
    }
    expect(
        secondGeneration.rawValue > firstGeneration.rawValue,
        "confirmed whole-disk disappearance must rotate generation after reinsertion"
    )
}

func gate1EvidenceHeaderAcceptsOnlyOpaqueEvidenceIDs() {
    expect(
        (try? Gate1EvidenceHeader(
            evidenceID: "G1-LEOLU-DISK-SERIAL",
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "a", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )) == nil,
        "free-form evidence IDs must not carry usernames or disk identity into canonical evidence"
    )
    expect(
        (try? Gate1EvidenceHeader(
            evidenceID: "G1-0123456789ABCDEF0123456789ABCDEF",
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "a", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )) != nil,
        "an opaque fixed-length hexadecimal evidence ID should be accepted"
    )
}

func gate1EvidenceWithoutHardwareCyclesStaysIncomplete() async {
    let header = try! Gate1EvidenceHeader(
        evidenceID: gate1FixtureEvidenceID,
        applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
        applicationBuild: 1,
        applicationSHA256: String(repeating: "a", count: 64),
        macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
    )
    let recorder = Gate1EvidenceRecorder(header: header)
    let artifact = try! await recorder.seal(
        at: GateEvidenceTimestamp(millisecondsSince1970: 1_788_112_000_000)
    )

    expect(
        artifact.bundle.verdict == .incomplete,
        "a session without real completed hardware cycles must stay incomplete"
    )
    let canonicalText = String(decoding: artifact.canonicalJSON, as: UTF8.self)
    expect(
        !canonicalText.lowercased().contains("pass"),
        "Gate 1 evidence must not expose an automatic pass result"
    )
}

func gate1EvidenceStatusExposesOnlyAnonymousBoundedProgress() async {
    let observation = await gate1UnknownCandidateObservation(
        diskBSDName: "disk724",
        volumeBSDName: "disk724s1",
        volumeUUID: "72400000-0000-0000-0000-000000000001",
        volumeName: "STATUS-POISON",
        mountPoint: "/Volumes/STATUS-POISON"
    )
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "1", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )

    let initial = await recorder.status()
    expect(
        initial == Gate1EvidenceRecorderStatus(
            phase: .recording,
            observationCount: 0,
            checkpointCount: 0,
            completedCycleCount: 0,
            requiredCycleCount: 100,
            openConnectionCount: 0,
            failureCodes: []
        ),
        "a new evidence session should expose only zeroed anonymous progress"
    )

    do {
        try await recorder.ingest(
            observation,
            at: GateEvidenceTimestamp(millisecondsSince1970: 5)
        )
        let recording = await recorder.status()
        expect(
            recording.phase == .recording
                && recording.observationCount == 1
                && recording.openConnectionCount == 1,
            "status should report bounded counts without source identities"
        )
        _ = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 6)
        )
        let sealed = await recorder.status()
        expect(
            sealed.phase == .sealed
                && sealed.observationCount == 1
                && sealed.openConnectionCount == 1,
            "sealing should freeze the same anonymous progress counters"
        )
    } catch {
        fatalError("CHECK FAILED: status evidence should record: \(error)")
    }
}

func gate1EvidenceProjectsCandidateWithoutRawIdentityOrMutationEligibility() async {
    let rawDisk = "disk710"
    let rawVolume = "disk710s1"
    let rawUUID = "71000000-0000-0000-0000-000000000001"
    let rawName = "SECRET-LABEL"
    let rawMountPoint = "/Volumes/SECRET-LABEL"
    let observation = await gate1UnknownCandidateObservation(
        diskBSDName: rawDisk,
        volumeBSDName: rawVolume,
        volumeUUID: rawUUID,
        volumeName: rawName,
        mountPoint: rawMountPoint
    )
    let header = try! Gate1EvidenceHeader(
        evidenceID: gate1FixtureEvidenceID,
        applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
        applicationBuild: 1,
        applicationSHA256: String(repeating: "b", count: 64),
        macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
    )
    let recorder = Gate1EvidenceRecorder(header: header)

    do {
        try await recorder.ingest(
            observation,
            at: GateEvidenceTimestamp(millisecondsSince1970: 1_788_112_000_001)
        )
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 1_788_112_000_002)
        )
        expect(
            artifact.bundle.observations.count == 1,
            "one accepted system observation should produce one evidence frame"
        )
        guard let disk = artifact.bundle.observations.first?.disks.first else {
            fatalError("CHECK FAILED: candidate evidence must include its anonymous disk frame")
        }
        expect(disk.candidateCount == 1, "the frame should retain candidate meaning")
        expect(
            disk.mutationSnapshotCount == 0,
            "an unknown-role candidate must retain zero mutation snapshots"
        )
        expect(
            artifact.bundle.observations[0].coordinatorInventoryPresent == false,
            "candidate evidence must show that no coordinator inventory was available"
        )

        let canonicalText = String(decoding: artifact.canonicalJSON, as: UTF8.self)
        for forbiddenValue in [
            rawDisk,
            rawVolume,
            rawUUID,
            rawName,
            rawMountPoint,
            "/dev/\(rawVolume)",
        ] {
            expect(
                !canonicalText.contains(forbiddenValue),
                "canonical Gate 1 evidence must not retain a raw disk value"
            )
        }
        for forbiddenKey in [
            "bsdName",
            "physicalDiskBSDName",
            "volumeUUID",
            "mediaUUID",
            "volumeName",
            "mountPoint",
            "sourcePath",
        ] {
            expect(
                !canonicalText.contains(forbiddenKey),
                "canonical Gate 1 evidence must not expose raw identity fields"
            )
        }
    } catch {
        fatalError("CHECK FAILED: one private candidate observation should record: \(error)")
    }
}

func gate1EvidenceNormalizesEquivalentVolumeUUIDCase() async {
    let observation = await gate1UnknownCandidateObservation(
        diskBSDName: "disk737",
        volumeBSDName: "disk737s1",
        volumeUUID: "ABCDEF12-3456-7890-ABCD-EF1234567890",
        volumeName: "UPPERCASE-UUID",
        mountPoint: "/Volumes/UPPERCASE-UUID"
    )
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "c", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )

    do {
        try await recorder.ingest(
            observation,
            at: GateEvidenceTimestamp(millisecondsSince1970: 10)
        )
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 11)
        )
        expect(
            artifact.bundle.failureCodes.isEmpty
                && artifact.bundle.observations.first?.disks.first?.candidateCount == 1,
            "UUID letter case must not fabricate a topology contradiction"
        )
    } catch {
        fatalError("CHECK FAILED: equivalent UUID case should record: \(error)")
    }
}

func gate1EvidenceCountsOnlyAConfirmedPresentToAbsentCycle() async {
    let present = await gate1UnknownCandidateObservation(
        diskBSDName: "disk711",
        volumeBSDName: "disk711s1",
        volumeUUID: "71100000-0000-0000-0000-000000000001",
        volumeName: "LIFECYCLE",
        mountPoint: "/Volumes/LIFECYCLE"
    )
    let unverifiedAbsence = DiskInventoryObservation(
        physicalDisks: [],
        issues: [.enumerationCoverageUnverified]
    )
    let verifiedAbsence = DiskInventoryObservation(physicalDisks: [], issues: [])
    func recorder(_ suffix: String) -> Gate1EvidenceRecorder {
        Gate1EvidenceRecorder(
            header: try! Gate1EvidenceHeader(
                evidenceID: gate1FixtureEvidenceID,
                applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
                applicationBuild: 1,
                applicationSHA256: String(repeating: "c", count: 64),
                macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
            )
        )
    }

    do {
        let uncertainRecorder = recorder("UNCERTAIN")
        try await uncertainRecorder.ingest(
            DiskInventoryObservation(physicalDisks: [], issues: []),
            at: GateEvidenceTimestamp(millisecondsSince1970: 9)
        )
        try await uncertainRecorder.ingest(
            present,
            at: GateEvidenceTimestamp(millisecondsSince1970: 10)
        )
        try await uncertainRecorder.ingest(
            unverifiedAbsence,
            at: GateEvidenceTimestamp(millisecondsSince1970: 11)
        )
        try await uncertainRecorder.ingest(
            verifiedAbsence,
            at: GateEvidenceTimestamp(millisecondsSince1970: 12)
        )
        let uncertain = try await uncertainRecorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 13)
        )
        expect(
            uncertain.bundle.completedCycleCount == 1
                && uncertain.bundle.verdict == .incomplete,
            "an unverified transition must wait for a later verified absence before counting"
        )

        let confirmedRecorder = recorder("CONFIRMED")
        try await confirmedRecorder.ingest(
            DiskInventoryObservation(physicalDisks: [], issues: []),
            at: GateEvidenceTimestamp(millisecondsSince1970: 19)
        )
        try await confirmedRecorder.ingest(
            present,
            at: GateEvidenceTimestamp(millisecondsSince1970: 20)
        )
        try await confirmedRecorder.ingest(
            verifiedAbsence,
            at: GateEvidenceTimestamp(millisecondsSince1970: 21)
        )
        let confirmed = try await confirmedRecorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 22)
        )
        expect(
            confirmed.bundle.completedCycleCount == 1,
            "only verified absence after a reviewable candidate should complete one cycle"
        )
        expect(
            confirmed.bundle.observations.last?.confirmedAbsentDiskOrdinals == [1],
            "the absence frame should identify only the anonymous removed disk"
        )
    } catch {
        fatalError("CHECK FAILED: Gate 1 lifecycle evidence should record: \(error)")
    }
}

func gate1EvidencePermanentlyFailsWhenGenerationChangesBeforeAbsence() async {
    let present = await gate1UnknownCandidateObservation(
        diskBSDName: "disk712",
        volumeBSDName: "disk712s1",
        volumeUUID: "71200000-0000-0000-0000-000000000001",
        volumeName: "GENERATION",
        mountPoint: "/Volumes/GENERATION"
    )
    guard let originalDisk = present.physicalDisks.first,
          let originalRecord = originalDisk.volumes.first,
          let originalCandidate = originalRecord.candidate
    else {
        fatalError("CHECK FAILED: generation fixture should contain one candidate")
    }
    let changedGeneration = MediaGeneration(
        rawValue: originalDisk.instanceID.mediaGeneration.rawValue + 1
    )
    let changedCandidate = ReadOnlyVolumeCandidate(
        id: originalCandidate.id,
        physicalDiskID: originalCandidate.physicalDiskID,
        mediaGeneration: changedGeneration,
        displayName: originalCandidate.displayName,
        fileSystem: originalCandidate.fileSystem,
        location: originalCandidate.location,
        mountAccess: originalCandidate.mountAccess
    )
    let contradictory = DiskInventoryObservation(
        physicalDisks: [
            ReadOnlyPhysicalDiskRecord(
                instanceID: changedCandidate.diskInstanceID,
                description: originalDisk.description,
                volumes: [
                    ReadOnlyVolumeRecord(
                        evidence: originalRecord.evidence,
                        candidate: changedCandidate,
                        snapshot: nil,
                        mountObservation: nil,
                        issues: originalRecord.issues
                    ),
                ],
                issues: originalDisk.issues
            ),
        ],
        issues: []
    )
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "d", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )

    do {
        try await recorder.ingest(
            present,
            at: GateEvidenceTimestamp(millisecondsSince1970: 30)
        )
        do {
            try await recorder.ingest(
                contradictory,
                at: GateEvidenceTimestamp(millisecondsSince1970: 31)
            )
            fatalError("CHECK FAILED: a generation change before absence must be rejected")
        } catch let error as Gate1EvidenceRecorderError {
            expect(
                error == .mediaGenerationChangedBeforeAbsence,
                "the rejected observation should retain its fixed generation failure"
            )
        }
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 32)
        )
        expect(
            artifact.bundle.verdict == .failedClosed,
            "a caught generation contradiction must leave the recorder failed closed"
        )
        expect(
            artifact.bundle.failureCodes == [.mediaGenerationChangedBeforeAbsence],
            "the sealed bundle should retain the fixed failure code without raw identity"
        )
    } catch {
        fatalError("CHECK FAILED: failed-closed generation evidence should seal: \(error)")
    }
}

func gate1EvidenceFailsWhenGenerationIsReusedAfterConfirmedAbsence() async {
    let present = await gate1UnknownCandidateObservation(
        diskBSDName: "disk720",
        volumeBSDName: "disk720s1",
        volumeUUID: "72000000-0000-0000-0000-000000000001",
        volumeName: "REUSED-GENERATION",
        mountPoint: "/Volumes/REUSED-GENERATION"
    )
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "b", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )

    do {
        try await recorder.ingest(
            present,
            at: GateEvidenceTimestamp(millisecondsSince1970: 40)
        )
        try await recorder.ingest(
            DiskInventoryObservation(physicalDisks: [], issues: []),
            at: GateEvidenceTimestamp(millisecondsSince1970: 41)
        )
        do {
            try await recorder.ingest(
                present,
                at: GateEvidenceTimestamp(millisecondsSince1970: 42)
            )
            fatalError("CHECK FAILED: a reused post-absence generation must be rejected")
        } catch let error as Gate1EvidenceRecorderError {
            expect(
                error == .mediaGenerationReusedAfterAbsence,
                "generation reuse should expose one fixed lifecycle error"
            )
        }
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 43)
        )
        expect(
            artifact.bundle.failureCodes == [.mediaGenerationReusedAfterAbsence]
                && artifact.bundle.verdict == .failedClosed,
            "post-absence generation reuse must remain permanently failed closed"
        )
        expect(
            artifact.bundle.observations.count == 2
                && artifact.bundle.openConnectionCount == 0,
            "the rejected reconnect must not create an alias or open connection"
        )
    } catch {
        fatalError("CHECK FAILED: reused-generation evidence should seal: \(error)")
    }
}

func gate1EvidenceFailsWhenGenerationRegressesAfterConfirmedAbsence() async {
    let base = await gate1UnknownCandidateObservation(
        diskBSDName: "disk721",
        volumeBSDName: "disk721s1",
        volumeUUID: "72100000-0000-0000-0000-000000000001",
        volumeName: "REGRESSED-GENERATION",
        mountPoint: "/Volumes/REGRESSED-GENERATION"
    )
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "c", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )

    do {
        try await recorder.ingest(
            gate1Observation(base, replacingMediaGeneration: 5),
            at: GateEvidenceTimestamp(millisecondsSince1970: 50)
        )
        try await recorder.ingest(
            DiskInventoryObservation(physicalDisks: [], issues: []),
            at: GateEvidenceTimestamp(millisecondsSince1970: 51)
        )
        do {
            try await recorder.ingest(
                gate1Observation(base, replacingMediaGeneration: 4),
                at: GateEvidenceTimestamp(millisecondsSince1970: 52)
            )
            fatalError("CHECK FAILED: a regressed post-absence generation must be rejected")
        } catch let error as Gate1EvidenceRecorderError {
            expect(
                error == .mediaGenerationRegressedAfterAbsence,
                "generation regression should expose one fixed lifecycle error"
            )
        }
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 53)
        )
        expect(
            artifact.bundle.failureCodes == [.mediaGenerationRegressedAfterAbsence]
                && artifact.bundle.verdict == .failedClosed,
            "post-absence generation regression must remain permanently failed closed"
        )
    } catch {
        fatalError("CHECK FAILED: regressed-generation evidence should seal: \(error)")
    }
}

func gate1EvidenceFailsWhenGenerationIsUnknownAfterConfirmedAbsence() async {
    let base = await gate1UnknownCandidateObservation(
        diskBSDName: "disk723",
        volumeBSDName: "disk723s1",
        volumeUUID: "72300000-0000-0000-0000-000000000001",
        volumeName: "UNKNOWN-GENERATION",
        mountPoint: "/Volumes/UNKNOWN-GENERATION"
    )
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "f", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )

    do {
        try await recorder.ingest(
            gate1Observation(base, replacingMediaGeneration: 5),
            at: GateEvidenceTimestamp(millisecondsSince1970: 60)
        )
        try await recorder.ingest(
            DiskInventoryObservation(physicalDisks: [], issues: []),
            at: GateEvidenceTimestamp(millisecondsSince1970: 61)
        )
        do {
            try await recorder.ingest(
                gate1Observation(base, replacingMediaGeneration: 0),
                at: GateEvidenceTimestamp(millisecondsSince1970: 62)
            )
            fatalError("CHECK FAILED: an unknown post-absence generation must be rejected")
        } catch let error as Gate1EvidenceRecorderError {
            expect(
                error == .mediaGenerationUnknownAfterAbsence,
                "unknown generation should expose one fixed lifecycle error"
            )
        }
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 63)
        )
        expect(
            artifact.bundle.failureCodes == [.mediaGenerationUnknownAfterAbsence]
                && artifact.bundle.verdict == .failedClosed,
            "unknown post-absence generation must remain permanently failed closed"
        )
    } catch {
        fatalError("CHECK FAILED: unknown-generation evidence should seal: \(error)")
    }
}

func gate1SyntheticCycleRecorder(
    evidenceID: String,
    cycleCount: Int
) async throws -> (
    recorder: Gate1EvidenceRecorder,
    observedGenerations: [UInt64],
    nextTimestamp: Int64
) {
    let diskBSDName = "disk713"
    let volumeBSDName = "disk713s1"
    let wholeDisk = DiskArbitrationDescription(
        bsdName: diskBSDName,
        physicalDiskBSDName: diskBSDName,
        isWholeDisk: true,
        isInternal: false,
        isEjectable: true,
        isRemovable: true,
        mediaSize: 1_000_000,
        mediaUUID: "71300000-0000-0000-0000-000000000000",
        volumeUUID: nil,
        volumeName: nil,
        fileSystemName: nil,
        mountPoint: nil
    )
    let volume = DiskArbitrationDescription(
        bsdName: volumeBSDName,
        physicalDiskBSDName: diskBSDName,
        isWholeDisk: false,
        isInternal: false,
        isEjectable: true,
        isRemovable: true,
        mediaSize: 1_000_000,
        mediaUUID: nil,
        volumeUUID: "71300000-0000-0000-0000-000000000001",
        volumeName: "SYNTHETIC-CYCLE",
        fileSystemName: "ntfs",
        mountPoint: nil
    )
    let siblingVolume = DiskArbitrationDescription(
        bsdName: "disk713s2",
        physicalDiskBSDName: diskBSDName,
        isWholeDisk: false,
        isInternal: false,
        isEjectable: true,
        isRemovable: true,
        mediaSize: 1_000_000,
        mediaUUID: nil,
        volumeUUID: "71300000-0000-0000-0000-000000000002",
        volumeName: "SYNTHETIC-SIBLING",
        fileSystemName: "exfat",
        mountPoint: nil
    )
    let inventory = ReadOnlyDiskInventory(
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [])
        }
    )
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: evidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "e", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )
    var observedGenerations: [UInt64] = []
    try await recorder.ingest(
        DiskInventoryObservation(physicalDisks: [], issues: []),
        at: GateEvidenceTimestamp(millisecondsSince1970: 99)
    )

    for round in 0 ..< cycleCount {
        await inventory.handle(
            DiskArbitrationEvent(kind: .appeared, description: wholeDisk)
        )
        await inventory.handle(
            DiskArbitrationEvent(kind: .appeared, description: volume)
        )
        await inventory.handle(
            DiskArbitrationEvent(kind: .appeared, description: siblingVolume)
        )
        _ = await inventory.verifyEnumerationCoverage(
            using: IOMediaEnumerationSnapshot(
                bsdNames: [diskBSDName, volumeBSDName, "disk713s2"]
            )
        )
        let present = await inventory.currentInventory()
        guard let generation = present.physicalDisks.first?
            .instanceID.mediaGeneration.rawValue,
              present.physicalDisks.first?.volumes.first?.candidate != nil
        else {
            fatalError("CHECK FAILED: every synthetic round should expose its candidate")
        }
        observedGenerations.append(generation)
        try await recorder.ingest(
            present,
            at: GateEvidenceTimestamp(
                millisecondsSince1970: Int64(100 + round * 2)
            )
        )
        for kind in [
            Gate1CheckpointKind.systemInventoryComparison,
            .mountTableComparison,
        ] {
            try await recorder.record(
                Gate1OperatorCheckpoint(
                    kind: kind,
                    roundOrdinal: UInt16(round + 1),
                    finding: .confirmed
                ),
                at: GateEvidenceTimestamp(
                    millisecondsSince1970: Int64(100 + round * 2)
                )
            )
        }

        await inventory.handle(
            DiskArbitrationEvent(kind: .disappeared, description: wholeDisk)
        )
        _ = await inventory.verifyEnumerationCoverage(
            using: IOMediaEnumerationSnapshot(bsdNames: [])
        )
        let absent = await inventory.currentInventory()
        expect(
            absent.physicalDisks.isEmpty,
            "confirmed disappearance must leave no ghost physical disk"
        )
        try await recorder.ingest(
            absent,
            at: GateEvidenceTimestamp(
                millisecondsSince1970: Int64(101 + round * 2)
            )
        )
    }
    return (
        recorder,
        observedGenerations,
        Int64(100 + cycleCount * 2)
    )
}

func gate1EvidenceTracksOneHundredSyntheticCyclesWithoutAwardingGatePass() async {
    do {
        let fixture = try await gate1SyntheticCycleRecorder(
            evidenceID: gate1FixtureEvidenceID,
            cycleCount: 100
        )
        expect(
            zip(
                fixture.observedGenerations,
                fixture.observedGenerations.dropFirst()
            ).allSatisfy(<),
            "the production inventory fixture should rotate generation every round"
        )
        let artifact = try await fixture.recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: fixture.nextTimestamp)
        )
        expect(
            artifact.bundle.completedCycleCount == 100
                && artifact.bundle.cycleRequirementMet,
            "one hundred confirmed synthetic lifecycles should satisfy only the cycle count"
        )
        expect(
            artifact.bundle.multiPartitionObservationPresent,
            "the evidence should derive multi-partition coverage from a real typed observation"
        )
        expect(
            artifact.bundle.verdict == .incomplete,
            "synthetic cycles without required checkpoints must never award Gate readiness"
        )
        let presentFrames = artifact.bundle.observations.compactMap {
            $0.disks.first
        }
        expect(
            presentFrames.first?.mediaGenerationRelation == .first
                && presentFrames.dropFirst().allSatisfy {
                    $0.mediaGenerationRelation == .advanced
                },
            "only confirmed absence should allow each next connection to advance generation"
        )
        expect(
            presentFrames.map(\.connectionOrdinal) == Array(1 ... 100),
            "each reinserted connection should receive a new anonymous ordinal"
        )
        expect(
            presentFrames.allSatisfy {
                $0.volumeCount == 2
                    && $0.candidateCount == 1
                    && $0.mutationSnapshotCount == 0
            },
            "each multi-partition frame should keep one candidate and zero mutation snapshots"
        )
        switch Gate1EvidenceArtifactVerifier.verify(
            canonicalJSON: artifact.canonicalJSON,
            expectedSHA256Digest: artifact.sha256Digest
        ) {
        case let .success(verified):
            expect(
                verified.bundle.completedCycleCount == 100,
                "semantic replay should admit all one hundred recorded lifecycles"
            )
        case let .failure(failure):
            fatalError("CHECK FAILED: 100-cycle evidence did not verify: \(failure)")
        }
    } catch {
        fatalError("CHECK FAILED: one hundred synthetic Gate 1 cycles should record: \(error)")
    }
}

func gate1EvidenceRecordsOnlyClosedOperatorCheckpoints() async {
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "f", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )
    let checkpoint = Gate1OperatorCheckpoint(
        kind: .wakeResubscription,
        roundOrdinal: nil,
        finding: .confirmed
    )

    do {
        try await recorder.record(
            checkpoint,
            at: GateEvidenceTimestamp(millisecondsSince1970: 400)
        )
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 401)
        )
        expect(
            artifact.bundle.checkpoints == [
                Gate1EvidenceCheckpoint(
                    sequence: 1,
                    occurredAt: GateEvidenceTimestamp(millisecondsSince1970: 400),
                    kind: .wakeResubscription,
                    roundOrdinal: nil,
                    finding: .confirmed
                ),
            ],
            "a checkpoint should retain only its closed typed finding"
        )
        expect(
            artifact.bundle.verdict == .incomplete,
            "one scenario checkpoint without hardware cycles must stay incomplete"
        )
        let canonicalText = String(decoding: artifact.canonicalJSON, as: UTF8.self)
        for forbiddenKey in ["note", "path", "command", "operatorName"] {
            expect(
                !canonicalText.contains(forbiddenKey),
                "checkpoint evidence must not expose a free-form field"
            )
        }
    } catch {
        fatalError("CHECK FAILED: a closed Gate 1 checkpoint should record: \(error)")
    }
}

func gate1EvidenceOperatorCommandParserAcceptsOnlyClosedGrammar() {
    expect(
        Gate1EvidenceOperatorCommandParser.parse("status") == .success(.status),
        "the evidence tool should accept only its fixed status command"
    )
    expect(
        Gate1EvidenceOperatorCommandParser.parse("seal") == .success(.seal),
        "the evidence tool should accept only its fixed seal command"
    )
    expect(
        Gate1EvidenceOperatorCommandParser.parse(
            "checkpoint sleep confirmed"
        ) == .success(
            .checkpoint(
                Gate1OperatorCheckpoint(
                    kind: .sleep,
                    roundOrdinal: nil,
                    finding: .confirmed
                )
            )
        ),
        "scenario checkpoints should omit a round"
    )
    expect(
        Gate1EvidenceOperatorCommandParser.parse(
            "checkpoint systemInventoryComparison 7 notPerformed"
        ) == .success(
            .checkpoint(
                Gate1OperatorCheckpoint(
                    kind: .systemInventoryComparison,
                    roundOrdinal: 7,
                    finding: .notPerformed
                )
            )
        ),
        "comparison checkpoints should require a bounded round"
    )
    for invalid in [
        "checkpoint sleep 1 confirmed",
        "checkpoint systemInventoryComparison confirmed",
        "checkpoint mountTableComparison 0 confirmed",
        "checkpoint mountTableComparison 101 confirmed",
        "checkpoint sleep confirmed /tmp/raw.log",
        "run diskutil list",
        String(repeating: "x", count: 257),
        "",
    ] {
        expect(
            Gate1EvidenceOperatorCommandParser.parse(invalid) == .failure(.invalidCommand),
            "the evidence tool must reject free-form, malformed, or out-of-range input"
        )
    }
}

func gate1EvidenceInvalidCheckpointFailsClosedPermanently() async {
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "4", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )

    do {
        do {
            try await recorder.record(
                Gate1OperatorCheckpoint(
                    kind: .systemInventoryComparison,
                    roundOrdinal: nil,
                    finding: .confirmed
                ),
                at: GateEvidenceTimestamp(millisecondsSince1970: 70)
            )
            fatalError("CHECK FAILED: a missing comparison round must be rejected")
        } catch let error as Gate1EvidenceRecorderError {
            expect(
                error == .invalidCheckpoint,
                "invalid typed checkpoint should expose one fixed input error"
            )
        }
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 71)
        )
        expect(
            artifact.bundle.checkpoints.isEmpty
                && artifact.bundle.failureCodes == [.invalidCheckpoint]
                && artifact.bundle.verdict == .failedClosed,
            "a malformed checkpoint must leave no event and permanently fail closed"
        )
    } catch {
        fatalError("CHECK FAILED: invalid-checkpoint evidence should seal: \(error)")
    }
}

func gate1EvidenceBecomesReadyOnlyForHumanReviewAfterEveryRequirement() async {
    do {
        let fixture = try await gate1SyntheticCycleRecorder(
            evidenceID: gate1FixtureEvidenceID,
            cycleCount: 100
        )
        var timestamp = fixture.nextTimestamp
        let scenarioKinds: [Gate1CheckpointKind] = [
            .multiPartitionTopology,
            .sleep,
            .wakeResubscription,
            .applicationRestart,
            .declarationInvalidatedAfterReinsert,
            .declarationInvalidatedAfterWake,
            .declarationInvalidatedAfterRestart,
            .declarationInvalidatedAfterTopologyChange,
            .declarationInvalidatedAfterConsumption,
            .strictReleaseChecks,
            .readOnlyBoundaryReview,
        ]
        for kind in scenarioKinds {
            try await fixture.recorder.record(
                Gate1OperatorCheckpoint(
                    kind: kind,
                    roundOrdinal: nil,
                    finding: .confirmed
                ),
                at: GateEvidenceTimestamp(millisecondsSince1970: timestamp)
            )
            timestamp += 1
        }
        let artifact = try await fixture.recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: timestamp)
        )
        expect(
            artifact.bundle.cycleRequirementMet
                && artifact.bundle.checkpointRequirementMet,
            "review readiness requires both lifecycle and checkpoint coverage"
        )
        expect(
            artifact.bundle.openConnectionCount == 0,
            "review readiness requires every observed connection to have confirmed absence"
        )
        expect(
            artifact.bundle.verdict == .readyForHumanReview,
            "complete software evidence may only become ready for human review"
        )
        let canonicalText = String(decoding: artifact.canonicalJSON, as: UTF8.self)
        expect(
            !canonicalText.lowercased().contains("pass"),
            "even a review-ready evidence bundle must not contain an automatic pass result"
        )
        switch Gate1EvidenceArtifactVerifier.verify(
            canonicalJSON: artifact.canonicalJSON,
            expectedSHA256Digest: artifact.sha256Digest
        ) {
        case let .success(verified):
            expect(
                verified.bundle.verdict == .readyForHumanReview,
                "semantic replay should preserve only review readiness"
            )
        case let .failure(failure):
            fatalError("CHECK FAILED: review-ready evidence did not verify: \(failure)")
        }
    } catch {
        fatalError("CHECK FAILED: complete Gate 1 evidence should become review-ready: \(error)")
    }
}

func gate1EvidenceRequiresAFinalVerifiedObservationForReviewReadiness() async {
    do {
        let fixture = try await gate1SyntheticCycleRecorder(
            evidenceID: gate1FixtureEvidenceID,
            cycleCount: 100
        )
        var timestamp = fixture.nextTimestamp
        for kind in [
            Gate1CheckpointKind.multiPartitionTopology,
            .sleep,
            .wakeResubscription,
            .applicationRestart,
            .declarationInvalidatedAfterReinsert,
            .declarationInvalidatedAfterWake,
            .declarationInvalidatedAfterRestart,
            .declarationInvalidatedAfterTopologyChange,
            .declarationInvalidatedAfterConsumption,
            .strictReleaseChecks,
            .readOnlyBoundaryReview,
        ] {
            try await fixture.recorder.record(
                Gate1OperatorCheckpoint(
                    kind: kind,
                    roundOrdinal: nil,
                    finding: .confirmed
                ),
                at: GateEvidenceTimestamp(millisecondsSince1970: timestamp)
            )
            timestamp += 1
        }
        try await fixture.recorder.ingest(
            DiskInventoryObservation(
                physicalDisks: [],
                issues: [.enumerationCoverageUnverified]
            ),
            at: GateEvidenceTimestamp(millisecondsSince1970: timestamp)
        )
        timestamp += 1
        let artifact = try await fixture.recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: timestamp)
        )
        expect(
            artifact.bundle.failureCodes.isEmpty
                && artifact.bundle.observations.last?.coverage == .unverified,
            "an unverified final frame should remain explicit without fabricating a source failure"
        )
        expect(
            artifact.bundle.verdict == .incomplete,
            "review readiness must never survive an unverified final system observation"
        )
        switch Gate1EvidenceArtifactVerifier.verify(
            canonicalJSON: artifact.canonicalJSON,
            expectedSHA256Digest: artifact.sha256Digest
        ) {
        case let .success(verified):
            expect(
                verified.bundle.verdict == .incomplete,
                "the verifier must recompute final-observation readiness independently"
            )
        case let .failure(failure):
            fatalError("CHECK FAILED: final-unverified canonical evidence should verify incomplete: \(failure)")
        }
    } catch {
        fatalError("CHECK FAILED: final-unverified review evidence should seal: \(error)")
    }
}

func gate1EvidenceKeepsOnlyFixedIssueMeaningFromIncompleteObservations() async {
    let rawChild = "disk714s9"
    let base = await gate1UnknownCandidateObservation(
        diskBSDName: "disk714",
        volumeBSDName: "disk714s1",
        volumeUUID: "71400000-0000-0000-0000-000000000001",
        volumeName: "ISSUE-POISON",
        mountPoint: "/Volumes/ISSUE-POISON"
    )
    guard let baseDisk = base.physicalDisks.first,
          let baseVolume = baseDisk.volumes.first
    else {
        fatalError("CHECK FAILED: issue fixture should contain one disk and volume")
    }
    let incomplete = DiskInventoryObservation(
        physicalDisks: [
            ReadOnlyPhysicalDiskRecord(
                instanceID: baseDisk.instanceID,
                description: baseDisk.description,
                volumes: [
                    ReadOnlyVolumeRecord(
                        evidence: baseVolume.evidence,
                        candidate: baseVolume.candidate,
                        snapshot: nil,
                        mountObservation: nil,
                        issues: [.unknownVolumeRole, .sourceDeviceMismatch]
                    ),
                ],
                issues: [.childLocationMismatch(bsdName: rawChild)]
            ),
        ],
        issues: [.missingPhysicalDiskDescription(childBSDName: rawChild)]
    )
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "1", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )

    do {
        try await recorder.ingest(
            incomplete,
            at: GateEvidenceTimestamp(millisecondsSince1970: 700)
        )
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 701)
        )
        guard let frame = artifact.bundle.observations.first,
              let disk = frame.disks.first
        else {
            fatalError("CHECK FAILED: incomplete evidence should retain its anonymous frame")
        }
        expect(
            frame.coverage == .unverified
                && frame.issueCodes == [.missingPhysicalDiskDescription],
            "top-level incompleteness should retain only its fixed issue meaning"
        )
        expect(
            disk.issueCodes == [
                .childLocationMismatch,
                .sourceDeviceMismatch,
                .unknownVolumeRole,
            ],
            "disk and volume problems should be deduplicated and sorted as fixed codes"
        )
        expect(
            artifact.bundle.completedCycleCount == 0,
            "an incomplete frame must not complete a lifecycle"
        )
        let canonicalText = String(decoding: artifact.canonicalJSON, as: UTF8.self)
        for rawValue in [
            rawChild,
            "disk714",
            "71400000-0000-0000-0000-000000000001",
            "ISSUE-POISON",
            "/Volumes/ISSUE-POISON",
        ] {
            expect(
                !canonicalText.contains(rawValue),
                "associated issue parameters and source identities must be discarded"
            )
        }
    } catch {
        fatalError("CHECK FAILED: fixed Gate 1 issue evidence should record: \(error)")
    }
}

func gate1EvidenceObservationLimitFailsClosedWithoutEvictingOldEvidence() async {
    let observation = await gate1UnknownCandidateObservation(
        diskBSDName: "disk715",
        volumeBSDName: "disk715s1",
        volumeUUID: "71500000-0000-0000-0000-000000000001",
        volumeName: "LIMIT",
        mountPoint: "/Volumes/LIMIT"
    )
    let policy = try! Gate1EvidencePolicy(
        maxObservations: 1,
        maxCheckpoints: 1,
        maxDisksPerObservation: 4,
        maxVolumesPerDisk: 4,
        maxEncodedBytes: 64 * 1_024
    )
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "2", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        ),
        policy: policy
    )

    do {
        try await recorder.ingest(
            observation,
            at: GateEvidenceTimestamp(millisecondsSince1970: 800)
        )
        do {
            try await recorder.ingest(
                observation,
                at: GateEvidenceTimestamp(millisecondsSince1970: 801)
            )
            fatalError("CHECK FAILED: a second frame must exceed the configured limit")
        } catch let error as Gate1EvidenceRecorderError {
            expect(
                error == .observationLimitExceeded,
                "the rejected frame should expose its fixed capacity error"
            )
        }
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 802)
        )
        expect(
            artifact.bundle.observations.count == 1,
            "capacity failure must retain the original frame without eviction or partial append"
        )
        expect(
            artifact.bundle.verdict == .failedClosed
                && artifact.bundle.failureCodes == [.observationLimitExceeded],
            "a caught capacity error must remain permanently failed closed"
        )
    } catch {
        fatalError("CHECK FAILED: bounded Gate 1 evidence should seal: \(error)")
    }
}

func gate1EvidencePolicyRejectsZeroAndUnsealableBudgets() {
    func rejects(
        maxObservations: Int = 1,
        maxEncodedBytes: Int = Gate1EvidencePolicy.minimumEncodedBytes
    ) -> Bool {
        do {
            _ = try Gate1EvidencePolicy(
                maxObservations: maxObservations,
                maxCheckpoints: 1,
                maxDisksPerObservation: 1,
                maxVolumesPerDisk: 1,
                maxEncodedBytes: maxEncodedBytes
            )
            return false
        } catch let error as Gate1EvidencePolicyError {
            return error == .invalidLimit
        } catch {
            return false
        }
    }
    expect(
        rejects(maxObservations: 0),
        "every evidence count limit must be positive"
    )
    expect(
        rejects(maxEncodedBytes: Gate1EvidencePolicy.minimumEncodedBytes - 1),
        "the byte policy must leave room for a minimal failed-closed artifact"
    )
    expect(
        (try? Gate1EvidencePolicy(
            maxObservations: 1,
            maxCheckpoints: 1,
            maxDisksPerObservation: 1,
            maxVolumesPerDisk: 1,
            maxEncodedBytes: Gate1EvidencePolicy.minimumEncodedBytes
        )) != nil,
        "the documented minimum byte budget should be usable"
    )
    let hardMaximums = Gate1EvidencePolicy.default
    expect(
        (try? Gate1EvidencePolicy(
            maxObservations: hardMaximums.maxObservations + 1,
            maxCheckpoints: hardMaximums.maxCheckpoints,
            maxDisksPerObservation: hardMaximums.maxDisksPerObservation,
            maxVolumesPerDisk: hardMaximums.maxVolumesPerDisk,
            maxEncodedBytes: hardMaximums.maxEncodedBytes
        )) == nil,
        "a caller must not weaken the verifier's hard observation ceiling"
    )
    expect(
        (try? Gate1EvidencePolicy(
            maxObservations: hardMaximums.maxObservations,
            maxCheckpoints: hardMaximums.maxCheckpoints,
            maxDisksPerObservation: hardMaximums.maxDisksPerObservation,
            maxVolumesPerDisk: hardMaximums.maxVolumesPerDisk,
            maxEncodedBytes: hardMaximums.maxEncodedBytes + 1
        )) == nil,
        "a caller must not create evidence larger than the default verifier admits"
    )
}

func gate1EvidenceRejectsComparisonCheckpointsOutsideTheirTargetCycle() async {
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "2", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )
    do {
        try await recorder.record(
            Gate1OperatorCheckpoint(
                kind: .systemInventoryComparison,
                roundOrdinal: 1,
                finding: .confirmed
            ),
            at: GateEvidenceTimestamp(millisecondsSince1970: 1)
        )
        fatalError("CHECK FAILED: a round comparison before target presence must be rejected")
    } catch let error as Gate1EvidenceRecorderError {
        expect(
            error == .invalidCheckpoint,
            "a comparison outside its target lifecycle should use the closed checkpoint error"
        )
    } catch {
        fatalError("CHECK FAILED: premature comparison used an unexpected error: \(error)")
    }
}

func gate1EvidenceDoesNotAggregateDifferentReviewableDisksIntoCycles() async {
    let first = await gate1UnknownCandidateObservation(
        diskBSDName: "disk731",
        volumeBSDName: "disk731s1",
        volumeUUID: "73100000-0000-0000-0000-000000000001",
        volumeName: "FIRST-TARGET",
        mountPoint: "/Volumes/FIRST-TARGET"
    )
    let second = await gate1UnknownCandidateObservation(
        diskBSDName: "disk732",
        volumeBSDName: "disk732s1",
        volumeUUID: "73200000-0000-0000-0000-000000000001",
        volumeName: "SECOND-TARGET",
        mountPoint: "/Volumes/SECOND-TARGET"
    )
    let simultaneous = DiskInventoryObservation(
        physicalDisks: first.physicalDisks + second.physicalDisks,
        issues: []
    )
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "3", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )
    do {
        try await recorder.ingest(
            simultaneous,
            at: GateEvidenceTimestamp(millisecondsSince1970: 1)
        )
        try await recorder.ingest(
            DiskInventoryObservation(physicalDisks: [], issues: []),
            at: GateEvidenceTimestamp(millisecondsSince1970: 2)
        )
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 3)
        )
        expect(
            artifact.bundle.completedCycleCount <= 1,
            "different physical disks must never be aggregated toward one 100-cycle target"
        )
        expect(
            artifact.bundle.verdict != .readyForHumanReview,
            "ambiguous target evidence must never become review-ready"
        )
    } catch let error as Gate1EvidenceRecorderError {
        expect(
            error == .topologyContradiction,
            "multiple reviewable targets should fail through a fixed closed topology error"
        )
    } catch {
        fatalError("CHECK FAILED: multiple-target evidence used an unexpected error: \(error)")
    }
}

func gate1EvidenceRejectsDuplicateVolumeTopologyAtomically() async {
    let base = await gate1UnknownCandidateObservation(
        diskBSDName: "disk733",
        volumeBSDName: "disk733s1",
        volumeUUID: "73300000-0000-0000-0000-000000000001",
        volumeName: "DUPLICATE-VOLUME",
        mountPoint: "/Volumes/DUPLICATE-VOLUME"
    )
    guard let disk = base.physicalDisks.first,
          let volume = disk.volumes.first
    else {
        fatalError("CHECK FAILED: duplicate-volume fixture needs one source volume")
    }
    let duplicate = DiskInventoryObservation(
        physicalDisks: [
            ReadOnlyPhysicalDiskRecord(
                instanceID: disk.instanceID,
                description: disk.description,
                volumes: [volume, volume],
                issues: disk.issues
            ),
        ],
        issues: []
    )
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "4", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )
    do {
        try await recorder.ingest(
            duplicate,
            at: GateEvidenceTimestamp(millisecondsSince1970: 1)
        )
        fatalError("CHECK FAILED: duplicate volume identities must be rejected atomically")
    } catch let error as Gate1EvidenceRecorderError {
        expect(
            error == .topologyContradiction,
            "duplicate volumes should use the fixed topology contradiction error"
        )
    } catch {
        fatalError("CHECK FAILED: duplicate volume used an unexpected error: \(error)")
    }
}

func gate1EvidenceRejectsCaseAliasedTypedVolumeTopology() async {
    let base = await gate1UnknownCandidateObservation(
        diskBSDName: "disk738",
        volumeBSDName: "disk738s1",
        volumeUUID: "abcdef12-3456-7890-abcd-ef1234567890",
        volumeName: "CASE-ALIASED-VOLUME",
        mountPoint: "/Volumes/CASE-ALIASED-VOLUME"
    )
    guard let disk = base.physicalDisks.first,
          let volume = disk.volumes.first,
          let candidate = volume.candidate
    else {
        fatalError("CHECK FAILED: case-alias fixture needs one candidate volume")
    }
    let aliasedCandidate = ReadOnlyVolumeCandidate(
        id: VolumeID(
            uuid: candidate.id.uuid.uppercased(),
            bsdName: candidate.id.bsdName
        ),
        physicalDiskID: candidate.physicalDiskID,
        mediaGeneration: candidate.mediaGeneration,
        displayName: candidate.displayName,
        fileSystem: candidate.fileSystem,
        location: candidate.location,
        mountAccess: candidate.mountAccess
    )
    let aliasedVolume = ReadOnlyVolumeRecord(
        evidence: volume.evidence,
        candidate: aliasedCandidate,
        snapshot: nil,
        mountObservation: volume.mountObservation,
        issues: volume.issues
    )
    let duplicate = DiskInventoryObservation(
        physicalDisks: [
            ReadOnlyPhysicalDiskRecord(
                instanceID: disk.instanceID,
                description: disk.description,
                volumes: [volume, aliasedVolume],
                issues: disk.issues
            ),
        ],
        issues: []
    )
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "4", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )
    do {
        try await recorder.ingest(
            duplicate,
            at: GateEvidenceTimestamp(millisecondsSince1970: 1)
        )
        fatalError(
            "CHECK FAILED: UUID-case aliases of one typed volume must be rejected atomically"
        )
    } catch let error as Gate1EvidenceRecorderError {
        expect(
            error == .topologyContradiction,
            "typed UUID-case aliases should use the fixed topology contradiction error"
        )
    } catch {
        fatalError("CHECK FAILED: UUID-case alias used an unexpected error: \(error)")
    }
}

func gate1EvidenceDoesNotCountMediaAlreadyPresentAtSessionStart() async {
    let present = await gate1UnknownCandidateObservation(
        diskBSDName: "disk734",
        volumeBSDName: "disk734s1",
        volumeUUID: "73400000-0000-0000-0000-000000000001",
        volumeName: "PRESENT-AT-START",
        mountPoint: "/Volumes/PRESENT-AT-START"
    )
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "5", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )
    do {
        try await recorder.ingest(
            present,
            at: GateEvidenceTimestamp(millisecondsSince1970: 1)
        )
        try await recorder.ingest(
            DiskInventoryObservation(physicalDisks: [], issues: []),
            at: GateEvidenceTimestamp(millisecondsSince1970: 2)
        )
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 3)
        )
        expect(
            artifact.bundle.completedCycleCount == 0,
            "a disk already present when capture starts must be a calibration removal, not cycle one"
        )
    } catch {
        fatalError("CHECK FAILED: startup-present calibration should record: \(error)")
    }
}

func gate1EvidenceCountsPendingThenVerifiedInsertionExactlyOnce() async {
    let present = await gate1UnknownCandidateObservation(
        diskBSDName: "disk735",
        volumeBSDName: "disk735s1",
        volumeUUID: "73500000-0000-0000-0000-000000000001",
        volumeName: "PENDING-INSERTION",
        mountPoint: "/Volumes/PENDING-INSERTION"
    )
    let pending = DiskInventoryObservation(
        physicalDisks: present.physicalDisks,
        issues: [.enumerationCoverageUnverified]
    )
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "6", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )
    do {
        try await recorder.ingest(
            DiskInventoryObservation(physicalDisks: [], issues: []),
            at: GateEvidenceTimestamp(millisecondsSince1970: 1)
        )
        try await recorder.ingest(
            pending,
            at: GateEvidenceTimestamp(millisecondsSince1970: 2)
        )
        try await recorder.ingest(
            present,
            at: GateEvidenceTimestamp(millisecondsSince1970: 3)
        )
        try await recorder.ingest(
            DiskInventoryObservation(
                physicalDisks: [],
                issues: [.enumerationCoverageUnverified]
            ),
            at: GateEvidenceTimestamp(millisecondsSince1970: 4)
        )
        try await recorder.ingest(
            DiskInventoryObservation(physicalDisks: [], issues: []),
            at: GateEvidenceTimestamp(millisecondsSince1970: 5)
        )
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 6)
        )
        expect(
            artifact.bundle.completedCycleCount == 1,
            "pending observer frames must neither consume nor invalidate the verified lifecycle"
        )
        switch Gate1EvidenceArtifactVerifier.verify(
            canonicalJSON: artifact.canonicalJSON,
            expectedSHA256Digest: artifact.sha256Digest
        ) {
        case .success:
            break
        case let .failure(failure):
            fatalError("CHECK FAILED: pending observer evidence did not verify: \(failure)")
        }
    } catch {
        fatalError("CHECK FAILED: pending-to-verified lifecycle should record: \(error)")
    }
}

func gate1EvidenceIgnoresPermanentNonTargetConnectionsForReadiness() async {
    let target = await gate1UnknownCandidateObservation(
        diskBSDName: "disk736",
        volumeBSDName: "disk736s1",
        volumeUUID: "73600000-0000-0000-0000-000000000001",
        volumeName: "TARGET-WITH-INTERNAL",
        mountPoint: "/Volumes/TARGET-WITH-INTERNAL"
    )
    guard let targetDisk = target.physicalDisks.first else {
        fatalError("CHECK FAILED: permanent-disk fixture needs a target")
    }
    let permanentDisk = ReadOnlyPhysicalDiskRecord(
        instanceID: DiskInstanceID(
            physicalDiskID: PhysicalDiskID(rawValue: "disk0"),
            mediaGeneration: MediaGeneration(rawValue: 1)
        ),
        description: DiskArbitrationDescription(
            bsdName: "disk0",
            physicalDiskBSDName: "disk0",
            isWholeDisk: true,
            isInternal: true,
            isEjectable: false,
            isRemovable: false,
            mediaSize: 1_000_000,
            mediaUUID: "00000000-0000-0000-0000-000000000000",
            volumeUUID: nil,
            volumeName: nil,
            fileSystemName: nil,
            mountPoint: nil
        ),
        volumes: [],
        issues: []
    )
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "7", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )
    do {
        try await recorder.ingest(
            DiskInventoryObservation(physicalDisks: [permanentDisk], issues: []),
            at: GateEvidenceTimestamp(millisecondsSince1970: 1)
        )
        try await recorder.ingest(
            DiskInventoryObservation(
                physicalDisks: [permanentDisk, targetDisk],
                issues: []
            ),
            at: GateEvidenceTimestamp(millisecondsSince1970: 2)
        )
        try await recorder.ingest(
            DiskInventoryObservation(physicalDisks: [permanentDisk], issues: []),
            at: GateEvidenceTimestamp(millisecondsSince1970: 3)
        )
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 4)
        )
        expect(
            artifact.bundle.completedCycleCount == 1
                && artifact.bundle.openConnectionCount == 0,
            "a permanent internal connection must not block target absence or count as a cycle"
        )
    } catch {
        fatalError("CHECK FAILED: target plus permanent disk should record: \(error)")
    }
}

func gate1EvidenceSourceTerminationIsPermanentlyFailedClosed() async {
    for (failure, expectedCode) in [
        (Gate1EvidenceSourceFailure.eventQueueOverflow,
         Gate1EvidenceFailureCode.eventQueueOverflow),
        (Gate1EvidenceSourceFailure.observationStreamEnded,
         Gate1EvidenceFailureCode.observationStreamEnded),
        (.finalObservationUnverified, .finalObservationUnverified),
        (.unclassifiedObservationFailure, .unclassifiedObservationFailure),
        (.unclassifiedOperatorFailure, .unclassifiedOperatorFailure),
    ] {
        let recorder = Gate1EvidenceRecorder(
            header: try! Gate1EvidenceHeader(
                evidenceID: gate1FixtureEvidenceID,
                applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
                applicationBuild: 1,
                applicationSHA256: String(repeating: "8", count: 64),
                macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
            )
        )
        do {
            try await recorder.failClosed(
                failure,
                at: GateEvidenceTimestamp(millisecondsSince1970: 1)
            )
            let artifact = try await recorder.seal(
                at: GateEvidenceTimestamp(millisecondsSince1970: 2)
            )
            expect(
                artifact.bundle.failureCodes == [expectedCode]
                    && artifact.bundle.verdict == .failedClosed,
                "every external source termination must retain one fixed failure code"
            )
        } catch {
            fatalError("CHECK FAILED: source termination should seal failed closed: \(error)")
        }
    }
}

func gate1EvidenceRejectsEveryEventAfterPermanentFailure() async {
    let observation = await gate1UnknownCandidateObservation(
        diskBSDName: "disk722",
        volumeBSDName: "disk722s1",
        volumeUUID: "72200000-0000-0000-0000-000000000001",
        volumeName: "PERMANENT-FAILURE",
        mountPoint: "/Volumes/PERMANENT-FAILURE"
    )
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "d", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        ),
        policy: try! Gate1EvidencePolicy(
            maxObservations: 1,
            maxCheckpoints: 2,
            maxDisksPerObservation: 2,
            maxVolumesPerDisk: 2,
            maxEncodedBytes: 64 * 1_024
        )
    )

    do {
        try await recorder.ingest(
            observation,
            at: GateEvidenceTimestamp(millisecondsSince1970: 840)
        )
        do {
            try await recorder.ingest(
                observation,
                at: GateEvidenceTimestamp(millisecondsSince1970: 841)
            )
            fatalError("CHECK FAILED: capacity fixture should enter failed-closed state")
        } catch let error as Gate1EvidenceRecorderError {
            expect(error == .observationLimitExceeded, "fixture should fail by capacity")
        }
        do {
            try await recorder.record(
                Gate1OperatorCheckpoint(
                    kind: .sleep,
                    roundOrdinal: nil,
                    finding: .confirmed
                ),
                at: GateEvidenceTimestamp(millisecondsSince1970: 842)
            )
            fatalError("CHECK FAILED: failed recorder must reject later checkpoints")
        } catch let error as Gate1EvidenceRecorderError {
            expect(
                error == .failedClosed,
                "every post-failure event should receive the permanent state error"
            )
        }
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 843)
        )
        expect(
            artifact.bundle.checkpoints.isEmpty
                && artifact.bundle.failureCodes == [.observationLimitExceeded],
            "later events must not mutate the first permanent failure artifact"
        )
    } catch {
        fatalError("CHECK FAILED: permanently failed Gate 1 evidence should seal: \(error)")
    }
}

func gate1EvidenceTimestampRegressionFailsClosedPermanently() async {
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "e", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )

    do {
        try await recorder.record(
            Gate1OperatorCheckpoint(
                kind: .sleep,
                roundOrdinal: nil,
                finding: .confirmed
            ),
            at: GateEvidenceTimestamp(millisecondsSince1970: 850)
        )
        do {
            try await recorder.record(
                Gate1OperatorCheckpoint(
                    kind: .wakeResubscription,
                    roundOrdinal: nil,
                    finding: .confirmed
                ),
                at: GateEvidenceTimestamp(millisecondsSince1970: 849)
            )
            fatalError("CHECK FAILED: timestamp regression must be rejected")
        } catch let error as Gate1EvidenceRecorderError {
            expect(
                error == .nonMonotonicTimestamp,
                "timestamp regression should expose one fixed input error"
            )
        }
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 851)
        )
        expect(
            artifact.bundle.failureCodes == [.nonMonotonicTimestamp]
                && artifact.bundle.verdict == .failedClosed,
            "a caught timestamp regression must remain permanently failed closed"
        )
        expect(
            artifact.bundle.checkpoints.count == 1,
            "the regressed event must not enter the canonical timeline"
        )
    } catch {
        fatalError("CHECK FAILED: timestamp-regressed evidence should seal: \(error)")
    }
}

func gate1EvidenceCheckpointLimitFailsClosedWithoutEvictingOldEvidence() async {
    let policy = try! Gate1EvidencePolicy(
        maxObservations: 1,
        maxCheckpoints: 1,
        maxDisksPerObservation: 4,
        maxVolumesPerDisk: 4,
        maxEncodedBytes: 64 * 1_024
    )
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "3", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        ),
        policy: policy
    )
    let checkpoint = Gate1OperatorCheckpoint(
        kind: .sleep,
        roundOrdinal: nil,
        finding: .confirmed
    )

    do {
        try await recorder.record(
            checkpoint,
            at: GateEvidenceTimestamp(millisecondsSince1970: 810)
        )
        do {
            try await recorder.record(
                checkpoint,
                at: GateEvidenceTimestamp(millisecondsSince1970: 811)
            )
            fatalError("CHECK FAILED: a second checkpoint must exceed the configured limit")
        } catch let error as Gate1EvidenceRecorderError {
            expect(
                error == .checkpointLimitExceeded,
                "the rejected checkpoint should expose its fixed capacity error"
            )
        }
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 812)
        )
        expect(
            artifact.bundle.checkpoints.count == 1,
            "checkpoint capacity failure must retain the original event without eviction"
        )
        expect(
            artifact.bundle.verdict == .failedClosed
                && artifact.bundle.failureCodes == [.checkpointLimitExceeded],
            "a checkpoint capacity failure must remain permanently failed closed"
        )
    } catch {
        fatalError("CHECK FAILED: bounded Gate 1 checkpoints should seal: \(error)")
    }
}

func gate1EvidenceDiskLimitRejectsTheWholeObservationAtomically() async {
    let first = await gate1UnknownCandidateObservation(
        diskBSDName: "disk716",
        volumeBSDName: "disk716s1",
        volumeUUID: "71600000-0000-0000-0000-000000000001",
        volumeName: "DISK-LIMIT-A",
        mountPoint: "/Volumes/DISK-LIMIT-A"
    )
    let second = await gate1UnknownCandidateObservation(
        diskBSDName: "disk717",
        volumeBSDName: "disk717s1",
        volumeUUID: "71700000-0000-0000-0000-000000000001",
        volumeName: "DISK-LIMIT-B",
        mountPoint: "/Volumes/DISK-LIMIT-B"
    )
    let oversized = DiskInventoryObservation(
        physicalDisks: first.physicalDisks + second.physicalDisks,
        issues: []
    )
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "4", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        ),
        policy: try! Gate1EvidencePolicy(
            maxObservations: 2,
            maxCheckpoints: 2,
            maxDisksPerObservation: 1,
            maxVolumesPerDisk: 4,
            maxEncodedBytes: 64 * 1_024
        )
    )

    do {
        do {
            try await recorder.ingest(
                oversized,
                at: GateEvidenceTimestamp(millisecondsSince1970: 820)
            )
            fatalError("CHECK FAILED: an oversized disk frame must be rejected")
        } catch let error as Gate1EvidenceRecorderError {
            expect(
                error == .diskLimitExceeded,
                "the rejected disk frame should expose its fixed capacity error"
            )
        }
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 821)
        )
        expect(
            artifact.bundle.observations.isEmpty
                && artifact.bundle.openConnectionCount == 0,
            "disk capacity failure must not commit aliases, connections, or a partial frame"
        )
        expect(
            artifact.bundle.failureCodes == [.diskLimitExceeded]
                && artifact.bundle.verdict == .failedClosed,
            "disk capacity failure must remain permanently failed closed"
        )
    } catch {
        fatalError("CHECK FAILED: disk-limited Gate 1 evidence should seal: \(error)")
    }
}

func gate1EvidenceRejectsDuplicatePhysicalDiskTopologyAtomically() async {
    let base = await gate1UnknownCandidateObservation(
        diskBSDName: "disk725",
        volumeBSDName: "disk725s1",
        volumeUUID: "72500000-0000-0000-0000-000000000001",
        volumeName: "DUPLICATE-TOPOLOGY",
        mountPoint: "/Volumes/DUPLICATE-TOPOLOGY"
    )
    guard let disk = base.physicalDisks.first else {
        fatalError("CHECK FAILED: topology fixture should contain one disk")
    }
    let duplicate = DiskInventoryObservation(
        physicalDisks: [disk, disk],
        issues: []
    )
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "2", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )

    do {
        do {
            try await recorder.ingest(
                duplicate,
                at: GateEvidenceTimestamp(millisecondsSince1970: 860)
            )
            fatalError("CHECK FAILED: duplicate physical topology must be rejected")
        } catch let error as Gate1EvidenceRecorderError {
            expect(
                error == .topologyContradiction,
                "duplicate topology should expose one fixed contradiction error"
            )
        }
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 861)
        )
        expect(
            artifact.bundle.observations.isEmpty
                && artifact.bundle.openConnectionCount == 0,
            "a topology contradiction must not partially create aliases or connections"
        )
        expect(
            artifact.bundle.failureCodes == [.topologyContradiction]
                && artifact.bundle.verdict == .failedClosed,
            "duplicate physical topology must remain permanently failed closed"
        )
    } catch {
        fatalError("CHECK FAILED: duplicate-topology evidence should seal: \(error)")
    }
}

func gate1EvidenceVolumeLimitRejectsTheWholeObservationAtomically() async {
    let base = await gate1UnknownCandidateObservation(
        diskBSDName: "disk718",
        volumeBSDName: "disk718s1",
        volumeUUID: "71800000-0000-0000-0000-000000000001",
        volumeName: "VOLUME-LIMIT",
        mountPoint: "/Volumes/VOLUME-LIMIT"
    )
    guard let disk = base.physicalDisks.first,
          let volume = disk.volumes.first
    else {
        fatalError("CHECK FAILED: volume limit fixture should contain one volume")
    }
    let oversized = DiskInventoryObservation(
        physicalDisks: [
            ReadOnlyPhysicalDiskRecord(
                instanceID: disk.instanceID,
                description: disk.description,
                volumes: [volume, volume],
                issues: disk.issues
            ),
        ],
        issues: []
    )
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "5", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        ),
        policy: try! Gate1EvidencePolicy(
            maxObservations: 2,
            maxCheckpoints: 2,
            maxDisksPerObservation: 2,
            maxVolumesPerDisk: 1,
            maxEncodedBytes: 64 * 1_024
        )
    )

    do {
        do {
            try await recorder.ingest(
                oversized,
                at: GateEvidenceTimestamp(millisecondsSince1970: 830)
            )
            fatalError("CHECK FAILED: an oversized volume frame must be rejected")
        } catch let error as Gate1EvidenceRecorderError {
            expect(
                error == .volumeLimitExceeded,
                "the rejected volume frame should expose its fixed capacity error"
            )
        }
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 831)
        )
        expect(
            artifact.bundle.observations.isEmpty
                && artifact.bundle.openConnectionCount == 0,
            "volume capacity failure must not commit aliases, connections, or a partial frame"
        )
        expect(
            artifact.bundle.failureCodes == [.volumeLimitExceeded]
                && artifact.bundle.verdict == .failedClosed,
            "volume capacity failure must remain permanently failed closed"
        )
    } catch {
        fatalError("CHECK FAILED: volume-limited Gate 1 evidence should seal: \(error)")
    }
}

func gate1EvidenceEncodedByteLimitFailsClosedWithoutOversizedOutput() async {
    let observation = await gate1UnknownCandidateObservation(
        diskBSDName: "disk719",
        volumeBSDName: "disk719s1",
        volumeUUID: "71900000-0000-0000-0000-000000000001",
        volumeName: "ENCODED-LIMIT",
        mountPoint: "/Volumes/ENCODED-LIMIT"
    )
    let maxEncodedBytes = 4 * 1_024
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "6", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        ),
        policy: try! Gate1EvidencePolicy(
            maxObservations: 100,
            maxCheckpoints: 2,
            maxDisksPerObservation: 2,
            maxVolumesPerDisk: 2,
            maxEncodedBytes: maxEncodedBytes
        )
    )

    var acceptedCount = 0
    do {
        for offset in 0 ..< 100 {
            do {
                try await recorder.ingest(
                    observation,
                    at: GateEvidenceTimestamp(
                        millisecondsSince1970: Int64(900 + offset)
                    )
                )
                acceptedCount += 1
            } catch let error as Gate1EvidenceRecorderError {
                expect(
                    error == .encodedByteLimitExceeded,
                    "encoded growth should expose its fixed capacity error"
                )
                break
            }
        }
        expect(
            acceptedCount > 0 && acceptedCount < 100,
            "the fixture should fill the byte budget after retaining earlier frames"
        )
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 1_100)
        )
        expect(
            artifact.bundle.observations.count == acceptedCount,
            "encoded capacity failure must reject only the oversized frame"
        )
        expect(
            artifact.canonicalJSON.count <= maxEncodedBytes,
            "even a failed-closed artifact must remain within its declared byte budget"
        )
        expect(
            artifact.bundle.failureCodes == [.encodedByteLimitExceeded]
                && artifact.bundle.verdict == .failedClosed,
            "encoded capacity failure must remain permanently failed closed"
        )
    } catch {
        fatalError("CHECK FAILED: byte-limited Gate 1 evidence should seal: \(error)")
    }
}

func gate1EvidenceVerifierAdmitsOnlyTheMatchingCanonicalArtifact() async {
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "7", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )

    do {
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 1_200)
        )
        switch Gate1EvidenceArtifactVerifier.verify(
            canonicalJSON: artifact.canonicalJSON,
            expectedSHA256Digest: artifact.sha256Digest
        ) {
        case let .success(verified):
            expect(
                verified == artifact,
                "the verifier should admit the exact recorder artifact"
            )
        case let .failure(failure):
            fatalError("CHECK FAILED: canonical Gate 1 evidence rejected: \(failure)")
        }

        switch Gate1EvidenceArtifactVerifier.verify(
            canonicalJSON: artifact.canonicalJSON,
            expectedSHA256Digest: String(repeating: "0", count: 64)
        ) {
        case .success:
            fatalError("CHECK FAILED: mismatched evidence digest must be rejected")
        case let .failure(failure):
            expect(
                failure == .digestMismatch,
                "a mismatched digest should have one fixed rejection reason"
            )
        }
    } catch {
        fatalError("CHECK FAILED: canonical Gate 1 evidence should seal: \(error)")
    }
}

func gate1EvidenceSealIsIdempotentAndClosesEveryInput() async {
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "3", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )

    do {
        let first = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 1_205)
        )
        let repeated = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 9_999)
        )
        expect(
            repeated == first,
            "repeated seal must return the exact first immutable artifact"
        )
        do {
            try await recorder.record(
                Gate1OperatorCheckpoint(
                    kind: .sleep,
                    roundOrdinal: nil,
                    finding: .confirmed
                ),
                at: GateEvidenceTimestamp(millisecondsSince1970: 10_000)
            )
            fatalError("CHECK FAILED: sealed evidence must reject every new event")
        } catch let error as Gate1EvidenceRecorderError {
            expect(error == .sealed, "sealed input should expose one fixed state error")
        }
        let status = await recorder.status()
        expect(
            status.phase == .sealed,
            "idempotent seal should leave the recorder in its terminal phase"
        )
    } catch {
        fatalError("CHECK FAILED: idempotent evidence should seal: \(error)")
    }
}

func gate1EvidenceVerifierRejectsDuplicateJSONMembersBeforeDecoding() async {
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "8", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )

    do {
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 1_210)
        )
        var duplicateBytes = Array(artifact.canonicalJSON)
        duplicateBytes.insert(
            contentsOf: Array("\"schemaVersion\":2,".utf8),
            at: 1
        )
        let duplicateJSON = Data(duplicateBytes)
        let duplicateDigest = SHA256.hash(data: duplicateJSON)
            .map { String(format: "%02x", $0) }
            .joined()

        switch Gate1EvidenceArtifactVerifier.verify(
            canonicalJSON: duplicateJSON,
            expectedSHA256Digest: duplicateDigest
        ) {
        case .success:
            fatalError("CHECK FAILED: duplicate JSON member must be rejected")
        case let .failure(failure):
            expect(
                failure == .malformedJSON,
                "duplicate members must fail in the strict grammar before typed decoding"
            )
        }
    } catch {
        fatalError("CHECK FAILED: duplicate-member fixture should seal: \(error)")
    }
}

func gate1EvidenceVerifierRejectsUnknownSchemaFieldsAndInvalidHeader() async {
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "5", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )
    func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func rejection(
        for data: Data
    ) -> Gate1EvidenceVerificationFailure? {
        switch Gate1EvidenceArtifactVerifier.verify(
            canonicalJSON: data,
            expectedSHA256Digest: digest(data)
        ) {
        case .success:
            nil
        case let .failure(failure):
            failure
        }
    }

    do {
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 1_215)
        )
        var unknownBytes = Array(artifact.canonicalJSON)
        unknownBytes.insert(contentsOf: Array("\"aaaUnknown\":0,".utf8), at: 1)
        expect(
            rejection(for: Data(unknownBytes)) == .nonCanonical,
            "an unknown sorted field must not survive typed canonical re-encoding"
        )

        let original = String(decoding: artifact.canonicalJSON, as: UTF8.self)
        let unsupportedSchema = Data(
            original.replacingOccurrences(
                of: "\"schemaVersion\":2",
                with: "\"schemaVersion\":3"
            ).utf8
        )
        expect(
            rejection(for: unsupportedSchema) == .unsupportedSchema,
            "an unknown evidence schema must be rejected explicitly"
        )
        let invalidHeader = Data(
            original.replacingOccurrences(
                of: "\"applicationBuild\":1",
                with: "\"applicationBuild\":0"
            ).utf8
        )
        expect(
            rejection(for: invalidHeader) == .invalidBundle,
            "decoded header values must be revalidated instead of trusting synthesis"
        )
    } catch {
        fatalError("CHECK FAILED: schema fixture should seal: \(error)")
    }
}

func gate1EvidenceVerifierRecomputesDerivedVerdict() async {
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "9", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )

    do {
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 1_220)
        )
        let original = String(decoding: artifact.canonicalJSON, as: UTF8.self)
        let forged = original.replacingOccurrences(
            of: "\"verdict\":\"incomplete\"",
            with: "\"verdict\":\"readyForHumanReview\""
        )
        expect(forged != original, "the verdict fixture should change one derived field")
        let forgedJSON = Data(forged.utf8)
        let forgedDigest = SHA256.hash(data: forgedJSON)
            .map { String(format: "%02x", $0) }
            .joined()

        switch Gate1EvidenceArtifactVerifier.verify(
            canonicalJSON: forgedJSON,
            expectedSHA256Digest: forgedDigest
        ) {
        case .success:
            fatalError("CHECK FAILED: a forged review verdict must be rejected")
        case let .failure(failure):
            expect(
                failure == .invalidBundle,
                "derived verdict forgery should fail semantic replay"
            )
        }
    } catch {
        fatalError("CHECK FAILED: verdict fixture should seal: \(error)")
    }
}

func gate1EvidenceVerifierReplaysEventsInsteadOfTrustingSummaries() async {
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "a", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )

    do {
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 1_230)
        )
        let original = String(decoding: artifact.canonicalJSON, as: UTF8.self)
        let forged = original
            .replacingOccurrences(
                of: "\"completedCycleCount\":0",
                with: "\"completedCycleCount\":100"
            )
            .replacingOccurrences(
                of: "\"cycleRequirementMet\":false",
                with: "\"cycleRequirementMet\":true"
            )
            .replacingOccurrences(
                of: "\"checkpointRequirementMet\":false",
                with: "\"checkpointRequirementMet\":true"
            )
            .replacingOccurrences(
                of: "\"multiPartitionObservationPresent\":false",
                with: "\"multiPartitionObservationPresent\":true"
            )
            .replacingOccurrences(
                of: "\"verdict\":\"incomplete\"",
                with: "\"verdict\":\"readyForHumanReview\""
            )
        expect(forged != original, "the replay fixture should forge every readiness summary")
        let forgedJSON = Data(forged.utf8)
        let forgedDigest = SHA256.hash(data: forgedJSON)
            .map { String(format: "%02x", $0) }
            .joined()

        switch Gate1EvidenceArtifactVerifier.verify(
            canonicalJSON: forgedJSON,
            expectedSHA256Digest: forgedDigest
        ) {
        case .success:
            fatalError("CHECK FAILED: summary-only Gate readiness must be rejected")
        case let .failure(failure):
            expect(
                failure == .invalidBundle,
                "event replay should reject summaries unsupported by recorded evidence"
            )
        }
    } catch {
        fatalError("CHECK FAILED: replay fixture should seal: \(error)")
    }
}

func gate1EvidenceVerifierRejectsForbiddenGenerationRelations() async {
    do {
        let fixture = try await gate1SyntheticCycleRecorder(
            evidenceID: gate1FixtureEvidenceID,
            cycleCount: 2
        )
        let artifact = try await fixture.recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: fixture.nextTimestamp)
        )
        let original = String(decoding: artifact.canonicalJSON, as: UTF8.self)
        let forged = original.replacingOccurrences(
            of: "\"mediaGenerationRelation\":\"advanced\"",
            with: "\"mediaGenerationRelation\":\"reusedWithoutAdvance\""
        )
        expect(forged != original, "the generation fixture must contain a reconnect")
        let forgedJSON = Data(forged.utf8)
        let forgedDigest = SHA256.hash(data: forgedJSON)
            .map { String(format: "%02x", $0) }
            .joined()
        switch Gate1EvidenceArtifactVerifier.verify(
            canonicalJSON: forgedJSON,
            expectedSHA256Digest: forgedDigest
        ) {
        case .success:
            fatalError("CHECK FAILED: a forbidden reconnect relation must not verify")
        case let .failure(failure):
            expect(
                failure == .invalidBundle,
                "generation forgery should fail semantic lifecycle replay"
            )
        }
    } catch {
        fatalError("CHECK FAILED: generation-forgery fixture should record: \(error)")
    }
}

func gate1EvidenceVerifierAcceptsCanonicalDiskOrderWhenReconnectInputFlips() async {
    let firstBase = await gate1UnknownCandidateObservation(
        diskBSDName: "disk737",
        volumeBSDName: "disk737s1",
        volumeUUID: "73700000-0000-0000-0000-000000000001",
        volumeName: "ORDER-A",
        mountPoint: "/Volumes/ORDER-A"
    )
    let secondBase = await gate1UnknownCandidateObservation(
        diskBSDName: "disk738",
        volumeBSDName: "disk738s1",
        volumeUUID: "73800000-0000-0000-0000-000000000001",
        volumeName: "ORDER-B",
        mountPoint: "/Volumes/ORDER-B"
    )
    func emptyDisk(
        _ observation: DiskInventoryObservation,
        generation: UInt64
    ) -> ReadOnlyPhysicalDiskRecord {
        let changed = gate1Observation(
            observation,
            replacingMediaGeneration: generation
        )
        guard let disk = changed.physicalDisks.first else {
            fatalError("CHECK FAILED: ordering fixture needs one disk")
        }
        return ReadOnlyPhysicalDiskRecord(
            instanceID: disk.instanceID,
            description: disk.description,
            volumes: [],
            issues: disk.issues
        )
    }
    let firstA = emptyDisk(firstBase, generation: 1)
    let firstB = emptyDisk(secondBase, generation: 1)
    let secondA = emptyDisk(firstBase, generation: 2)
    let secondB = emptyDisk(secondBase, generation: 2)
    let recorder = Gate1EvidenceRecorder(
        header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            applicationSHA256: String(repeating: "9", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        )
    )
    do {
        try await recorder.ingest(
            DiskInventoryObservation(
                physicalDisks: [firstA, firstB],
                issues: []
            ),
            at: GateEvidenceTimestamp(millisecondsSince1970: 1)
        )
        try await recorder.ingest(
            DiskInventoryObservation(physicalDisks: [], issues: []),
            at: GateEvidenceTimestamp(millisecondsSince1970: 2)
        )
        try await recorder.ingest(
            DiskInventoryObservation(
                physicalDisks: [secondB, secondA],
                issues: []
            ),
            at: GateEvidenceTimestamp(millisecondsSince1970: 3)
        )
        let artifact = try await recorder.seal(
            at: GateEvidenceTimestamp(millisecondsSince1970: 4)
        )
        switch Gate1EvidenceArtifactVerifier.verify(
            canonicalJSON: artifact.canonicalJSON,
            expectedSHA256Digest: artifact.sha256Digest
        ) {
        case .success:
            break
        case let .failure(failure):
            fatalError("CHECK FAILED: canonical reconnect ordering rejected: \(failure)")
        }
    } catch {
        fatalError("CHECK FAILED: reconnect-order fixture should record: \(error)")
    }
}

func semanticVersionParserHandlesTrustedDependencyOutput() {
    expect(
        SemanticVersionParser.parse("5.3.3")
            == SemanticVersion(major: 5, minor: 3, patch: 3),
        "a three-component dependency version should parse exactly"
    )
    expect(
        SemanticVersionParser.parse("ntfs-3g 2026.7.7 integrated FUSE")
            == SemanticVersion(major: 2026, minor: 7, patch: 7),
        "a trusted tool banner should expose its semantic version"
    )
    expect(
        SemanticVersionParser.parse("macFUSE 5.4")
            == SemanticVersion(major: 5, minor: 4, patch: 0),
        "a two-component bundle version should receive a zero patch"
    )
    expect(SemanticVersionParser.parse("version 5") == nil, "one component is ambiguous")
    expect(SemanticVersionParser.parse("-5.3.3") == nil, "negative versions must be rejected")
    expect(SemanticVersionParser.parse("not installed") == nil, "text without a version must fail")
}

func setupFailsClosedWhenAuthorizationOrConflictScanIsUnknown() {
    let facts = SetupFacts(
        macOSVersion: SemanticVersion(major: 15, minor: 4, patch: 0),
        architecture: .appleSilicon,
        macFUSEVersion: SemanticVersion(major: 5, minor: 3, patch: 3),
        ntfs3GVersion: SemanticVersion(major: 2026, minor: 7, patch: 7),
        fileSystemExtensionEnabled: true,
        selectedBackend: .fsKit,
        authorizationStatus: .unknown,
        conflictScanComplete: false,
        conflictingDrivers: []
    )

    let assessment = SetupChecker.assess(facts)
    expect(
        assessment.issues == [
            .requiredAuthorizationUnavailable(.unknown),
            .conflictScanIncomplete,
        ],
        "unknown authorization and an incomplete conflict scan must fail closed"
    )
    expect(!assessment.isReady, "unknown setup safety facts must never be ready")
}

func setupEnvironmentEvidenceMapsToExplicitFacts() {
    let evidence = SetupEnvironmentEvidence(
        macOSVersion: SemanticVersion(major: 26, minor: 6, patch: 2),
        architecture: .appleSilicon,
        macFUSEVersionText: "5.3.3",
        ntfs3GVersionText: "ntfs-3g 2026.7.7 integrated FUSE",
        fileSystemExtensionEnabled: true,
        selectedBackend: .unknown,
        authorizationStatus: .granted,
        conflictScanComplete: true,
        conflictingDriverIdentifiers: ["known-driver-b", "known-driver-a"]
    )

    let facts = SetupEnvironmentMapper.map(evidence)
    expect(
        facts == SetupFacts(
            macOSVersion: SemanticVersion(major: 26, minor: 6, patch: 2),
            architecture: .appleSilicon,
            macFUSEVersion: SemanticVersion(major: 5, minor: 3, patch: 3),
            ntfs3GVersion: SemanticVersion(major: 2026, minor: 7, patch: 7),
            fileSystemExtensionEnabled: true,
            selectedBackend: .unknown,
            authorizationStatus: .granted,
            conflictScanComplete: true,
            conflictingDrivers: ["known-driver-a", "known-driver-b"]
        ),
        "the mapper must preserve an explicitly observed backend instead of inventing FSKit"
    )
}

func setupPresentationDistinguishesUnconfiguredAndRejectedTrustEvidence() {
    let facts = SetupFacts(
        macOSVersion: SemanticVersion(major: 15, minor: 4, patch: 0),
        architecture: .appleSilicon,
        macFUSEVersion: nil,
        ntfs3GVersion: nil,
        fileSystemExtensionEnabled: false,
        selectedBackend: .unknown,
        authorizationStatus: .unknown,
        conflictScanComplete: false,
        conflictingDrivers: []
    )
    let probe = SetupProbeResult(
        fileSystemExtensionEnabled: false,
        conflictScanComplete: false,
        conflictingDriverIdentifiers: []
    )
    let unconfigured = SetupPresenter.presentation(
        for: SystemSetupReport(
            facts: facts,
            macFUSEEvidence: .notConfigured,
            ntfs3GEvidence: .notConfigured,
            authorizationStatus: .unknown,
            probeResult: probe
        ),
        isRefreshing: false
    )
    let unconfiguredRows = Dictionary(
        uniqueKeysWithValues: unconfigured.requirements.map { ($0.id, $0) }
    )
    expect(
        unconfiguredRows[.macFUSE]?.detail.contains("尚未配置受信任校验策略") == true,
        "an unconfigured trust policy must not be presented as a confirmed missing install"
    )
    expect(
        unconfiguredRows[.ntfs3G]?.detail.contains("尚未配置受信任校验策略") == true,
        "an unconfigured NTFS-3G policy must remain distinguishable"
    )

    let rejected = SetupPresenter.presentation(
        for: SystemSetupReport(
            facts: facts,
            macFUSEEvidence: .failedClosed(.bundle(.unsafeWritePermissions)),
            ntfs3GEvidence: .failedClosed(.invalidVersionCatalog),
            authorizationStatus: .unknown,
            probeResult: probe
        ),
        isRefreshing: false
    )
    let rejectedRows = Dictionary(
        uniqueKeysWithValues: rejected.requirements.map { ($0.id, $0) }
    )
    expect(
        rejectedRows[.macFUSE]?.detail.contains("BUNDLE_UNSAFE_PERMISSIONS") == true,
        "a rejected macFUSE artifact should expose a fixed non-sensitive failure code"
    )
    expect(
        rejectedRows[.ntfs3G]?.detail.contains("NTFS3G_VERSION_CATALOG") == true,
        "a rejected NTFS-3G catalog should expose a fixed non-sensitive failure code"
    )

    let unapprovedVersion = SetupPresenter.presentation(
        for: SystemSetupReport(
            facts: facts,
            macFUSEEvidence: .failedClosed(.bundle(.versionNotApproved)),
            ntfs3GEvidence: .notConfigured,
            authorizationStatus: .unknown,
            probeResult: probe
        ),
        isRefreshing: false
    )
    expect(
        unapprovedVersion.requirements.first(where: { $0.id == .macFUSE })?
            .detail.contains("BUNDLE_VERSION_NOT_APPROVED") == true,
        "an unapproved macFUSE version should expose one fixed failure code"
    )

    let signatureMismatch = SetupPresenter.presentation(
        for: SystemSetupReport(
            facts: facts,
            macFUSEEvidence: .failedClosed(
                .codeSignature(.teamIdentifierMismatch)
            ),
            ntfs3GEvidence: .notConfigured,
            authorizationStatus: .unknown,
            probeResult: probe
        ),
        isRefreshing: false
    )
    expect(
        signatureMismatch.requirements.first(where: { $0.id == .macFUSE })?
            .detail.contains("MACFUSE_TEAM_ID_MISMATCH") == true,
        "a macFUSE signer mismatch should expose one fixed non-sensitive code"
    )
}

func setupReportContradictionsFailClosedAcrossPresentationAndFacts() {
    let report = SystemSetupReport(
        facts: readySetupFacts(),
        macFUSEEvidence: .notConfigured,
        ntfs3GEvidence: .failedClosed(.invalidVersionCatalog),
        authorizationStatus: .denied,
        probeResult: SetupProbeResult(
            fileSystemExtensionEnabled: false,
            conflictScanComplete: false,
            conflictingDriverIdentifiers: ["fixed-conflict-code"]
        )
    )
    let presentation = SetupPresenter.presentation(for: report, isRefreshing: false)
    let rows = Dictionary(
        uniqueKeysWithValues: presentation.requirements.map { ($0.id, $0) }
    )

    expect(
        !SetupChecker.assess(report.reconciledFacts).isReady,
        "contradictory typed Setup evidence must reconcile to failed-closed facts"
    )
    expect(
        !presentation.isReady && presentation.title == "首次设置未完成",
        "contradictory Setup evidence must never retain a ready title"
    )
    expect(
        presentation.primaryAction == .continueSetup,
        "a contradictory Setup report must expose remediation rather than a ready recheck state"
    )
    expect(
        rows[.macFUSE]?.state == .actionRequired
            && rows[.ntfs3G]?.state == .actionRequired
            && rows[.authorization]?.state == .actionRequired
            && rows[.fileSystemExtension]?.state == .actionRequired
            && rows[.conflictingDrivers]?.state == .actionRequired,
        "every contradictory report component must remain visible as action required"
    )
}

func liveSystemSetupFactsLoaderFailsClosedOnUnverifiedCapabilities() async {
    let facts = await SystemSetupFactsLoader().currentFacts()
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
    expect(
        facts.macOSVersion == SemanticVersion(
            major: operatingSystem.majorVersion,
            minor: operatingSystem.minorVersion,
            patch: operatingSystem.patchVersion
        ),
        "the live setup loader should read the current macOS version"
    )
#if arch(arm64)
    expect(facts.architecture == .appleSilicon, "arm64 builds should report Apple Silicon")
#elseif arch(x86_64)
    expect(facts.architecture == .intel, "x86_64 builds should report Intel")
#else
    expect(facts.architecture == .unknown, "unrecognized builds should fail closed")
#endif
    expect(
        facts.authorizationStatus != .granted,
        "the loader must not grant authorization before a helper proves it"
    )
    expect(
        !SetupChecker.assess(facts).isReady,
        "unverified local dependencies and authorization must keep setup closed"
    )
}

func liveSetupProbeProviderExposesOnlyTypedBoundedOutput() async {
    let output = await SetupReadOnlyCommandProvider.live.output(
        for: .plugInKit(identifier: "io.macfuse.app.fsmodule.macfuse-local")
    )
    expect(
        output.standardOutput.utf8.count <= 1_048_576,
        "the fixed live Setup probe must bound standard output"
    )
    expect(
        output.standardError.utf8.count <= 1_048_576,
        "the fixed live Setup probe must bound standard error before discarding it"
    )
}

func boundedSetupProbeDoesNotWaitForInheritedOutputPipes() async {
    let invocation = SetupProbeInvocation(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "(sleep 3) & printf ok"],
        timeout: .milliseconds(250),
        maximumOutputBytes: 64
    )
    let clock = ContinuousClock()
    let startedAt = clock.now

    let result = await BoundedReadOnlyCommandRunner().run(invocation: invocation)
    let elapsed = startedAt.duration(to: clock.now)

    expect(
        result.completion == .outputUnreadable,
        "a direct exit without both output EOFs must not make incomplete output trustworthy"
    )
    expect(result.standardOutput == "ok", "the bounded probe should capture available output")
    expect(
        elapsed < .seconds(1),
        "a descendant holding the output pipe must not keep the probe call alive"
    )
}

func boundedSetupProbeStopsOnOutputOverflow() async {
    let invocation = SetupProbeInvocation(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "while :; do printf 0123456789abcdef; done"],
        timeout: .seconds(3),
        maximumOutputBytes: 64
    )
    let clock = ContinuousClock()
    let startedAt = clock.now

    let result = await BoundedReadOnlyCommandRunner().run(invocation: invocation)
    let elapsed = startedAt.duration(to: clock.now)

    expect(
        result.completion == .outputLimitExceeded,
        "output overflow must outrank the longer command timeout; observed \(result.completion) after \(elapsed)"
    )
    expect(
        result.standardOutput.utf8.count == 64,
        "the result should retain no more than the configured byte limit"
    )
    expect(
        elapsed < .seconds(1),
        "output overflow must stop the fixed probe within a bounded wall-clock interval"
    )
}

func cancellingSetupProbeStillConfirmsTheDirectProcessStops() async {
    let invocation = SetupProbeInvocation(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "sleep 3"],
        timeout: .seconds(5),
        maximumOutputBytes: 64
    )
    let clock = ContinuousClock()
    let startedAt = clock.now
    let task = Task {
        await BoundedReadOnlyCommandRunner().run(invocation: invocation)
    }

    try? await Task.sleep(for: .milliseconds(50))
    task.cancel()
    let result = await task.value
    let elapsed = startedAt.duration(to: clock.now)

    expect(
        result.completion == .timedOut,
        "cancellation must use the same fixed failed-closed result as a timeout"
    )
    expect(
        elapsed < .seconds(1),
        "cancelling a fixed probe must stop and confirm its direct process within the bound"
    )
}

func readOnlyDashboardNeverExposesMutationControlsOrRawIdentifiers() {
    let snapshot = makeSnapshot(
        uuid: "SECRET-VOLUME-UUID",
        bsdName: "disk99s7",
        displayName: "PERSONAL",
        physicalDiskID: PhysicalDiskID(rawValue: "disk99"),
        health: .unknown,
        mountAccess: .readOnly
    )
    let evidence = ReadOnlyVolumeEvidence(
        bsdName: "disk99s7",
        volumeUUID: "SECRET-VOLUME-UUID",
        physicalDiskBSDName: "disk99",
        displayName: "PERSONAL",
        fileSystemName: "ntfs",
        isInternal: false,
        roleEvidence: .trustedData,
        diskArbitrationMountPoint: "/Volumes/PERSONAL"
    )
    let record = ReadOnlyVolumeRecord(
        evidence: evidence,
        snapshot: snapshot,
        mountObservation: nil,
        issues: []
    )
    let observation = DiskInventoryObservation(
        physicalDisks: [
            ReadOnlyPhysicalDiskRecord(
                instanceID: snapshot.diskInstanceID,
                description: DiskArbitrationDescription(
                    bsdName: "disk99",
                    physicalDiskBSDName: "disk99",
                    isWholeDisk: true,
                    isInternal: false,
                    isEjectable: true,
                    isRemovable: true,
                    mediaSize: 1_000_000,
                    mediaUUID: "SECRET-MEDIA-UUID",
                    volumeUUID: nil,
                    volumeName: nil,
                    fileSystemName: nil,
                    mountPoint: nil
                ),
                volumes: [record],
                issues: []
            ),
        ],
        issues: []
    )

    let dashboard = ReadOnlyDashboardPresenter.presentation(
        for: observation,
        setupAssessment: SetupChecker.assess(readySetupFacts()),
        isSetupRefreshing: false
    )

    expect(dashboard.phase == .settled, "complete evidence should produce a settled dashboard")
    expect(dashboard.volumes.count == 1, "one confirmed NTFS volume should be presented")
    expect(
        dashboard.physicalDisks.count == 1
            && dashboard.physicalDisks[0].volumes == dashboard.volumes,
        "confirmed volumes should retain their physical-disk grouping for the C layout"
    )
    expect(
        dashboard.physicalDisks[0].title == "物理磁盘 1",
        "physical-disk grouping should use a privacy-safe local ordinal"
    )
    expect(dashboard.volumes[0].title == "PERSONAL", "the user-facing volume name should be shown")
    expect(dashboard.volumes[0].accessText == "只读", "the actual mount access should be explicit")
    expect(!dashboard.writeControlsAvailable, "the observation-only app must never expose write controls")

    let renderedText = ([dashboard.title, dashboard.detail]
        + dashboard.volumes.flatMap { [$0.title, $0.detail, $0.accessText] })
        .joined(separator: " ")
    for secret in ["SECRET-VOLUME-UUID", "SECRET-MEDIA-UUID", "disk99", "/Volumes/PERSONAL"] {
        expect(!renderedText.contains(secret), "dashboard text must not leak raw identifier \(secret)")
    }

    let incomplete = DiskInventoryObservation(
        physicalDisks: [],
        issues: [.mountTableReadFailed]
    )
    let limited = ReadOnlyDashboardPresenter.presentation(
        for: incomplete,
        setupAssessment: SetupChecker.assess(readySetupFacts()),
        isSetupRefreshing: false
    )
    expect(limited.phase == .limited, "incomplete evidence must not look like an empty settled system")
    expect(limited.title == "磁盘信息尚未确认", "incomplete evidence should use a fail-closed headline")
    expect(!limited.writeControlsAvailable, "limited evidence must keep write controls absent")

    let partiallyConfirmed = ReadOnlyDashboardPresenter.presentation(
        for: DiskInventoryObservation(
            physicalDisks: observation.physicalDisks,
            issues: [.mountTableReadFailed]
        ),
        setupAssessment: SetupChecker.assess(readySetupFacts()),
        isSetupRefreshing: false
    )
    expect(
        partiallyConfirmed.phase == .limited
            && partiallyConfirmed.volumes.count == 1,
        "limited read-only UI should retain independently confirmed NTFS volumes"
    )
    expect(
        partiallyConfirmed.title == "已确认 1 个 NTFS 卷",
        "partial evidence should distinguish a confirmed volume from an empty system"
    )
    expect(
        !partiallyConfirmed.writeControlsAvailable,
        "showing a confirmed volume under partial evidence must not enable mutations"
    )
}

func readOnlyDashboardGroupsAndSortsLongNamedPartitionsDeterministically() {
    let longName = String(repeating: "超长卷名", count: 24)
    let firstDiskID = PhysicalDiskID(rawValue: "disk-sort-a")
    let secondDiskID = PhysicalDiskID(rawValue: "disk-sort-b")
    let caseLower = makeSnapshot(
        uuid: "00000000-0000-0000-0000-000000000001",
        bsdName: "disk40s1",
        displayName: "archive 2",
        physicalDiskID: firstDiskID,
        mediaGeneration: MediaGeneration(rawValue: 40),
        health: .unknown
    )
    let caseUpper = makeSnapshot(
        uuid: "00000000-0000-0000-0000-000000000002",
        bsdName: "disk40s2",
        displayName: "ARCHIVE 2",
        physicalDiskID: firstDiskID,
        mediaGeneration: MediaGeneration(rawValue: 40),
        health: .unknown
    )
    let longNamed = makeSnapshot(
        uuid: "00000000-0000-0000-0000-000000000003",
        bsdName: "disk40s3",
        displayName: longName,
        physicalDiskID: firstDiskID,
        mediaGeneration: MediaGeneration(rawValue: 40),
        health: .unknown
    )
    let sameNamedFirst = makeSnapshot(
        uuid: "00000000-0000-0000-0000-000000000005",
        bsdName: "disk40s4",
        displayName: "SAME NAME",
        physicalDiskID: firstDiskID,
        mediaGeneration: MediaGeneration(rawValue: 40),
        health: .unknown
    )
    let sameNamedSecond = makeSnapshot(
        uuid: "00000000-0000-0000-0000-000000000006",
        bsdName: "disk40s5",
        displayName: "SAME NAME",
        physicalDiskID: firstDiskID,
        mediaGeneration: MediaGeneration(rawValue: 40),
        health: .unknown
    )
    let generatedTitleCollision = makeSnapshot(
        uuid: "00000000-0000-0000-0000-000000000007",
        bsdName: "disk40s6",
        displayName: "SAME NAME · 卷 1",
        physicalDiskID: firstDiskID,
        mediaGeneration: MediaGeneration(rawValue: 40),
        health: .unknown
    )
    let secondDiskVolume = makeSnapshot(
        uuid: "00000000-0000-0000-0000-000000000004",
        bsdName: "disk41s1",
        displayName: "SECOND DISK",
        physicalDiskID: secondDiskID,
        mediaGeneration: MediaGeneration(rawValue: 41),
        health: .unknown
    )

    func volumeRecord(_ snapshot: VolumeSnapshot) -> ReadOnlyVolumeRecord {
        ReadOnlyVolumeRecord(
            evidence: ReadOnlyVolumeEvidence(
                bsdName: snapshot.id.bsdName,
                volumeUUID: snapshot.id.uuid,
                physicalDiskBSDName: snapshot.physicalDiskID.rawValue,
                displayName: snapshot.displayName,
                fileSystemName: "ntfs",
                isInternal: false,
                roleEvidence: .trustedData,
                diskArbitrationMountPoint: nil
            ),
            snapshot: snapshot,
            mountObservation: nil,
            issues: []
        )
    }

    func diskRecord(
        id: DiskInstanceID,
        bsdName: String,
        snapshots: [VolumeSnapshot]
    ) -> ReadOnlyPhysicalDiskRecord {
        ReadOnlyPhysicalDiskRecord(
            instanceID: id,
            description: DiskArbitrationDescription(
                bsdName: bsdName,
                physicalDiskBSDName: bsdName,
                isWholeDisk: true,
                isInternal: false,
                isEjectable: true,
                isRemovable: true,
                mediaSize: 1_000_000,
                mediaUUID: nil,
                volumeUUID: nil,
                volumeName: nil,
                fileSystemName: nil,
                mountPoint: nil
            ),
            volumes: snapshots.map(volumeRecord),
            issues: []
        )
    }

    let firstDiskForward = diskRecord(
        id: caseLower.diskInstanceID,
        bsdName: "disk40",
        snapshots: [
            sameNamedSecond,
            caseUpper,
            generatedTitleCollision,
            longNamed,
            sameNamedFirst,
            caseLower,
        ]
    )
    let firstDiskReverse = diskRecord(
        id: caseLower.diskInstanceID,
        bsdName: "disk40",
        snapshots: [
            caseLower,
            sameNamedFirst,
            longNamed,
            generatedTitleCollision,
            caseUpper,
            sameNamedSecond,
        ]
    )
    let secondDisk = diskRecord(
        id: secondDiskVolume.diskInstanceID,
        bsdName: "disk41",
        snapshots: [secondDiskVolume]
    )
    let setupAssessment = SetupChecker.assess(readySetupFacts())
    let forward = ReadOnlyDashboardPresenter.presentation(
        for: DiskInventoryObservation(
            physicalDisks: [secondDisk, firstDiskForward],
            issues: []
        ),
        setupAssessment: setupAssessment,
        isSetupRefreshing: false
    )
    let reverse = ReadOnlyDashboardPresenter.presentation(
        for: DiskInventoryObservation(
            physicalDisks: [firstDiskReverse, secondDisk],
            issues: []
        ),
        setupAssessment: setupAssessment,
        isSetupRefreshing: false
    )

    expect(
        forward == reverse,
        "reversing disk and sibling input must not change C-layout grouping or order"
    )
    expect(
        forward.physicalDisks.map(\.title) == ["物理磁盘 1", "物理磁盘 2"]
            && forward.physicalDisks.map(\.volumes.count) == [6, 1],
        "multiple partitions must remain grouped under deterministic physical-disk ordinals"
    )
    let firstDiskTitles = forward.physicalDisks[0].volumes.map(\.title)
    expect(
        Set(firstDiskTitles).count == firstDiskTitles.count,
        "a user-supplied volume name must not collide with generated sibling labels"
    )
    expect(
        firstDiskTitles.enumerated().allSatisfy { index, title in
            title.hasPrefix("卷 \(index + 1) · ")
        },
        "every volume on a multi-volume disk must expose its deterministic local ordinal"
    )
    expect(
        forward.volumes.contains(where: { $0.title.hasSuffix(" · \(longName)") }),
        "presentation must preserve the complete long volume name for text and accessibility"
    )
    let titleByID = Dictionary(
        uniqueKeysWithValues: forward.physicalDisks[0].volumes.map { ($0.id, $0.title) }
    )
    let sameNamedTitles = [sameNamedFirst, sameNamedSecond].compactMap {
        titleByID[$0.instanceID]
    }
    expect(
        sameNamedTitles.count == 2
            && Set(sameNamedTitles).count == 2
            && sameNamedTitles.allSatisfy { $0.hasSuffix(" · SAME NAME") },
        "same-named sibling volumes must receive stable privacy-safe local ordinals"
    )
    expect(
        sameNamedTitles.allSatisfy { title in
            !title.contains("00000000-") && !title.contains("disk40s")
        },
        "same-name disambiguation must not expose UUID or BSD identity"
    )
    expect(
        forward.physicalDisks[1].volumes.map(\.title) == ["SECOND DISK"],
        "a single-volume disk must keep its original display name without ordinal noise"
    )
    expect(
        forward.physicalDisks.allSatisfy { disk in
            disk.volumes.allSatisfy { $0.id.diskInstanceID == disk.id }
        },
        "every displayed partition must remain bound to its physical-disk instance"
    )
}

func readOnlySelectionWaitsForAStableAbsenceBeforeResetting() {
    let snapshot = makeSnapshot(
        uuid: "SELECTION-VOLUME",
        bsdName: "disk88s1",
        displayName: "ARCHIVE",
        physicalDiskID: PhysicalDiskID(rawValue: "disk88")
    )
    let volume = ReadOnlyVolumePresentation(
        id: snapshot.instanceID,
        title: "ARCHIVE",
        accessText: "只读",
        detail: "外置磁盘。"
    )
    let disk = ReadOnlyPhysicalDiskPresentation(
        id: snapshot.diskInstanceID,
        title: "物理磁盘 1",
        detail: "外置物理磁盘。",
        volumes: [volume]
    )
    let setup = SetupPresenter.presentation(
        for: SetupChecker.assess(readySetupFacts()),
        isRefreshing: false
    )
    let selected = ReadOnlyDashboardSelection.volume(snapshot.instanceID)
    let focusedButNotSelected = ReadOnlyDashboardSelection.volume(
        makeSnapshot(
            uuid: "FOCUSED-OTHER-VOLUME",
            bsdName: "disk88s2",
            displayName: "OTHER",
            physicalDiskID: PhysicalDiskID(rawValue: "disk88")
        ).instanceID
    )

    func dashboard(
        phase: ReadOnlyDashboardPhase,
        disks: [ReadOnlyPhysicalDiskPresentation]
    ) -> ReadOnlyDashboardPresentation {
        ReadOnlyDashboardPresentation(
            phase: phase,
            title: "状态",
            detail: "状态说明。",
            physicalDisks: disks,
            setup: setup
        )
    }

    let scanningDashboard = dashboard(phase: .scanning, disks: [])
    let presentDashboard = dashboard(phase: .settled, disks: [disk])
    expect(
        ReadOnlySelectionPresenter.reconciledSelection(
            selected,
            for: scanningDashboard
        ) == selected,
        "a selected volume must survive a temporary empty scanning projection"
    )
    expect(
        ReadOnlySelectionPresenter.presentedSelection(
            for: selected,
            in: scanningDashboard
        ) == .overview,
        "a retained volume missing from a scanning projection must present the overview"
    )
    expect(
        ReadOnlyNavigationFocusPresenter.reconciledFocus(
            .wide(selected),
            from: .wide,
            to: .wide,
            previousPresentedSelection: selected,
            currentPresentedSelection: .overview,
            in: scanningDashboard
        ) == .wide(.overview),
        "an invalidated focused wide navigation item must move focus to overview"
    )
    expect(
        ReadOnlyNavigationFocusPresenter.reconciledFocus(
            .wide(selected),
            from: .wide,
            to: .wide,
            previousPresentedSelection: .overview,
            currentPresentedSelection: .overview,
            in: scanningDashboard
        ) == .wide(.overview),
        "a coalesced epoch callback must still invalidate focus using the current dashboard"
    )
    expect(
        ReadOnlyNavigationFocusPresenter.reconciledFocus(
            .compactPicker,
            from: .compact,
            to: .compact,
            previousPresentedSelection: selected,
            currentPresentedSelection: .overview,
            in: scanningDashboard
        ) == .compactPicker,
        "a focused compact picker must retain focus when its selection falls back"
    )
    expect(
        ReadOnlyNavigationFocusPresenter.reconciledFocus(
            .wide(selected),
            from: .wide,
            to: .compact,
            previousPresentedSelection: selected,
            currentPresentedSelection: selected,
            in: presentDashboard
        ) == .compactPicker
            && ReadOnlyNavigationFocusPresenter.reconciledFocus(
                .compactPicker,
                from: .compact,
                to: .wide,
                previousPresentedSelection: selected,
                currentPresentedSelection: selected,
                in: presentDashboard
            ) == .wide(selected),
        "focused navigation must transfer between wide items and the compact picker"
    )
    expect(
        ReadOnlyNavigationFocusPresenter.reconciledFocus(
            nil,
            from: .wide,
            to: .compact,
            previousPresentedSelection: selected,
            currentPresentedSelection: selected,
            in: presentDashboard
        ) == nil,
        "a layout change must not steal focus from outside the navigation region"
    )
    expect(
        ReadOnlyNavigationFocusPresenter.reconciledFocus(
            .wide(.environment),
            from: .wide,
            to: .wide,
            previousPresentedSelection: selected,
            currentPresentedSelection: .overview,
            in: scanningDashboard
        ) == .wide(.environment),
        "selection fallback must preserve another still-present navigation focus"
    )
    expect(
        ReadOnlyNavigationFocusPresenter.reconciledFocus(
            .wide(.overview),
            from: .wide,
            to: .wide,
            previousPresentedSelection: .overview,
            currentPresentedSelection: selected,
            in: presentDashboard
        ) == .wide(.overview),
        "a temporarily missing volume returning must not reclaim focus from overview"
    )
    expect(
        ReadOnlyNavigationFocusPresenter.reconciledFocus(
            .wide(focusedButNotSelected),
            from: .wide,
            to: .wide,
            previousPresentedSelection: selected,
            currentPresentedSelection: .overview,
            in: scanningDashboard
        ) == .wide(.overview),
        "any focused wide volume removed by scanning must fall back to the presented selection"
    )
    expect(
        ReadOnlySelectionPresenter.reconciledSelection(
            selected,
            for: dashboard(phase: .limited, disks: [])
        ) == .overview,
        "a limited stable projection may reset a volume that is no longer presented"
    )
    expect(
        ReadOnlySelectionPresenter.reconciledSelection(
            selected,
            for: dashboard(phase: .settled, disks: [])
        ) == .overview,
        "a settled projection must reset a confirmed missing volume"
    )
    expect(
        ReadOnlySelectionPresenter.reconciledSelection(
            selected,
            for: presentDashboard
        ) == selected,
        "a selected volume that remains present must stay selected"
    )
    expect(
        ReadOnlySelectionPresenter.presentedSelection(
            for: selected,
            in: presentDashboard
        ) == selected,
        "a retained volume that remains present must also be the presented selection"
    )
}

func observationSubscriptionChangeResetsAnOtherwiseIdenticalSelection() {
    let snapshot = makeSnapshot(
        uuid: "REUSED-SELECTION-ID",
        bsdName: "disk89s1",
        displayName: "REUSED TARGET",
        physicalDiskID: PhysicalDiskID(rawValue: "disk89"),
        mediaGeneration: MediaGeneration(rawValue: 1)
    )
    let setup = SetupPresenter.presentation(
        for: SetupChecker.assess(readySetupFacts()),
        isRefreshing: false
    )
    let replacementDashboard = ReadOnlyDashboardPresentation(
        phase: .settled,
        title: "新订阅结果",
        detail: "新的观察订阅复用了系统标识。",
        physicalDisks: [
            ReadOnlyPhysicalDiskPresentation(
                id: snapshot.diskInstanceID,
                title: "物理磁盘 1",
                detail: "外置物理磁盘。",
                volumes: [
                    ReadOnlyVolumePresentation(
                        id: snapshot.instanceID,
                        title: "REPLACEMENT TARGET",
                        accessText: "只读",
                        detail: "当前应用不会更改磁盘状态。"
                    ),
                ]
            ),
        ],
        setup: setup
    )
    let scanningDashboard = ReadOnlyDashboardPresentation(
        phase: .scanning,
        title: "正在扫描",
        detail: "等待当前订阅的只读事实。",
        physicalDisks: [],
        setup: setup
    )
    let selection = ReadOnlyDashboardSelection.volume(snapshot.instanceID)

    var observationSession = ReadOnlyObservationSession()
    observationSession.beginRefresh()
    let selectedEpoch = observationSession.selectionResetEpoch
    expect(
        ReadOnlySelectionPresenter.reconciledSelection(
            selection,
            selectedIn: selectedEpoch,
            for: scanningDashboard,
            in: selectedEpoch
        ) == selection,
        "temporary scanning inside one observation subscription must preserve selection"
    )

    observationSession.beginRefresh()
    let replacementEpoch = observationSession.selectionResetEpoch
    expect(
        replacementEpoch != selectedEpoch,
        "every observation subscription must rotate the typed selection-reset epoch"
    )
    expect(
        ReadOnlySelectionPresenter.reconciledSelection(
            selection,
            selectedIn: selectedEpoch,
            for: replacementDashboard,
            in: replacementEpoch
        ) == .overview,
        "a new subscription must not reuse an old selection even when its volume instance ID repeats"
    )
    expect(
        ReadOnlyNavigationFocusPresenter.reconciledFocus(
            .wide(selection),
            from: .wide,
            to: .wide,
            previousPresentedSelection: selection,
            currentPresentedSelection: .overview,
            in: replacementDashboard
        ) == .wide(.overview),
        "an epoch reset must move focus to overview even when the replacement dashboard reuses the volume ID"
    )
}

func readOnlySelectionNeverResolvesAStaleVolumeAcrossRefreshes() {
    let oldSnapshot = makeSnapshot(
        uuid: "OLD-SELECTION",
        bsdName: "disk89s1",
        displayName: "OLD TARGET",
        physicalDiskID: PhysicalDiskID(rawValue: "disk89")
    )
    let replacementSnapshot = makeSnapshot(
        uuid: "NEW-SELECTION",
        bsdName: "disk90s1",
        displayName: "NEW TARGET",
        physicalDiskID: PhysicalDiskID(rawValue: "disk90")
    )
    let setup = SetupPresenter.presentation(
        for: SetupChecker.assess(readySetupFacts()),
        isRefreshing: false
    )

    func disk(
        snapshot: VolumeSnapshot,
        ordinal: Int
    ) -> ReadOnlyPhysicalDiskPresentation {
        ReadOnlyPhysicalDiskPresentation(
            id: snapshot.diskInstanceID,
            title: "物理磁盘 \(ordinal)",
            detail: "外置物理磁盘。",
            volumes: [
                ReadOnlyVolumePresentation(
                    id: snapshot.instanceID,
                    title: snapshot.displayName,
                    accessText: "只读",
                    detail: "当前应用不会更改磁盘状态。"
                ),
            ]
        )
    }

    func dashboard(
        phase: ReadOnlyDashboardPhase,
        title: String,
        disks: [ReadOnlyPhysicalDiskPresentation]
    ) -> ReadOnlyDashboardPresentation {
        ReadOnlyDashboardPresentation(
            phase: phase,
            title: title,
            detail: "当前刷新状态。",
            physicalDisks: disks,
            setup: setup
        )
    }

    let oldDashboard = dashboard(
        phase: .settled,
        title: "旧结果",
        disks: [disk(snapshot: oldSnapshot, ordinal: 1)]
    )
    let scanningDashboards = [
        dashboard(phase: .scanning, title: "第一次扫描", disks: []),
        dashboard(phase: .scanning, title: "第二次扫描", disks: []),
    ]
    let replacementDashboard = dashboard(
        phase: .settled,
        title: "新结果",
        disks: [disk(snapshot: replacementSnapshot, ordinal: 1)]
    )
    var selection = ReadOnlyDashboardSelection.volume(oldSnapshot.instanceID)

    guard case let .volume(volume, _) = ReadOnlySelectionPresenter.detail(
        for: selection,
        in: oldDashboard
    ) else {
        fatalError("CHECK FAILED: a current selected volume should resolve")
    }
    expect(volume.title == "OLD TARGET", "the initial current target should resolve")

    for scanning in scanningDashboards {
        selection = ReadOnlySelectionPresenter.reconciledSelection(
            selection,
            for: scanning
        )
        expect(
            selection == .volume(oldSnapshot.instanceID),
            "scanning may retain only the selected instance identity"
        )
        expect(
            ReadOnlySelectionPresenter.detail(for: selection, in: scanning) == .overview,
            "a scanning projection must not resolve content from the old target"
        )
        expect(
            !ReadOnlyAccessibilityPresenter.announcement(
                for: selection,
                in: scanning
            ).contains("OLD TARGET"),
            "a scanning announcement must describe current scanning facts, not old content"
        )
    }

    expect(
        ReadOnlySelectionPresenter.detail(
            for: selection,
            in: replacementDashboard
        ) == .overview,
        "a replacement dashboard must not bind an old selection to a new volume"
    )
    selection = ReadOnlySelectionPresenter.reconciledSelection(
        selection,
        for: replacementDashboard
    )
    expect(
        selection == .overview,
        "a settled replacement must reset the confirmed missing old selection"
    )
}

func readOnlyAccessibilityAnnouncementDescribesTheCurrentSelection() {
    let snapshot = makeSnapshot(
        uuid: "ANNOUNCEMENT-VOLUME",
        bsdName: "disk87s1",
        displayName: "WORK FILES",
        physicalDiskID: PhysicalDiskID(rawValue: "disk87")
    )
    let sameNamedOtherDiskSnapshot = makeSnapshot(
        uuid: "ANNOUNCEMENT-OTHER-DISK",
        bsdName: "disk86s1",
        displayName: "WORK FILES",
        physicalDiskID: PhysicalDiskID(rawValue: "disk86")
    )
    let sameSpokenSiblingSnapshot = makeSnapshot(
        uuid: "ANNOUNCEMENT-SIBLING",
        bsdName: "disk87s2",
        displayName: "WORK FILES",
        physicalDiskID: PhysicalDiskID(rawValue: "disk87")
    )
    let volume = ReadOnlyVolumePresentation(
        id: snapshot.instanceID,
        title: "WORK FILES",
        accessText: "只读",
        detail: "外置磁盘。当前应用不会更改磁盘状态。"
    )
    let disk = ReadOnlyPhysicalDiskPresentation(
        id: snapshot.diskInstanceID,
        title: "物理磁盘 1",
        detail: "外置物理磁盘，包含 1 个已确认的 NTFS 卷。",
        volumes: [volume]
    )
    let setup = SetupPresenter.presentation(
        for: SetupAssessment(issues: [.macFUSEMissing]),
        isRefreshing: false
    )
    let dashboard = ReadOnlyDashboardPresentation(
        phase: .settled,
        title: "检测到 1 个 NTFS 卷",
        detail: "当前版本只读取系统状态。",
        physicalDisks: [disk],
        setup: setup
    )

    let overview = ReadOnlyAccessibilityPresenter.announcement(
        for: .overview,
        in: dashboard
    )
    expect(
        overview.contains(dashboard.title) && overview.contains(dashboard.detail),
        "the overview announcement should describe the overview"
    )

    let selectedVolume = ReadOnlyAccessibilityPresenter.announcement(
        for: .volume(snapshot.instanceID),
        in: dashboard
    )
    expect(
        selectedVolume.contains("WORK FILES")
            && selectedVolume.contains("只读")
            && !selectedVolume.contains(dashboard.title),
        "a volume announcement should describe that volume instead of the overview"
    )

    let sameNamedOtherDiskVolume = ReadOnlyVolumePresentation(
        id: sameNamedOtherDiskSnapshot.instanceID,
        title: volume.title,
        accessText: volume.accessText,
        detail: volume.detail
    )
    let sameNamedOtherDisk = ReadOnlyPhysicalDiskPresentation(
        id: sameNamedOtherDiskSnapshot.diskInstanceID,
        title: "物理磁盘 2",
        detail: disk.detail,
        volumes: [sameNamedOtherDiskVolume]
    )
    let crossDiskDashboard = ReadOnlyDashboardPresentation(
        phase: dashboard.phase,
        title: "检测到 2 个 NTFS 卷",
        detail: dashboard.detail,
        physicalDisks: [disk, sameNamedOtherDisk],
        setup: dashboard.setup
    )
    let firstSelectionLabel = ReadOnlyAccessibilityPresenter.selectionLabel(
        for: .volume(snapshot.instanceID),
        in: crossDiskDashboard
    )
    let otherDiskSelectionLabel = ReadOnlyAccessibilityPresenter.selectionLabel(
        for: .volume(sameNamedOtherDiskSnapshot.instanceID),
        in: crossDiskDashboard
    )
    expect(
        firstSelectionLabel == "物理磁盘 1，WORK FILES"
            && otherDiskSelectionLabel == "物理磁盘 2，WORK FILES"
            && firstSelectionLabel != otherDiskSelectionLabel,
        "same-named volumes on different disks must expose distinct selection labels"
    )
    expect(
        [firstSelectionLabel, otherDiskSelectionLabel].allSatisfy { label in
            !label.contains("ANNOUNCEMENT-")
                && !label.contains("disk86s1")
                && !label.contains("disk87s1")
        },
        "selection labels must not expose UUID or BSD identity"
    )
    expect(
        ReadOnlyAccessibilityPresenter.selectionLabel(
            for: .overview,
            in: crossDiskDashboard
        ) == "概览"
            && ReadOnlyAccessibilityPresenter.selectionLabel(
                for: .environment,
                in: crossDiskDashboard
            ) == "运行环境"
            && ReadOnlyAccessibilityPresenter.selectionLabel(
                for: .diagnostics,
                in: crossDiskDashboard
            ) == "诊断摘要",
        "non-volume selection labels must remain fixed and explicit"
    )
    expect(
        ReadOnlyAccessibilityPresenter.selectionLabel(
            for: .volume(sameSpokenSiblingSnapshot.instanceID),
            in: crossDiskDashboard
        ) == "概览",
        "a stale volume selection label must follow the existing overview fallback"
    )

    let environment = ReadOnlyAccessibilityPresenter.announcement(
        for: .environment,
        in: dashboard
    )
    expect(
        environment.contains(setup.title)
            && environment.contains(setup.detail)
            && !environment.contains(dashboard.title),
        "an environment announcement should describe Setup instead of the overview"
    )

    expect(
        ReadOnlyAccessibilityPresenter.announcement(
            for: .diagnostics,
            in: dashboard
        ).hasPrefix("诊断摘要"),
        "the diagnostics selection should announce the diagnostics page"
    )

    let sameSpokenSibling = ReadOnlyVolumePresentation(
        id: sameSpokenSiblingSnapshot.instanceID,
        title: volume.title,
        accessText: volume.accessText,
        detail: volume.detail
    )
    let sameSpokenDashboard = ReadOnlyDashboardPresentation(
        phase: dashboard.phase,
        title: dashboard.title,
        detail: dashboard.detail,
        physicalDisks: [
            ReadOnlyPhysicalDiskPresentation(
                id: disk.id,
                title: disk.title,
                detail: disk.detail,
                volumes: [volume, sameSpokenSibling]
            )
        ],
        setup: dashboard.setup
    )
    let firstEvent = ReadOnlyAccessibilityPresenter.announcementEvent(
        for: .volume(snapshot.instanceID),
        in: sameSpokenDashboard
    )
    let siblingEvent = ReadOnlyAccessibilityPresenter.announcementEvent(
        for: .volume(sameSpokenSiblingSnapshot.instanceID),
        in: sameSpokenDashboard
    )
    expect(
        firstEvent.text == siblingEvent.text && firstEvent != siblingEvent,
        "selection identity must distinguish accessibility events even when spoken text matches"
    )
}

func readOnlyDiagnosticFeedbackUsesStableVisibleAndAccessibleText() {
    expect(
        ReadOnlyDiagnosticInteractionPresenter.copyActionTitle == "复制摘要",
        "the diagnostics copy action must use stable visible text"
    )
    expect(
        ReadOnlyDiagnosticInteractionPresenter.clearActionTitle(isClearing: false)
            == "清除诊断"
            && ReadOnlyDiagnosticInteractionPresenter.clearActionTitle(isClearing: true)
                == "正在清除",
        "the diagnostics clear action must expose stable idle and busy text"
    )

    let cases: [(ReadOnlyActionFeedback, String)] = [
        (
            ReadOnlyDiagnosticInteractionPresenter.copyFeedback(didSucceed: true),
            "诊断摘要已复制。"
        ),
        (
            ReadOnlyDiagnosticInteractionPresenter.copyFeedback(didSucceed: false),
            "未能复制诊断摘要，请稍后重试。"
        ),
        (
            ReadOnlyDiagnosticInteractionPresenter.clearStartedFeedback,
            "正在清除诊断记录。"
        ),
        (
            ReadOnlyDiagnosticInteractionPresenter.clearFeedback(didSucceed: true),
            "诊断记录与本地存档已清除，运行标识已轮换。"
        ),
        (
            ReadOnlyDiagnosticInteractionPresenter.clearFeedback(didSucceed: false),
            "诊断内存已重置，但本地旧存档未能确认清除。"
        ),
    ]
    for (feedback, expectedText) in cases {
        expect(
            feedback.visibleText == expectedText,
            "diagnostics feedback must keep its stable visible result"
        )
        expect(
            feedback.accessibilityAnnouncement == expectedText,
            "diagnostics feedback must announce the same complete result"
        )
    }
}

func diagnosticsRetainsOnlyTypedBoundedDeterministicEntries() async {
    do {
        _ = try DiagnosticRetentionPolicy(maxEntries: 0)
        fatalError("CHECK FAILED: a zero diagnostics entry limit must be rejected")
    } catch let error as DiagnosticRetentionPolicyError {
        expect(
            error == .maxEntriesMustBePositive,
            "an invalid diagnostics policy should expose a fixed error"
        )
    } catch {
        fatalError("CHECK FAILED: diagnostics policy returned an unexpected error: \(error)")
    }

    let firstRunID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let secondRunID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let runIDs = LockedRunIDGenerator([firstRunID, secondRunID])
    let policy: DiagnosticRetentionPolicy
    do {
        policy = try DiagnosticRetentionPolicy(maxEntries: 2)
    } catch {
        fatalError("CHECK FAILED: a positive diagnostics limit should be accepted: \(error)")
    }
    let diagnostics = Diagnostics(
        policy: policy,
        clock: { Date(timeIntervalSince1970: 123) },
        runIDGenerator: { runIDs.next() }
    )

    let disk: DiagnosticTarget
    do {
        disk = try await diagnostics.registerDisk(mediaGeneration: 7)
        for count in 1...3 {
            try await diagnostics.record(
                .inventory(
                    DiagnosticInventoryEvent(
                        isComplete: false,
                        physicalDiskCount: UInt32(count),
                        volumeCount: UInt32(count + 1),
                        issueCodes: [
                            .mountTableReadFailed,
                            .initialEnumerationPending,
                            .mountTableReadFailed,
                        ]
                    )
                )
            )
        }
    } catch {
        fatalError("CHECK FAILED: typed diagnostics fixture should record: \(error)")
    }

    let snapshot = await diagnostics.snapshot()
    expect(snapshot.runID == firstRunID, "the current diagnostics run should use its generated ID")
    expect(
        snapshot.entries.map(\.sequence) == [2, 3],
        "the bounded archive should evict only the oldest entry"
    )
    guard case let .inventory(firstEvent) = snapshot.entries.first?.event else {
        fatalError("CHECK FAILED: the retained diagnostic entry should preserve its typed kind")
    }
    expect(
        firstEvent.issueCodes == [.initialEnumerationPending, .mountTableReadFailed],
        "diagnostic issue codes should be deduplicated and sorted"
    )

    do {
        let json = try snapshot.encodedJSON()
        let copyText = try snapshot.copyText()
        let secondSnapshot = await diagnostics.snapshot()
        let secondJSON = try secondSnapshot.encodedJSON()
        expect(copyText == String(decoding: json, as: UTF8.self), "copy text should reuse exact JSON")
        expect(
            json == secondJSON,
            "a fixed clock should produce deterministic snapshot bytes"
        )
        let forbiddenKeys = ["bsdName", "mountPoint", "volumeName", "driverName", "stderr"]
        for forbiddenKey in forbiddenKeys {
            expect(
                !copyText.contains(forbiddenKey),
                "diagnostics JSON must not contain free-form field \(forbiddenKey)"
            )
        }
    } catch {
        fatalError("CHECK FAILED: diagnostics snapshot should encode deterministically: \(error)")
    }

    await diagnostics.clear()
    let cleared = await diagnostics.snapshot()
    expect(cleared.runID == secondRunID, "clear should rotate the diagnostics run ID")
    expect(cleared.entries.isEmpty, "clear should remove every retained entry")
    do {
        _ = try await diagnostics.registerVolume(on: disk)
        fatalError("CHECK FAILED: a target from the previous run must be stale")
    } catch let error as DiagnosticsError {
        expect(error == .staleTarget, "old diagnostic aliases should be rejected after clear")
    } catch {
        fatalError("CHECK FAILED: stale diagnostics target returned unexpected error: \(error)")
    }
}

func setupOutputParsersRejectAmbiguityAndUnknownRecords() {
    let validVersionOutput = SetupCommandOutput(
        standardOutput: "ntfs-3g 2026.7.7 integrated FUSE 3.x\n",
        terminationStatus: 0,
        wasTruncated: false
    )
    expect(
        NTFS3GVersionParser.parse(validVersionOutput)
            == .parsed(SemanticVersion(major: 2026, minor: 7, patch: 7)),
        "NTFS-3G parser should accept one anchored three-component version"
    )
    expect(
        NTFS3GVersionParser.parse(
            SetupCommandOutput(
                standardOutput: "ntfs-3g 2026.7.7\nntfs-3g 2026.7.8\n",
                terminationStatus: 0,
                wasTruncated: false
            )
        ) == .failedClosed(.duplicateRecord),
        "multiple NTFS-3G version records must be ambiguous"
    )
    expect(
        NTFS3GVersionParser.parse(
            SetupCommandOutput(
                standardOutput: "ntfs-3g 2026.7\n",
                terminationStatus: 0,
                wasTruncated: false
            )
        ) == .failedClosed(.unexpectedOutput),
        "two-component NTFS-3G versions must fail closed"
    )
    expect(
        NTFS3GVersionParser.parse(
            SetupCommandOutput(
                standardOutput: "ntfs-3g 2026.7.7\n",
                terminationStatus: 0,
                wasTruncated: true
            )
        ) == .failedClosed(.truncated),
        "truncated version output must never be accepted"
    )

    let plugInIdentifier = "io.macfuse.filesystems.macfuse"
    expect(
        PlugInKitListingParser.parse(
            SetupCommandOutput(
                standardOutput: "+    \(plugInIdentifier) (5.3.3)\n",
                terminationStatus: 0,
                wasTruncated: false
            ),
            allowedIdentifiers: [plugInIdentifier]
        ) == .parsed([
            PlugInKitRecord(identifier: plugInIdentifier, election: .use),
        ]),
        "PluginKit parser should retain one exact allowlisted elected module"
    )
    expect(
        PlugInKitListingParser.parse(
            SetupCommandOutput(
                standardOutput: "?    \(plugInIdentifier) (5.3.3)\n",
                terminationStatus: 0,
                wasTruncated: false
            ),
            allowedIdentifiers: [plugInIdentifier]
        ) == .failedClosed(.unexpectedOutput),
        "unknown PluginKit election markers must fail closed"
    )
    expect(
        PlugInKitListingParser.parse(
            SetupCommandOutput(
                standardOutput: "+    com.example.untrusted (1.0.0)\n",
                terminationStatus: 0,
                wasTruncated: false
            ),
            allowedIdentifiers: [plugInIdentifier]
        ) == .failedClosed(.unexpectedOutput),
        "PluginKit output outside the exact allowlist must fail closed"
    )

    let extensionIdentifier = "com.example.known-extension"
    let systemExtensionOutput = """
    2 extension(s)
    --- com.apple.system_extension.driver_extension
    enabled active teamID bundleID (version) name [state]
    * * TEAM123456 \(extensionIdentifier) (1.0.0/1) Known [activated enabled]
    - - OTHERTEAM com.example.unrelated (1.0.0/1) Other [activated disabled]
    """
    expect(
        SystemExtensionListingParser.parse(
            SetupCommandOutput(
                standardOutput: systemExtensionOutput,
                terminationStatus: 0,
                wasTruncated: false
            ),
            allowedIdentifiers: [extensionIdentifier]
        ) == .parsed([
            SystemExtensionRecord(
                identifier: extensionIdentifier,
                isEnabled: true,
                isActive: true,
                state: .activatedEnabled
            ),
        ]),
        "system extension parser should validate all records and return only allowlisted matches"
    )
    expect(
        SystemExtensionListingParser.parse(
            SetupCommandOutput(
                standardOutput: systemExtensionOutput.replacingOccurrences(
                    of: "2 extension(s)",
                    with: "3 extension(s)"
                ),
                terminationStatus: 0,
                wasTruncated: false
            ),
            allowedIdentifiers: [extensionIdentifier]
        ) == .failedClosed(.inconsistentRecordCount),
        "declared and observed extension counts must match"
    )

    let kextIdentifier = "com.example.known-kext"
    let kextOutput = """
    Index Refs Address Size Wired Name (Version) UUID <Linked Against>
    1 1 0xffffff 0x1000 0x1000 \(kextIdentifier) (1.0.0) 11111111-1111-1111-1111-111111111111 <1 2>
    """
    expect(
        LoadedKextParser.parse(
            SetupCommandOutput(
                standardOutput: kextOutput,
                terminationStatus: 0,
                wasTruncated: false
            ),
            allowedIdentifiers: [kextIdentifier]
        ) == .parsed([LoadedKextRecord(identifier: kextIdentifier)]),
        "loaded-kext parser should return only a structurally valid allowlisted record"
    )
    expect(
        LoadedKextParser.parse(
            SetupCommandOutput(
                standardOutput: kextOutput,
                terminationStatus: 1,
                wasTruncated: false
            ),
            allowedIdentifiers: [kextIdentifier]
        ) == .failedClosed(.commandFailed),
        "nonzero probe exit must outrank parseable-looking output"
    )
}

func setupProbeEvaluatorRequiresExactFSKitElectionAndCompleteConflictEvidence() {
    let fsKitIdentifier = "io.macfuse.app.fsmodule.macfuse-local"
    let kextConflict = "com.paragon-software.filesystems.ntfs"
    guard let candidateScope = SetupProbePolicy.current.candidateScope else {
        fatalError("CHECK FAILED: the current policy should retain its candidate scope")
    }
    let policy = SetupProbePolicy(
        acceptedFSKitIdentifiers: [fsKitIdentifier],
        candidateScope: candidateScope,
        activeScope: candidateScope,
        environmentBaselineSatisfied: true
    )
    let environment = ConflictCatalogEnvironment(
        macOSVersion: candidateScope.target.macOSVersion,
        architecture: candidateScope.target.architecture
    )
    let absentFootprints = ConflictFootprintProvider { _ in .absent }

    let result = SetupProbeEvaluator.evaluate(
        plugInKitOutputs: [
            fsKitIdentifier: SetupCommandOutput(
                standardOutput: "+    \(fsKitIdentifier) (1.9)\n",
                terminationStatus: 0,
                wasTruncated: false
            ),
        ],
        systemExtensionOutput: nil,
        loadedKextOutput: SetupCommandOutput(
            standardOutput: """
            Index Refs Address Size Wired Name (Version) UUID <Linked Against>
            1 1 0xffffff 0x1000 0x1000 \(kextConflict) (1.0.0) 11111111-1111-1111-1111-111111111111 <1 2>
            """,
            terminationStatus: 0,
            wasTruncated: false
        ),
        policy: policy,
        environment: environment,
        footprintProvider: absentFootprints
    )
    expect(result.fileSystemExtensionEnabled, "the exact elected local FSKit module should be enabled")
    expect(result.conflictScanComplete, "fully parsed outputs and a complete catalog should complete the scan")
    expect(
        result.conflictingDriverIdentifiers == ["known-conflict-1"],
        "detected conflicts should be normalized to deterministic opaque identifiers"
    )

    let ignored = SetupProbeEvaluator.evaluate(
        plugInKitOutputs: [
            fsKitIdentifier: SetupCommandOutput(
                standardOutput: "-    \(fsKitIdentifier) (1.9)\n",
                terminationStatus: 0,
                wasTruncated: false
            ),
        ],
        systemExtensionOutput: nil,
        loadedKextOutput: nil,
        policy: policy,
        environment: environment,
        footprintProvider: absentFootprints
    )
    expect(!ignored.fileSystemExtensionEnabled, "an ignored FSKit module must not be treated as enabled")
    expect(!ignored.conflictScanComplete, "missing conflict command evidence must fail closed")
}

func candidateScopedConflictCatalogRequiresEveryBoundedEvidenceSource() {
    let exactKextIdentifiers: Set<String> = [
        "com.paragon-software.filesystems.ntfs",
        "com.tuxera.filesystems.tuxera_ntfs",
        "com.iboysoft.filesystems.ms_ntfs",
    ]
    let currentPolicy = SetupProbePolicy.current
    expect(
        currentPolicy.conflictingKextIdentifiers == exactKextIdentifiers,
        "the dated candidate scope should contain exactly the three verified kext identifiers"
    )
    expect(
        currentPolicy.conflictingSystemExtensionIdentifiers.isEmpty,
        "the dated artifacts must not fabricate system-extension identifiers"
    )
    expect(
        currentPolicy.activeScope == nil,
        "the current production policy must keep the candidate scope unapproved"
    )
    guard let candidateScope = currentPolicy.candidateScope else {
        fatalError("CHECK FAILED: the current policy should carry a bounded candidate scope")
    }

    let targetEnvironment = ConflictCatalogEnvironment(
        macOSVersion: candidateScope.target.macOSVersion,
        architecture: candidateScope.target.architecture
    )
    let approvedPolicy = SetupProbePolicy(
        acceptedFSKitIdentifiers: [],
        candidateScope: candidateScope,
        activeScope: candidateScope,
        environmentBaselineSatisfied: true
    )
    let absentProvider = ConflictFootprintProvider { _ in .absent }
    let allThreeLoaded = SetupCommandOutput(
        standardOutput: """
        Index Refs Address Size Wired Name (Version) UUID <Linked Against>
        1 1 0xffffff 0x1000 0x1000 com.paragon-software.filesystems.ntfs (17.0.488) 11111111-1111-1111-1111-111111111111 <1 2>
        2 1 0xffffff 0x1000 0x1000 com.tuxera.filesystems.tuxera_ntfs (2023.5.23) 22222222-2222-2222-2222-222222222222 <1 2>
        3 1 0xffffff 0x1000 0x1000 com.iboysoft.filesystems.ms_ntfs (4.5.0) 33333333-3333-3333-3333-333333333333 <1 2>
        """,
        terminationStatus: 0,
        wasTruncated: false
    )
    let allThreeResult = SetupProbeEvaluator.evaluate(
        plugInKitOutputs: [:],
        systemExtensionOutput: nil,
        loadedKextOutput: allThreeLoaded,
        policy: approvedPolicy,
        environment: targetEnvironment,
        footprintProvider: absentProvider
    )
    expect(
        allThreeResult.conflictScanComplete,
        "an approved exact scope should complete only with matching platform, baseline and scans"
    )
    expect(
        allThreeResult.conflictingDriverIdentifiers.count == 3
            && allThreeResult.installedConflictCount == 0,
        "all three exact loaded identifiers should map to three opaque conflict records"
    )
    expect(
        allThreeResult.conflictingDriverIdentifiers.allSatisfy {
            !$0.contains("paragon") && !$0.contains("tuxera") && !$0.contains("iboysoft")
        },
        "probe output must not expose vendor identifiers"
    )

    let unapprovedResult = SetupProbeEvaluator.evaluate(
        plugInKitOutputs: [:],
        systemExtensionOutput: nil,
        loadedKextOutput: allThreeLoaded,
        policy: currentPolicy,
        environment: targetEnvironment,
        footprintProvider: absentProvider
    )
    expect(
        !unapprovedResult.conflictScanComplete
            && unapprovedResult.conflictingDriverIdentifiers.count == 3,
        "the current unapproved policy should detect known conflicts without claiming completeness"
    )

    let legacyFootprint = "/Library/Filesystems/fusefs_txantfs.fs"
    expect(
        candidateScope.artifacts.flatMap(\.installedFootprints).contains {
            $0.absolutePath == legacyFootprint
        },
        "the bounded catalog should retain the documented legacy installed footprint"
    )
    let benignLoadedOutput = SetupCommandOutput(
        standardOutput: """
        Index Refs Address Size Wired Name (Version) UUID <Linked Against>
        1 1 0xffffff 0x1000 0x1000 com.apple.filesystems.apfs (1.0.0) 44444444-4444-4444-4444-444444444444 <1 2>
        """,
        terminationStatus: 0,
        wasTruncated: false
    )
    let legacyProvider = ConflictFootprintProvider { footprint in
        footprint.absolutePath == legacyFootprint ? .presentConflict : .absent
    }
    let legacyResult = SetupProbeEvaluator.evaluate(
        plugInKitOutputs: [:],
        systemExtensionOutput: nil,
        loadedKextOutput: benignLoadedOutput,
        policy: approvedPolicy,
        environment: targetEnvironment,
        footprintProvider: legacyProvider
    )
    expect(
        legacyResult.conflictScanComplete
            && legacyResult.installedConflictCount == 1
            && legacyResult.conflictingDriverIdentifiers.count == 1,
        "a legacy installed footprint should block as one opaque conflict without making the scan incomplete"
    )

    guard let firstFootprint = candidateScope.artifacts.first?.installedFootprints.first else {
        fatalError("CHECK FAILED: every candidate artifact should have a fixed footprint")
    }
    let incompleteReasons: [ConflictFootprintIncompleteReason] = [
        .symbolicLink,
        .notDirectory,
        .permissionDenied,
        .changedDuringRead,
        .metadataUnavailable,
    ]
    for reason in incompleteReasons {
        let provider = ConflictFootprintProvider { footprint in
            footprint == firstFootprint ? .incomplete(reason) : .absent
        }
        let result = SetupProbeEvaluator.evaluate(
            plugInKitOutputs: [:],
            systemExtensionOutput: nil,
            loadedKextOutput: benignLoadedOutput,
            policy: approvedPolicy,
            environment: targetEnvironment,
            footprintProvider: provider
        )
        expect(
            !result.conflictScanComplete,
            "symlink, type, permission and race uncertainty must each fail the footprint scan closed"
        )
    }

    guard let firstArtifact = candidateScope.artifacts.first else {
        fatalError("CHECK FAILED: the candidate scope should contain artifacts")
    }
    func scopeReplacingFirstArtifact(
        with replacement: ConflictCatalogArtifact
    ) -> ConflictCatalogScope {
        ConflictCatalogScope(
            scopeID: candidateScope.scopeID,
            target: candidateScope.target,
            evidenceDate: candidateScope.evidenceDate,
            artifacts: [replacement] + candidateScope.artifacts.dropFirst()
        )
    }
    func evaluateWithActiveScope(_ activeScope: ConflictCatalogScope) -> SetupProbeResult {
        SetupProbeEvaluator.evaluate(
            plugInKitOutputs: [:],
            systemExtensionOutput: nil,
            loadedKextOutput: benignLoadedOutput,
            policy: SetupProbePolicy(
                acceptedFSKitIdentifiers: [],
                candidateScope: candidateScope,
                activeScope: activeScope,
                environmentBaselineSatisfied: true
            ),
            environment: targetEnvironment,
            footprintProvider: absentProvider
        )
    }
    let changedVersion = ConflictCatalogArtifact(
        artifactID: firstArtifact.artifactID,
        version: SemanticVersion(
            major: firstArtifact.version.major,
            minor: firstArtifact.version.minor,
            patch: firstArtifact.version.patch + 1
        ),
        sha256: firstArtifact.sha256,
        loadedSystemExtensionIdentifiers: firstArtifact.loadedSystemExtensionIdentifiers,
        loadedKextIdentifiers: firstArtifact.loadedKextIdentifiers,
        installedFootprints: firstArtifact.installedFootprints
    )
    expect(
        !evaluateWithActiveScope(scopeReplacingFirstArtifact(with: changedVersion))
            .conflictScanComplete,
        "an artifact version change should make the active scope mismatch"
    )
    let changedDigest = ConflictCatalogArtifact(
        artifactID: firstArtifact.artifactID,
        version: firstArtifact.version,
        sha256: Data(repeating: 0xA5, count: 32),
        loadedSystemExtensionIdentifiers: firstArtifact.loadedSystemExtensionIdentifiers,
        loadedKextIdentifiers: firstArtifact.loadedKextIdentifiers,
        installedFootprints: firstArtifact.installedFootprints
    )
    expect(
        !evaluateWithActiveScope(scopeReplacingFirstArtifact(with: changedDigest))
            .conflictScanComplete,
        "an artifact digest change should make the active scope mismatch"
    )
    let scopeIDMismatch = ConflictCatalogScope(
        scopeID: "different-bounded-scope",
        target: candidateScope.target,
        evidenceDate: candidateScope.evidenceDate,
        artifacts: candidateScope.artifacts
    )
    expect(
        !evaluateWithActiveScope(scopeIDMismatch).conflictScanComplete,
        "a different scope identity must not activate the candidate"
    )

    let platformMismatch = SetupProbeEvaluator.evaluate(
        plugInKitOutputs: [:],
        systemExtensionOutput: nil,
        loadedKextOutput: benignLoadedOutput,
        policy: approvedPolicy,
        environment: ConflictCatalogEnvironment(
            macOSVersion: candidateScope.target.macOSVersion,
            architecture: .intel
        ),
        footprintProvider: absentProvider
    )
    expect(!platformMismatch.conflictScanComplete, "a platform mismatch must fail closed")

    let operatingSystemMismatch = SetupProbeEvaluator.evaluate(
        plugInKitOutputs: [:],
        systemExtensionOutput: nil,
        loadedKextOutput: benignLoadedOutput,
        policy: approvedPolicy,
        environment: ConflictCatalogEnvironment(
            macOSVersion: SemanticVersion(
                major: candidateScope.target.macOSVersion.major,
                minor: candidateScope.target.macOSVersion.minor,
                patch: candidateScope.target.macOSVersion.patch + 1
            ),
            architecture: candidateScope.target.architecture
        ),
        footprintProvider: absentProvider
    )
    expect(
        !operatingSystemMismatch.conflictScanComplete,
        "an operating-system target change must make the candidate scope mismatch"
    )

    let missingBaseline = SetupProbeEvaluator.evaluate(
        plugInKitOutputs: [:],
        systemExtensionOutput: nil,
        loadedKextOutput: benignLoadedOutput,
        policy: SetupProbePolicy(
            acceptedFSKitIdentifiers: [],
            candidateScope: candidateScope,
            activeScope: candidateScope,
            environmentBaselineSatisfied: false
        ),
        environment: targetEnvironment,
        footprintProvider: absentProvider
    )
    expect(!missingBaseline.conflictScanComplete, "a missing environment baseline must fail closed")

    let truncatedLoadedScan = SetupProbeEvaluator.evaluate(
        plugInKitOutputs: [:],
        systemExtensionOutput: nil,
        loadedKextOutput: SetupCommandOutput(
            standardOutput: benignLoadedOutput.standardOutput,
            terminationStatus: 0,
            wasTruncated: true
        ),
        policy: approvedPolicy,
        environment: targetEnvironment,
        footprintProvider: absentProvider
    )
    expect(!truncatedLoadedScan.conflictScanComplete, "truncated loaded output must fail closed")

    let unknownLoadedRecord = SetupProbeEvaluator.evaluate(
        plugInKitOutputs: [:],
        systemExtensionOutput: nil,
        loadedKextOutput: SetupCommandOutput(
            standardOutput: "unknown loaded record\n",
            terminationStatus: 0,
            wasTruncated: false
        ),
        policy: approvedPolicy,
        environment: targetEnvironment,
        footprintProvider: absentProvider
    )
    expect(!unknownLoadedRecord.conflictScanComplete, "unknown loaded records must fail closed")
}

func liveConflictFootprintProviderUsesNoFollowTriStateTraversal() {
    let fileManager = FileManager.default
    let fixtureRoot = URL(
        fileURLWithPath: "/private/tmp",
        isDirectory: true
    ).appendingPathComponent(
        "ntfs-lite-conflict-footprint-\(UUID().uuidString)",
        isDirectory: true
    )
    defer {
        try? fileManager.removeItem(at: fixtureRoot)
    }

    do {
        try fileManager.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        let existingBundle = fixtureRoot.appendingPathComponent("existing.bundle", isDirectory: true)
        try fileManager.createDirectory(at: existingBundle, withIntermediateDirectories: false)
        let wrongIdentifierPlist = existingBundle.appendingPathComponent("Info.plist")
        try Data("CFBundleIdentifier=com.example.wrong\n".utf8).write(to: wrongIdentifierPlist)

        let provider = ConflictFootprintProvider.live
        let expectedIdentifier = "com.example.expected"
        expect(
            provider.observe(
                InstalledConflictFootprint(
                    absolutePath: fixtureRoot.appendingPathComponent("absent.bundle").path,
                    expectedBundleIdentifier: expectedIdentifier
                )
            ) == .absent,
            "a no-follow traversal should distinguish a confirmed missing terminal"
        )
        expect(
            provider.observe(
                InstalledConflictFootprint(
                    absolutePath: existingBundle.path,
                    expectedBundleIdentifier: expectedIdentifier
                )
            ) == .presentConflict,
            "any terminal content, including a wrong bundle identifier, must remain a conflict"
        )

        let symbolicLink = fixtureRoot.appendingPathComponent("linked.bundle")
        try fileManager.createSymbolicLink(
            atPath: symbolicLink.path,
            withDestinationPath: existingBundle.path
        )
        expect(
            provider.observe(
                InstalledConflictFootprint(
                    absolutePath: symbolicLink.path,
                    expectedBundleIdentifier: expectedIdentifier
                )
            ) == .incomplete(.symbolicLink),
            "a terminal symbolic link must block without being reported absent"
        )

        let nonDirectory = fixtureRoot.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: nonDirectory)
        expect(
            provider.observe(
                InstalledConflictFootprint(
                    absolutePath: nonDirectory.path,
                    expectedBundleIdentifier: expectedIdentifier
                )
            ) == .presentConflict,
            "terminal content with an unexpected type must still block as a conflict"
        )
        expect(
            provider.observe(
                InstalledConflictFootprint(
                    absolutePath: nonDirectory
                        .appendingPathComponent("child.bundle")
                        .path,
                    expectedBundleIdentifier: expectedIdentifier
                )
            ) == .incomplete(.notDirectory),
            "a non-directory traversal component must fail closed"
        )
        expect(
            provider.observe(
                InstalledConflictFootprint(
                    absolutePath: "relative/path",
                    expectedBundleIdentifier: expectedIdentifier
                )
            ) == .incomplete(.invalidPolicy),
            "an invalid non-absolute footprint policy must fail closed"
        )
    } catch {
        fatalError("CHECK FAILED: could not prepare conflict footprint fixtures")
    }
}

func systemSetupLoaderConsumesTheInjectedScopedFootprintEvidence() async {
    guard let datedScope = SetupProbePolicy.current.candidateScope else {
        fatalError("CHECK FAILED: the current policy should retain its dated scope")
    }
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
    let architecture: RuntimeArchitecture
#if arch(arm64)
    architecture = .appleSilicon
#elseif arch(x86_64)
    architecture = .intel
#else
    architecture = .unknown
#endif
    let runtimeScope = ConflictCatalogScope(
        scopeID: "fixture-runtime-scope",
        target: ConflictCatalogTarget(
            macOSVersion: SemanticVersion(
                major: operatingSystem.majorVersion,
                minor: operatingSystem.minorVersion,
                patch: operatingSystem.patchVersion
            ),
            architecture: architecture
        ),
        evidenceDate: datedScope.evidenceDate,
        artifacts: datedScope.artifacts
    )
    let legacyFootprint = "/Library/Filesystems/fusefs_txantfs.fs"
    let loader = SystemSetupFactsLoader(
        commandProvider: SetupReadOnlyCommandProvider { command in
            switch command {
            case .loadedKexts:
                SetupCommandOutput(
                    standardOutput: """
                    Index Refs Address Size Wired Name (Version) UUID <Linked Against>
                    1 1 0xffffff 0x1000 0x1000 com.apple.filesystems.apfs (1.0.0) 55555555-5555-5555-5555-555555555555 <1 2>
                    """,
                    terminationStatus: 0,
                    wasTruncated: false
                )
            case .plugInKit, .systemExtensions:
                SetupCommandOutput(
                    standardOutput: "",
                    terminationStatus: 1,
                    wasTruncated: false
                )
            }
        },
        probePolicy: SetupProbePolicy(
            acceptedFSKitIdentifiers: [],
            candidateScope: runtimeScope,
            activeScope: runtimeScope,
            environmentBaselineSatisfied: true
        ),
        conflictFootprintProvider: ConflictFootprintProvider { footprint in
            footprint.absolutePath == legacyFootprint ? .presentConflict : .absent
        }
    )
    let report = await loader.currentReport()
    expect(
        report.probeResult.conflictScanComplete
            && report.facts.conflictScanComplete
            && report.probeResult.installedConflictCount == 1
            && report.facts.conflictingDrivers == ["known-conflict-2"],
        "the system loader should combine its runtime target with injected read-only footprint evidence"
    )
}

func diagnosticProjectionDropsRawDomainPoisonValues() async {
    let poison = "/Users/private-user/Volumes/SECRET-disk99-UUID"
    let facts = SetupFacts(
        macOSVersion: SemanticVersion(major: 26, minor: 6, patch: 2),
        architecture: .appleSilicon,
        macFUSEVersion: nil,
        ntfs3GVersion: nil,
        fileSystemExtensionEnabled: false,
        selectedBackend: .fsKit,
        authorizationStatus: .unknown,
        conflictScanComplete: false,
        conflictingDrivers: [poison]
    )
    let assessment = SetupChecker.assess(facts)
    let evidence = ReadOnlyVolumeEvidence(
        bsdName: poison,
        volumeUUID: poison,
        physicalDiskBSDName: poison,
        displayName: poison,
        fileSystemName: "ntfs",
        isInternal: false,
        roleEvidence: .unknown,
        diskArbitrationMountPoint: poison
    )
    let disk = ReadOnlyPhysicalDiskRecord(
        instanceID: DiskInstanceID(
            physicalDiskID: PhysicalDiskID(rawValue: poison),
            mediaGeneration: MediaGeneration(rawValue: 9)
        ),
        description: DiskArbitrationDescription(
            bsdName: poison,
            physicalDiskBSDName: poison,
            isWholeDisk: true,
            isInternal: false,
            isEjectable: true,
            isRemovable: true,
            mediaSize: 100,
            mediaUUID: poison,
            volumeUUID: nil,
            volumeName: poison,
            fileSystemName: nil,
            mountPoint: poison
        ),
        volumes: [
            ReadOnlyVolumeRecord(
                evidence: evidence,
                snapshot: nil,
                mountObservation: nil,
                issues: [.missingVolumeUUID, .mountPointMismatch]
            ),
        ],
        issues: [.physicalParentMismatch(bsdName: poison)]
    )
    let observation = DiskInventoryObservation(
        physicalDisks: [disk],
        issues: [.missingPhysicalDiskDescription(childBSDName: poison)]
    )

    let diagnostics = Diagnostics(clock: { Date(timeIntervalSince1970: 456) })
    do {
        try await diagnostics.record(
            DiagnosticProjection.setup(
                facts: facts,
                assessment: assessment,
                applicationVersion: DiagnosticVersion(major: 0, minor: 1, patch: 0),
                applicationBuild: 1
            )
        )
        try await diagnostics.record(DiagnosticProjection.inventory(observation))
        let text = try await diagnostics.snapshot().copyText()
        expect(!text.contains(poison), "diagnostic projection must drop every raw poison value")
        expect(!text.contains("private-user"), "diagnostics must not retain usernames")
        expect(!text.contains("SECRET"), "diagnostics must not retain volume labels")
        expect(
            text.contains("conflictingDrivers")
                && text.contains("conflictScanIncomplete")
                && text.contains("missingPhysicalDiskDescription")
                && text.contains("mountPointMismatch"),
            "diagnostics should retain only normalized issue meaning"
        )
    } catch {
        fatalError("CHECK FAILED: typed domain diagnostics should project and encode: \(error)")
    }
}

func ntfsHealthParserAcceptsOnlyCanonicalBoundedEvidence() {
    let canonicalCases: [(String, VolumeHealth)] = [
        (NTFSHealthProbeV1OutputParser.cleanRecord, .clean),
        (NTFSHealthProbeV1OutputParser.dirtyRecord, .dirty),
        (NTFSHealthProbeV1OutputParser.hibernatedRecord, .hibernated),
        (NTFSHealthProbeV1OutputParser.unknownRecord, .unknown),
    ]
    for (record, expected) in canonicalCases {
        expect(
            NTFSHealthProbeV1OutputParser.parse(
                NTFSHealthProbeOutput(
                    completion: .exited(0),
                    standardOutput: record
                )
            ) == expected,
            "the health parser should accept only its exact versioned records"
        )
    }

    let rejectedCases: [NTFSHealthProbeOutput] = [
        NTFSHealthProbeOutput(
            completion: .exited(1),
            standardOutput: NTFSHealthProbeV1OutputParser.cleanRecord
        ),
        NTFSHealthProbeOutput(
            completion: .timedOut,
            standardOutput: NTFSHealthProbeV1OutputParser.cleanRecord
        ),
        NTFSHealthProbeOutput(
            completion: .truncated,
            standardOutput: NTFSHealthProbeV1OutputParser.cleanRecord
        ),
        NTFSHealthProbeOutput(
            completion: .unreadable,
            standardOutput: NTFSHealthProbeV1OutputParser.cleanRecord
        ),
        NTFSHealthProbeOutput(
            completion: .launchFailed,
            standardOutput: NTFSHealthProbeV1OutputParser.cleanRecord
        ),
        NTFSHealthProbeOutput(
            completion: .exited(0),
            standardOutput: NTFSHealthProbeV1OutputParser.cleanRecord,
            standardError: "warning"
        ),
        NTFSHealthProbeOutput(
            completion: .exited(0),
            standardOutput: "NTFS-LITE-HEALTH/1 clean"
        ),
        NTFSHealthProbeOutput(
            completion: .exited(0),
            standardOutput: " NTFS-LITE-HEALTH/1 clean\n"
        ),
        NTFSHealthProbeOutput(
            completion: .exited(0),
            standardOutput: "NTFS-LITE-HEALTH/1 healthy\n"
        ),
        NTFSHealthProbeOutput(
            completion: .exited(0),
            standardOutput: "NTFS-LITE-HEALTH/1 clean\nNTFS-LITE-HEALTH/1 dirty\n"
        ),
        NTFSHealthProbeOutput(
            completion: .exited(0),
            standardOutput: "NTFS-LITE-HEALTH/1 clean\u{0}\n"
        ),
        NTFSHealthProbeOutput(
            completion: .exited(0),
            standardOutput: String(repeating: "x", count: 129)
        ),
    ]
    for output in rejectedCases {
        expect(
            NTFSHealthProbeV1OutputParser.parse(output) == .unknown,
            "ambiguous, incomplete, failed, or oversized health evidence must fail closed"
        )
    }
}

func safeMountCompilerEmitsOnlyTheFixedValidatedInvocation() {
    func plan(
        operation: String = "mount-1",
        uuid: String = "ARCHIVE-UUID",
        physicalDisk: String = "disk9",
        bsdName: String = "disk9s1",
        generation: UInt64 = 1
    ) -> MountPlan {
        MountPlan(
            operationID: OperationID(rawValue: operation),
            target: VolumeInstanceID(
                volumeID: VolumeID(uuid: uuid, bsdName: bsdName),
                diskInstanceID: DiskInstanceID(
                    physicalDiskID: PhysicalDiskID(rawValue: physicalDisk),
                    mediaGeneration: MediaGeneration(rawValue: generation)
                )
            ),
            policy: .fsKitCurrentUserNoRecovery
        )
    }

    let fileManager = FileManager.default
    let fixtureRoot = URL(
        fileURLWithPath: "/private/tmp",
        isDirectory: true
    ).appendingPathComponent(
        "ntfs-lite-mount-capability-\(UUID().uuidString)",
        isDirectory: true
    )
    let binURL = fixtureRoot.appendingPathComponent("bin", isDirectory: true)
    let executableURL = binURL.appendingPathComponent("ntfs-3g", isDirectory: false)
    let fixtureData = Data("ntfs-lite-fixture\n".utf8)
    let fixtureDigest = "13979bdc7701f20c912d88b31e6a9a71e90ddf2550242d6731e90a44ddd54c3f"
    let pinnedVersion = SemanticVersion(major: 2026, minor: 7, patch: 7)

    do {
        try fileManager.createDirectory(at: binURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: fixtureRoot)
        }
        try fixtureData.write(to: executableURL)
        guard chmod(executableURL.path, 0o700) == 0 else {
            fatalError("CHECK FAILED: could not prepare mount capability fixture")
        }

        func artifactPolicy(
            digests: Set<String> = [fixtureDigest]
        ) -> TrustedNTFS3GArtifactPolicy {
            TrustedNTFS3GArtifactPolicy(
                executablePolicy: TrustedExecutablePolicy(
                    executablePath: executableURL.path,
                    expectedBasename: "ntfs-3g",
                    expectedOwnerUID: getuid(),
                    maximumBytes: 1_024,
                    allowedSHA256Digests: digests
                ),
                versionsBySHA256Digest: Dictionary(
                    uniqueKeysWithValues: digests.map { ($0, pinnedVersion) }
                )
            )
        }

        let trustedArtifact: TrustedNTFS3GArtifactCapability
        switch TrustedNTFS3GArtifactCapabilityResolver.resolve(
            policy: artifactPolicy()
        ) {
        case let .success(capability):
            trustedArtifact = capability
            expect(
                capability.executableURL.path == executableURL.path
                    && capability.sha256Digest == fixtureDigest
                    && capability.byteCount == fixtureData.count
                    && capability.version == pinnedVersion,
                "the capability must bind verified path, digest, byte count, and version"
            )
        case let .failure(error):
            fatalError("CHECK FAILED: trusted fixture failed capability resolution: \(error)")
        }

        expect(
            TrustedNTFS3GArtifactCapabilityResolver.resolve(
                policy: artifactPolicy(digests: [String(repeating: "0", count: 64)])
            ) == .failure(.verificationFailed(.executable(.digestNotAllowed))),
            "an unpinned artifact must not produce a mount compiler capability"
        )

        let compiler = SafeMountInvocationCompiler(trustedArtifact: trustedArtifact)
        let invocation: SafeMountInvocation
        switch compiler.compile(
            plan: plan(),
            mountPointURL: URL(fileURLWithPath: "/Volumes/ARCHIVE", isDirectory: true)
        ) {
        case let .success(compiled):
            invocation = compiled
            expect(
                compiled.executableURL.path == executableURL.path,
                "the mount compiler should retain only the verified ntfs-3g artifact"
            )
            expect(
                compiled.arguments
                    == [
                        "/dev/disk9s1",
                        "/Volumes/ARCHIVE",
                        "-o",
                        "rw,no_def_opts,backend=fskit,norecover",
                    ],
                "the mount compiler should emit the fixed FSKit no-recovery invocation"
            )
            let optionTokens = Set(
                compiled.arguments[3].split(separator: ",").map(String.init)
            )
            expect(
                optionTokens == ["rw", "no_def_opts", "backend=fskit", "norecover"],
                "the mount invocation must contain exactly the approved option tokens"
            )
            expect(
                optionTokens.isDisjoint(
                    with: ["force", "recover", "remove_hiberfile", "allow_other"]
                ),
                "the mount invocation must never contain dangerous or cross-user options"
            )
            expect(
                compiled.executionArtifactGate.revalidateImmediatelyBeforeExecution(),
                "the execution-side artifact gate should accept unchanged verified bytes"
            )
        case let .failure(error):
            fatalError("CHECK FAILED: the valid safe mount fixture was rejected: \(error)")
        }

        expect(
            compiler.compile(
                plan: plan(physicalDisk: "diskX"),
                mountPointURL: URL(fileURLWithPath: "/Volumes/ARCHIVE")
            ) == .failure(.invalidPhysicalDiskIdentity),
            "the compiler must reject a malformed whole-disk identity"
        )
        expect(
            compiler.compile(
                plan: plan(bsdName: "disk10s1"),
                mountPointURL: URL(fileURLWithPath: "/Volumes/ARCHIVE")
            ) == .failure(.targetDeviceDoesNotBelongToPhysicalDisk),
            "the compiler must reject a target from another physical disk"
        )
        expect(
            compiler.compile(
                plan: plan(generation: 0),
                mountPointURL: URL(fileURLWithPath: "/Volumes/ARCHIVE")
            ) == .failure(.invalidPhysicalDiskIdentity),
            "the compiler must reject an unversioned media instance"
        )
        for invalidPath in ["/tmp/ARCHIVE", "/Volumes/A/B", "/Volumes/A\nB"] {
            expect(
                compiler.compile(
                    plan: plan(),
                    mountPointURL: URL(fileURLWithPath: invalidPath)
                ) == .failure(.invalidMountPoint),
                "the compiler must reject mount points outside one direct /Volumes child"
            )
        }
        expect(
            compiler.compile(
                plan: plan(operation: " "),
                mountPointURL: URL(fileURLWithPath: "/Volumes/ARCHIVE")
            ) == .failure(.invalidOperationID),
            "the compiler must reject an empty or padded operation identity"
        )
        expect(
            compiler.compile(
                plan: plan(uuid: ""),
                mountPointURL: URL(fileURLWithPath: "/Volumes/ARCHIVE")
            ) == .failure(.invalidVolumeIdentity),
            "the compiler must reject a missing volume identity"
        )

        try Data("changed-artifact\n".utf8).write(to: executableURL)
        guard chmod(executableURL.path, 0o700) == 0 else {
            fatalError("CHECK FAILED: could not prepare changed artifact fixture")
        }
        expect(
            compiler.compile(
                plan: plan(),
                mountPointURL: URL(fileURLWithPath: "/Volumes/ARCHIVE")
            ) == .failure(.trustedArtifactChanged),
            "the compiler must reverify and reject an artifact changed after capability issue"
        )
        expect(
            !invocation.executionArtifactGate.revalidateImmediatelyBeforeExecution(),
            "the explicit execution-side gate must fail closed after artifact replacement"
        )
    } catch {
        fatalError("CHECK FAILED: mount capability fixtures failed: \(error)")
    }
}

func helperProtocolRoundTripsOnlyStrictStructuredRequests() async {
    do {
        let disk = try HelperDiskInstanceIdentity(
            physicalDiskBSDName: "disk9",
            mediaGeneration: 7
        )
        let volume = try HelperVolumeInstanceIdentity(
            volumeUUID: "11111111-1111-1111-1111-111111111111",
            volumeBSDName: "disk9s1",
            disk: disk
        )
        let fixtures: [(HelperAction, HelperTarget, String)] = [
            (.mountReadWrite, .volume(volume), "helper-mount-1"),
            (.unmountVolume, .volume(volume), "helper-unmount-1"),
            (.unmountDisk, .disk(disk), "helper-unmount-disk-1"),
            (.ejectDisk, .disk(disk), "helper-eject-1"),
        ]
        let encoder = JSONEncoder()
        let admission = HelperRequestAdmission.processLifetime

        for (action, target, operationText) in fixtures {
            let request = try HelperRequestEnvelope(
                operationID: HelperOperationID(validating: operationText),
                action: action,
                target: target
            )
            let data = try encoder.encode(request)
            switch await admission.admit(data) {
            case let .success(admitted):
                expect(
                    admitted.operationID == request.operationID
                        && admitted.action == action
                        && admitted.target == target,
                    "each helper action should enter only through atomic admission"
                )
            case let .failure(rejection):
                fatalError(
                    "CHECK FAILED: valid helper action was rejected: \(rejection)"
                )
            }
        }

        let validDiskJSON = """
        {"schemaVersion":1,"operationID":"helper-eject-2","action":"ejectDisk","target":{"kind":"disk","disk":{"physicalDiskBSDName":"disk9","mediaGeneration":7}}}
        """
        guard var envelope = try JSONSerialization.jsonObject(
            with: Data(validDiskJSON.utf8)
        ) as? [String: Any] else {
            fatalError("CHECK FAILED: helper JSON fixture should be a dictionary")
        }
        for forbiddenField in ["command", "arguments", "path"] {
            envelope[forbiddenField] = forbiddenField == "arguments" ? ["--force"] : "/bin/sh"
            let data = try JSONSerialization.data(withJSONObject: envelope)
            await expectAsync(
                await admission.admit(data) == .failure(.unexpectedField),
                "helper envelopes must reject the forbidden \(forbiddenField) field"
            )
            envelope.removeValue(forKey: forbiddenField)
        }

        let rejectionFixtures: [(String, HelperRequestRejection)] = [
            (
                validDiskJSON.replacingOccurrences(
                    of: "\"schemaVersion\":1",
                    with: "\"schemaVersion\":2"
                ),
                .unsupportedSchemaVersion
            ),
            (
                validDiskJSON.replacingOccurrences(
                    of: "\"ejectDisk\"",
                    with: "\"formatDisk\""
                ),
                .unknownAction
            ),
            (
                validDiskJSON.replacingOccurrences(
                    of: "helper-eject-2",
                    with: "bad operation id"
                ),
                .invalidOperationID
            ),
            (
                """
                {"schemaVersion":1,"operationID":"helper-mismatch","action":"mountReadWrite","target":{"kind":"disk","disk":{"physicalDiskBSDName":"disk9","mediaGeneration":7}}}
                """,
                .actionTargetMismatch
            ),
            (
                """
                {"schemaVersion":1,"operationID":"helper-invalid-volume","action":"unmountVolume","target":{"kind":"volume","volume":{"volumeUUID":"11111111-1111-1111-1111-111111111111","volumeBSDName":"disk9s1s2","disk":{"physicalDiskBSDName":"disk9","mediaGeneration":7}}}}
                """,
                .invalidIdentity
            ),
            (
                """
                {"schemaVersion":1,"operationID":"helper-nested-extra","action":"ejectDisk","target":{"kind":"disk","disk":{"physicalDiskBSDName":"disk9","mediaGeneration":7,"path":"/dev/disk9"}}}
                """,
                .unexpectedField
            ),
        ]
        for (json, expected) in rejectionFixtures {
            await expectAsync(
                await admission.admit(Data(json.utf8)) == .failure(expected),
                "invalid helper request evidence should retain rejection code \(expected)"
            )
        }
        await expectAsync(
            await admission.admit(Data("{}".utf8)) == .failure(.malformedEnvelope),
            "a missing helper envelope must fail closed"
        )
        await expectAsync(
            await admission.admit(
                Data(repeating: 0x41, count: HelperProtocolLimits.maximumRequestBytes + 1)
            ) == .failure(.malformedEnvelope),
            "an oversized helper envelope must fail before decoding"
        )

        let response = HelperResponseEnvelope(resultCode: .succeeded, exitStatus: 0)
        let responseData = try encoder.encode(response)
        guard let responseObject = try JSONSerialization.jsonObject(
            with: responseData
        ) as? [String: Any] else {
            fatalError("CHECK FAILED: helper response should encode as an object")
        }
        expect(
            Set(responseObject.keys) == ["schemaVersion", "resultCode", "exitStatus"],
            "helper responses must contain exactly the three numeric protocol fields"
        )
        expect(
            responseObject.values.allSatisfy { $0 is NSNumber },
            "helper responses must not leak text, paths, identifiers, or stderr"
        )
        let decodedResponse = try JSONDecoder().decode(
            HelperResponseEnvelope.self,
            from: responseData
        )
        expect(
            decodedResponse == response,
            "the minimal helper response should round-trip"
        )

        let responseDecoder = HelperResponseDecoder()
        expect(
            responseDecoder.decode(responseData) == .success(response),
            "the bounded response decoder should accept a canonical success"
        )
        for validResponse in [
            HelperResponseEnvelope(resultCode: .executionFailed, exitStatus: 5),
            HelperResponseEnvelope(resultCode: .postconditionFailed, exitStatus: 0),
        ] {
            let data = try encoder.encode(validResponse)
            expect(
                responseDecoder.decode(data) == .success(validResponse),
                "fixed failure responses should preserve their numeric semantics"
            )
        }
        let invalidResponseFixtures: [(String, HelperResponseRejection)] = [
            (
                "{\"schemaVersion\":2,\"resultCode\":0,\"exitStatus\":0}",
                .unsupportedSchemaVersion
            ),
            (
                "{\"schemaVersion\":1,\"resultCode\":999,\"exitStatus\":1}",
                .unknownResultCode
            ),
            (
                "{\"schemaVersion\":1,\"resultCode\":0,\"exitStatus\":1}",
                .invalidResultSemantics
            ),
            (
                "{\"schemaVersion\":1,\"resultCode\":10,\"exitStatus\":0}",
                .invalidResultSemantics
            ),
            (
                "{\"schemaVersion\":1,\"resultCode\":20,\"exitStatus\":0}",
                .invalidResultSemantics
            ),
            (
                "{\"schemaVersion\":1,\"resultCode\":0,\"exitStatus\":0,\"stderr\":\"secret\"}",
                .unexpectedField
            ),
        ]
        for (json, expectedRejection) in invalidResponseFixtures {
            expect(
                responseDecoder.decode(Data(json.utf8))
                    == .failure(expectedRejection),
                "invalid helper responses should expose one fixed response rejection"
            )
        }
        expect(
            responseDecoder.decode(Data()) == .failure(.malformedEnvelope),
            "an empty helper response must fail closed"
        )
        expect(
            responseDecoder.decode(
                Data(
                    repeating: 0x30,
                    count: HelperProtocolLimits.maximumResponseBytes + 1
                )
            ) == .failure(.responseTooLarge),
            "an oversized helper response must fail before decoding"
        )
        do {
            _ = try encoder.encode(
                HelperResponseEnvelope(resultCode: .succeeded, exitStatus: 1)
            )
            fatalError("CHECK FAILED: an invalid success response must not encode")
        } catch let rejection as HelperResponseRejection {
            expect(
                rejection == .invalidResultSemantics,
                "invalid response construction should fail with a fixed semantic reason"
            )
        }
    } catch {
        fatalError("CHECK FAILED: strict helper protocol fixtures should construct: \(error)")
    }
}

func trustedBundleVersionReaderRejectsUntrustedFilesystemEvidence() async {
    let fileManager = FileManager.default
    let canonicalTemporaryDirectory = URL(
        fileURLWithPath: "/private/tmp",
        isDirectory: true
    )
    let fixtureRoot = canonicalTemporaryDirectory.appendingPathComponent(
        "ntfs-lite-trusted-bundle-\(UUID().uuidString)",
        isDirectory: true
    )
    let bundleURL = fixtureRoot.appendingPathComponent(
        "macfuse.fs",
        isDirectory: true
    )
    let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
    let infoURL = contentsURL.appendingPathComponent("Info.plist", isDirectory: false)
    let expectedIdentifier = "com.example.ntfslite.fixture"

    func writeInfo(
        identifier: String = expectedIdentifier,
        version: String? = "5.3.3"
    ) throws {
        var propertyList: [String: Any] = [
            "CFBundleIdentifier": identifier,
        ]
        if let version {
            propertyList["CFBundleShortVersionString"] = version
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try data.write(to: infoURL)
        guard chmod(infoURL.path, 0o600) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    do {
        try fileManager.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: fixtureRoot)
        }
        try writeInfo()

        func policy(
            rootPath: String = bundleURL.path,
            identifier: String = expectedIdentifier,
            owner: uid_t = getuid(),
            byteLimit: Int = 4_096,
            approvedVersions: Set<SemanticVersion> = [
                SemanticVersion(major: 5, minor: 3, patch: 3),
            ]
        ) -> TrustedBundleVersionPolicy {
            TrustedBundleVersionPolicy(
                bundleRootPath: rootPath,
                expectedBundleIdentifier: identifier,
                expectedOwnerUID: owner,
                maximumInfoPlistBytes: byteLimit,
                approvedVersions: approvedVersions
            )
        }

        let validResult = TrustedBundleVersionReader.read(policy: policy())
        expect(
            validResult == .trusted(SemanticVersion(major: 5, minor: 3, patch: 3)),
            "a fixed owner-safe bundle should expose its version, got \(validResult)"
        )
        expect(
            TrustedBundleVersionReader.read(policy: policy(approvedVersions: []))
                == .failedClosed(.invalidPolicy),
            "a configured bundle policy must carry a nonempty exact-version allowlist"
        )
        let approvedTeamIdentifier = "ABCDE12345"
        let approvedCodeDirectoryHash = Data(repeating: 0xAB, count: 20)
        let signaturePolicy = TrustedCodeSignaturePolicy(
            designatedRequirement: "identifier \"\(expectedIdentifier)\" and anchor apple generic",
            expectedTeamIdentifier: approvedTeamIdentifier,
            expectedCodeDirectoryHash: approvedCodeDirectoryHash
        )
        let macFUSEPolicy = TrustedMacFUSEPolicy(
            bundleVersionPolicy: policy(),
            codeSignaturePoliciesByVersion: [
                SemanticVersion(major: 5, minor: 3, patch: 3): signaturePolicy,
            ]
        )
        func signatureProvider(
            teamIdentifier: String = approvedTeamIdentifier,
            codeDirectoryHash: Data = approvedCodeDirectoryHash,
            securedBundleIdentifier: String = expectedIdentifier,
            securedBundleVersionText: String = "5.3.3"
        ) -> TrustedCodeSignatureEvidenceProvider {
            TrustedCodeSignatureEvidenceProvider { _, _ in
                .observed(
                    TrustedCodeSignatureEvidence(
                        teamIdentifier: teamIdentifier,
                        codeDirectoryHash: codeDirectoryHash,
                        securedBundleIdentifier: securedBundleIdentifier,
                        securedBundleVersionText: securedBundleVersionText
                    )
                )
            }
        }
        expect(
            TrustedMacFUSEEvidenceReader.read(
                policy: macFUSEPolicy,
                evidenceProvider: signatureProvider()
            ) == .trusted(SemanticVersion(major: 5, minor: 3, patch: 3)),
            "exact version, requirement, team and Code Directory hash should form typed trust"
        )
        expect(
            TrustedMacFUSEEvidenceReader.read(
                policy: macFUSEPolicy,
                evidenceProvider: signatureProvider(teamIdentifier: "OTHER12345")
            ) == .failedClosed(.codeSignature(.teamIdentifierMismatch)),
            "a contradictory observed Team ID must fail closed"
        )
        expect(
            TrustedMacFUSEEvidenceReader.read(
                policy: macFUSEPolicy,
                evidenceProvider: signatureProvider(
                    codeDirectoryHash: Data(repeating: 0xCD, count: 20)
                )
            ) == .failedClosed(.codeSignature(.codeDirectoryHashMismatch)),
            "artifact Code Directory drift must fail closed"
        )
        let unavailableSignatureProvider = TrustedCodeSignatureEvidenceProvider { _, _ in
            .failedClosed(.signingInformationUnavailable)
        }
        expect(
            TrustedMacFUSEEvidenceReader.read(
                policy: macFUSEPolicy,
                evidenceProvider: unavailableSignatureProvider
            ) == .failedClosed(.codeSignature(.signingInformationUnavailable)),
            "missing signing evidence must preserve a typed failure"
        )
        expect(
            TrustedMacFUSEEvidenceReader.read(
                policy: macFUSEPolicy,
                evidenceProvider: signatureProvider(teamIdentifier: "")
            ) == .failedClosed(.codeSignature(.teamIdentifierMissing)),
            "incomplete Team ID evidence must fail closed before comparison"
        )
        expect(
            TrustedMacFUSEEvidenceReader.read(
                policy: macFUSEPolicy,
                evidenceProvider: signatureProvider(codeDirectoryHash: Data())
            ) == .failedClosed(.codeSignature(.codeDirectoryHashMissing)),
            "incomplete Code Directory hash evidence must fail closed before comparison"
        )
        let invalidSignaturePolicy = TrustedMacFUSEPolicy(
            bundleVersionPolicy: policy(),
            codeSignaturePoliciesByVersion: [
                SemanticVersion(major: 5, minor: 3, patch: 3):
                    TrustedCodeSignaturePolicy(
                        designatedRequirement: "",
                        expectedTeamIdentifier: approvedTeamIdentifier,
                        expectedCodeDirectoryHash: approvedCodeDirectoryHash
                    ),
            ]
        )
        expect(
            TrustedMacFUSEEvidenceReader.read(
                policy: invalidSignaturePolicy,
                evidenceProvider: signatureProvider()
            ) == .failedClosed(.codeSignature(.invalidPolicy)),
            "missing signature policy fields must never be treated as configured trust"
        )
        let approvedVersion = SemanticVersion(major: 5, minor: 3, patch: 3)
        let alternateVersion = SemanticVersion(major: 5, minor: 4, patch: 0)
        let alternateSignaturePolicy = TrustedCodeSignaturePolicy(
            designatedRequirement: signaturePolicy.designatedRequirement,
            expectedTeamIdentifier: approvedTeamIdentifier,
            expectedCodeDirectoryHash: Data(repeating: 0xCD, count: 20)
        )
        let missingCatalogEntry = TrustedMacFUSEPolicy(
            bundleVersionPolicy: policy(approvedVersions: [approvedVersion, alternateVersion]),
            codeSignaturePoliciesByVersion: [approvedVersion: signaturePolicy]
        )
        expect(
            TrustedMacFUSEEvidenceReader.read(
                policy: missingCatalogEntry,
                evidenceProvider: signatureProvider()
            ) == .failedClosed(.codeSignature(.invalidPolicy)),
            "every approved version must have exactly one corresponding signature policy"
        )
        let extraCatalogEntry = TrustedMacFUSEPolicy(
            bundleVersionPolicy: policy(approvedVersions: [approvedVersion]),
            codeSignaturePoliciesByVersion: [
                approvedVersion: signaturePolicy,
                alternateVersion: alternateSignaturePolicy,
            ]
        )
        expect(
            TrustedMacFUSEEvidenceReader.read(
                policy: extraCatalogEntry,
                evidenceProvider: signatureProvider()
            ) == .failedClosed(.codeSignature(.invalidPolicy)),
            "a signature policy for an unapproved version must invalidate the catalog"
        )
        let sharedSignatureIdentity = TrustedMacFUSEPolicy(
            bundleVersionPolicy: policy(approvedVersions: [approvedVersion, alternateVersion]),
            codeSignaturePoliciesByVersion: [
                approvedVersion: signaturePolicy,
                alternateVersion: signaturePolicy,
            ]
        )
        expect(
            TrustedMacFUSEEvidenceReader.read(
                policy: sharedSignatureIdentity,
                evidenceProvider: signatureProvider()
            ) == .failedClosed(.codeSignature(.invalidPolicy)),
            "two versions must never share one Code Directory identity"
        )
        expect(
            TrustedMacFUSEEvidenceReader.read(
                policy: macFUSEPolicy,
                evidenceProvider: signatureProvider(securedBundleIdentifier: "")
            ) == .failedClosed(.codeSignature(.securedBundleIdentifierMissing)),
            "a missing secured bundle identifier must fail closed"
        )
        expect(
            TrustedMacFUSEEvidenceReader.read(
                policy: macFUSEPolicy,
                evidenceProvider: signatureProvider(securedBundleVersionText: "")
            ) == .failedClosed(.codeSignature(.securedBundleVersionMissing)),
            "a missing secured bundle version must fail closed"
        )
        expect(
            TrustedMacFUSEEvidenceReader.read(
                policy: macFUSEPolicy,
                evidenceProvider: signatureProvider(securedBundleVersionText: "05.3.3")
            ) == .failedClosed(.codeSignature(.securedBundleVersionInvalid)),
            "a noncanonical secured bundle version must fail closed"
        )
        expect(
            TrustedMacFUSEEvidenceReader.read(
                policy: macFUSEPolicy,
                evidenceProvider: signatureProvider(
                    securedBundleIdentifier: "com.example.ntfslite.replacement"
                )
            ) == .failedClosed(.codeSignature(.securedBundleIdentifierMismatch)),
            "the secured identifier must match the filesystem bundle policy"
        )
        expect(
            TrustedMacFUSEEvidenceReader.read(
                policy: macFUSEPolicy,
                evidenceProvider: signatureProvider(securedBundleVersionText: "5.4.0")
            ) == .failedClosed(.codeSignature(.securedBundleVersionMismatch)),
            "the secured version must match the filesystem version and selected catalog entry"
        )
        let missingSecuredInfoProvider = TrustedCodeSignatureEvidenceProvider { _, _ in
            .failedClosed(.securedInfoPlistMissing)
        }
        expect(
            TrustedMacFUSEEvidenceReader.read(
                policy: macFUSEPolicy,
                evidenceProvider: missingSecuredInfoProvider
            ) == .failedClosed(.codeSignature(.securedInfoPlistMissing)),
            "missing Code Signing Services Info.plist evidence must retain its typed failure"
        )
        let loader = SystemSetupFactsLoader(
            commandProvider: SetupReadOnlyCommandProvider { _ in
                SetupCommandOutput(
                    standardOutput: "",
                    terminationStatus: 1,
                    wasTruncated: false
                )
            },
            probePolicy: .unconfigured(),
            macFUSEPolicy: macFUSEPolicy,
            macFUSECodeSignatureEvidenceProvider: signatureProvider()
        )
        let mappedFacts = await loader.currentFacts()
        expect(
            mappedFacts.macFUSEVersion
                == SemanticVersion(major: 5, minor: 3, patch: 3),
            "the setup loader should consume only a trusted bundle version result"
        )
        let alternateFixtureVersion = SemanticVersion(major: 5, minor: 4, patch: 0)
        try writeInfo(version: "5.4.0")
        expect(
            TrustedBundleVersionReader.read(policy: policy())
                == .failedClosed(.versionNotApproved),
            "a newer but unapproved exact bundle version must fail closed"
        )
        let unapprovedReport = await loader.currentReport()
        expect(
            unapprovedReport.macFUSEEvidence
                == .failedClosed(.bundle(.versionNotApproved))
                && unapprovedReport.facts.macFUSEVersion == nil,
            "the setup loader must not flatten an unapproved bundle version into facts"
        )
        expect(
            TrustedBundleVersionReader.read(
                policy: policy(approvedVersions: [alternateFixtureVersion])
            ) == .trusted(alternateFixtureVersion),
            "a fixture version should be trusted only when that exact value is approved"
        )
        try writeInfo()
        expect(
            TrustedBundleVersionReader.read(
                policy: policy(identifier: "com.example.unrelated")
            ) == .failedClosed(.bundleIdentifierMismatch),
            "the bundle reader must reject an unexpected bundle identity"
        )
        expect(
            TrustedBundleVersionReader.read(
                policy: policy(rootPath: "relative/macfuse.fs")
            ) == .failedClosed(.invalidAbsoluteBundlePath),
            "the bundle reader must reject non-absolute paths"
        )
        expect(
            TrustedBundleVersionReader.read(
                policy: policy(rootPath: bundleURL.path + "/../macfuse.fs")
            ) == .failedClosed(.invalidAbsoluteBundlePath),
            "the bundle reader must reject dot segments rather than normalizing them"
        )

        let differentOwner = getuid() == uid_t.max ? getuid() - 1 : getuid() + 1
        expect(
            TrustedBundleVersionReader.read(policy: policy(owner: differentOwner))
                == .failedClosed(.ownerMismatch),
            "the bundle reader must reject an owner mismatch"
        )
        expect(
            TrustedBundleVersionReader.read(policy: policy(byteLimit: 8))
                == .failedClosed(.infoPlistTooLarge),
            "the bundle reader must reject a plist above the configured bound"
        )

        guard chmod(infoURL.path, 0o660) == 0 else {
            fatalError("CHECK FAILED: could not prepare unsafe-permission fixture")
        }
        expect(
            TrustedBundleVersionReader.read(policy: policy())
                == .failedClosed(.unsafeWritePermissions),
            "the bundle reader must reject group-writable metadata"
        )
        try writeInfo(version: "05.3.3")
        expect(
            TrustedBundleVersionReader.read(policy: policy())
                == .failedClosed(.invalidSemanticVersion),
            "the bundle reader must reject noncanonical version text"
        )
        try writeInfo(version: nil)
        expect(
            TrustedBundleVersionReader.read(policy: policy())
                == .failedClosed(.versionMissing),
            "missing bundle version evidence must retain its fixed reason"
        )

        try fileManager.removeItem(at: infoURL)
        let realInfoURL = fixtureRoot.appendingPathComponent("RealInfo.plist")
        let realData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": expectedIdentifier,
                "CFBundleShortVersionString": "5.3.3",
            ],
            format: .xml,
            options: 0
        )
        try realData.write(to: realInfoURL)
        try fileManager.createSymbolicLink(
            at: infoURL,
            withDestinationURL: realInfoURL
        )
        expect(
            TrustedBundleVersionReader.read(policy: policy())
                == .failedClosed(.infoPlistIsSymbolicLink),
            "the bundle reader must never follow an Info.plist symbolic link"
        )

        let bundleLink = fixtureRoot.appendingPathComponent(
            "linked-macfuse.fs",
            isDirectory: true
        )
        try fileManager.createSymbolicLink(
            at: bundleLink,
            withDestinationURL: bundleURL
        )
        expect(
            TrustedBundleVersionReader.read(
                policy: policy(rootPath: bundleLink.path)
            ) == .failedClosed(.pathComponentIsSymbolicLink),
            "the bundle reader must never follow a bundle path symbolic link"
        )
    } catch {
        fatalError("CHECK FAILED: trusted bundle fixture setup failed: \(error)")
    }
}

func trustedMacFUSEEvidenceRejectsMixedFilesystemEpochs() {
    let fileManager = FileManager.default
    let fixtureRoot = URL(
        fileURLWithPath: "/private/tmp",
        isDirectory: true
    ).appendingPathComponent(
        "ntfs-lite-macfuse-mixed-epoch-\(UUID().uuidString)",
        isDirectory: true
    )
    let bundleURL = fixtureRoot.appendingPathComponent("macfuse.fs", isDirectory: true)
    let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
    let infoURL = contentsURL.appendingPathComponent("Info.plist", isDirectory: false)
    let bundleIdentifier = "com.example.ntfslite.mixed-epoch"
    let versionA = SemanticVersion(major: 5, minor: 3, patch: 3)
    let versionB = SemanticVersion(major: 5, minor: 4, patch: 0)
    let versionAHash = Data(repeating: 0xA3, count: 20)
    let versionBHash = Data(repeating: 0xB4, count: 20)

    func infoData(version: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleShortVersionString": version,
            ],
            format: .xml,
            options: 0
        )
    }

    do {
        try fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: fixtureRoot)
        }
        try infoData(version: "5.3.3").write(to: infoURL)
        guard chmod(infoURL.path, 0o600) == 0 else {
            fatalError("CHECK FAILED: could not prepare mixed-epoch metadata")
        }
        let replacementInfoData = try infoData(version: "5.4.0")
        let requirement = "identifier \"\(bundleIdentifier)\" and anchor apple generic"
        let policy = TrustedMacFUSEPolicy(
            bundleVersionPolicy: TrustedBundleVersionPolicy(
                bundleRootPath: bundleURL.path,
                expectedBundleIdentifier: bundleIdentifier,
                expectedOwnerUID: getuid(),
                approvedVersions: [versionA, versionB]
            ),
            codeSignaturePoliciesByVersion: [
                versionA: TrustedCodeSignaturePolicy(
                    designatedRequirement: requirement,
                    expectedTeamIdentifier: "ABCDE12345",
                    expectedCodeDirectoryHash: versionAHash
                ),
                versionB: TrustedCodeSignaturePolicy(
                    designatedRequirement: requirement,
                    expectedTeamIdentifier: "ABCDE12345",
                    expectedCodeDirectoryHash: versionBHash
                ),
            ]
        )
        let swappingProvider = TrustedCodeSignatureEvidenceProvider { _, _ in
            do {
                try replacementInfoData.write(to: infoURL)
                guard chmod(infoURL.path, 0o600) == 0 else {
                    fatalError("CHECK FAILED: could not protect replacement metadata")
                }
            } catch {
                fatalError("CHECK FAILED: could not replace mixed-epoch metadata: \(error)")
            }
            return .observed(
                TrustedCodeSignatureEvidence(
                    teamIdentifier: "ABCDE12345",
                    codeDirectoryHash: versionBHash,
                    securedBundleIdentifier: bundleIdentifier,
                    securedBundleVersionText: "5.4.0"
                )
            )
        }

        let result = TrustedMacFUSEEvidenceReader.read(
            policy: policy,
            evidenceProvider: swappingProvider
        )
        if case .failedClosed = result {
            return
        }
        fatalError(
            "CHECK FAILED: filesystem version A and signature identity B must never form trust: \(result)"
        )
    } catch {
        fatalError("CHECK FAILED: mixed-epoch fixture setup failed: \(error)")
    }
}

func diagnosticsRetentionIsBoundedByAgeAndEncodedBytes() async {
    func inventoryInput() -> DiagnosticInput {
        .inventory(
            DiagnosticInventoryEvent(
                isComplete: false,
                physicalDiskCount: 1,
                volumeCount: 1,
                issueCodes: [.initialEnumerationPending]
            )
        )
    }

    do {
        _ = try DiagnosticRetentionPolicy(maxEntries: 1, maxEncodedBytes: 0)
        fatalError("CHECK FAILED: a zero diagnostic byte budget must be rejected")
    } catch let error as DiagnosticRetentionPolicyError {
        expect(
            error == .maxEncodedBytesMustBePositive,
            "a zero diagnostic byte budget should have a stable policy error"
        )
    } catch {
        fatalError("CHECK FAILED: unexpected zero-byte policy error: \(error)")
    }
    do {
        _ = try DiagnosticRetentionPolicy(
            maxEntries: 1,
            maxEncodedBytes: DiagnosticRetentionPolicy.minimumEncodedSnapshotBytes - 1
        )
        fatalError("CHECK FAILED: a byte budget below an empty snapshot must be rejected")
    } catch let error as DiagnosticRetentionPolicyError {
        expect(
            error
                == .maxEncodedBytesBelowMinimum(
                    minimum: DiagnosticRetentionPolicy.minimumEncodedSnapshotBytes
                ),
            "an undersized diagnostic budget should report its fixed minimum"
        )
    } catch {
        fatalError("CHECK FAILED: unexpected undersized policy error: \(error)")
    }
    for invalidAge in [0, -1, Double.infinity, Double.nan] {
        do {
            _ = try DiagnosticRetentionPolicy(maxEntries: 1, maxAge: invalidAge)
            fatalError("CHECK FAILED: a nonpositive or nonfinite diagnostic age must be rejected")
        } catch let error as DiagnosticRetentionPolicyError {
            expect(
                error == .maxAgeMustBePositive,
                "invalid diagnostic ages should share one stable policy error"
            )
        } catch {
            fatalError("CHECK FAILED: unexpected diagnostic age policy error: \(error)")
        }
    }

    do {
        let clock = LockedDateSource(secondsSince1970: 100)
        let agePolicy = try DiagnosticRetentionPolicy(
            maxEntries: 10,
            maxEncodedBytes: 32_768,
            maxAge: 10
        )
        let ageDiagnostics = Diagnostics(
            policy: agePolicy,
            clock: { clock.now() },
            runIDGenerator: {
                UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
            }
        )
        try await ageDiagnostics.record(inventoryInput())
        clock.set(secondsSince1970: 109.999)
        let youngSnapshot = await ageDiagnostics.snapshot()
        expect(
            youngSnapshot.entries.count == 1,
            "a diagnostic entry younger than the exact age limit should remain"
        )
        clock.set(secondsSince1970: 110)
        let expiredSnapshot = await ageDiagnostics.snapshot()
        expect(
            expiredSnapshot.entries.isEmpty,
            "a diagnostic entry at the exact age boundary should expire"
        )
        clock.set(secondsSince1970: 90)
        let rolledBackSnapshot = await ageDiagnostics.snapshot()
        expect(
            rolledBackSnapshot.entries.isEmpty,
            "clock rollback must not revive expired diagnostic entries"
        )

        let fixedRunID = UUID(
            uuidString: "44444444-4444-4444-4444-444444444444"
        )!
        let sizingDiagnostics = Diagnostics(
            policy: try DiagnosticRetentionPolicy(
                maxEntries: 10,
                maxEncodedBytes: 32_768,
                maxAge: 60
            ),
            clock: { Date(timeIntervalSince1970: 200) },
            runIDGenerator: { fixedRunID }
        )
        try await sizingDiagnostics.record(inventoryInput())
        let sizingSnapshot = await sizingDiagnostics.snapshot()
        let singleEntryByteCount = try sizingSnapshot.encodedJSON().count

        let byteDiagnostics = Diagnostics(
            policy: try DiagnosticRetentionPolicy(
                maxEntries: 10,
                maxEncodedBytes: singleEntryByteCount,
                maxAge: 60
            ),
            clock: { Date(timeIntervalSince1970: 200) },
            runIDGenerator: { fixedRunID }
        )
        try await byteDiagnostics.record(inventoryInput())
        try await byteDiagnostics.record(inventoryInput())
        let byteSnapshot = await byteDiagnostics.snapshot()
        let byteSnapshotEncodedCount = try byteSnapshot.encodedJSON().count
        expect(
            byteSnapshot.entries.map(\.sequence) == [2],
            "the encoded-byte budget should evict the oldest entry first"
        )
        expect(
            byteSnapshotEncodedCount <= singleEntryByteCount,
            "the retained diagnostic snapshot must never exceed its encoded-byte budget"
        )

        let emptyOnlyDiagnostics = Diagnostics(
            policy: try DiagnosticRetentionPolicy(
                maxEntries: 10,
                maxEncodedBytes: DiagnosticRetentionPolicy.minimumEncodedSnapshotBytes,
                maxAge: 60
            ),
            clock: { Date(timeIntervalSince1970: 200) },
            runIDGenerator: { fixedRunID }
        )
        try await emptyOnlyDiagnostics.record(inventoryInput())
        let emptyOnlySnapshot = await emptyOnlyDiagnostics.snapshot()
        let emptyOnlyEncodedCount = try emptyOnlySnapshot.encodedJSON().count
        expect(
            emptyOnlySnapshot.entries.isEmpty,
            "an individually oversized diagnostic entry must be dropped fail-closed"
        )
        expect(
            emptyOnlyEncodedCount
                <= DiagnosticRetentionPolicy.minimumEncodedSnapshotBytes,
            "even an empty retained snapshot must respect the configured byte limit"
        )
    } catch {
        fatalError("CHECK FAILED: diagnostics retention fixtures failed: \(error)")
    }
}

func coordinatorEffectsCompileIntoExactlyFourHelperMutations() {
    let disk = DiskInstanceID(
        physicalDiskID: PhysicalDiskID(rawValue: "disk12"),
        mediaGeneration: MediaGeneration(rawValue: 42)
    )
    let volume = VolumeInstanceID(
        volumeID: VolumeID(
            uuid: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            bsdName: "disk12s3"
        ),
        diskInstanceID: disk
    )
    let operationID = OperationID(rawValue: "coordinator-operation-1")
    let fixtures: [(VolumeEffect, HelperAction, HelperTarget)]
    do {
        let helperDisk = try HelperDiskInstanceIdentity(
            physicalDiskBSDName: "disk12",
            mediaGeneration: 42
        )
        let helperVolume = try HelperVolumeInstanceIdentity(
            volumeUUID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            volumeBSDName: "disk12s3",
            disk: helperDisk
        )
        fixtures = [
            (
                .unmountStandard(operationID: operationID, target: volume),
                .unmountVolume,
                .volume(helperVolume)
            ),
            (
                .mountReadWrite(
                    MountPlan(
                        operationID: operationID,
                        target: volume,
                        policy: .fsKitCurrentUserNoRecovery
                    )
                ),
                .mountReadWrite,
                .volume(helperVolume)
            ),
            (
                .unmountPhysicalDiskStandard(operationID: operationID, target: disk),
                .unmountDisk,
                .disk(helperDisk)
            ),
            (
                .ejectPhysicalDiskStandard(operationID: operationID, target: disk),
                .ejectDisk,
                .disk(helperDisk)
            ),
        ]
    } catch {
        fatalError("CHECK FAILED: helper bridge fixtures should construct: \(error)")
    }

    for (effect, expectedAction, expectedTarget) in fixtures {
        switch HelperRequestCompiler.compile(effect: effect) {
        case let .success(request):
            expect(
                request.operationID.rawValue == operationID.rawValue,
                "the helper bridge must preserve the coordinator one-shot operation ID"
            )
            expect(
                request.action == expectedAction && request.target == expectedTarget,
                "each mutation effect must map to exactly one fixed helper action and target"
            )
        case let .failure(error):
            fatalError("CHECK FAILED: valid coordinator effect failed helper compilation: \(error)")
        }
    }

    expect(
        HelperRequestCompiler.compile(effect: .none) == .failure(.notMutationEffect),
        "observation effects must never cross the helper mutation boundary"
    )
    expect(
        HelperRequestCompiler.compile(
            effect: .unmountStandard(
                operationID: OperationID(rawValue: "bad operation id"),
                target: volume
            )
        ) == .failure(.invalidOperationID),
        "invalid coordinator operation IDs must fail before helper transport"
    )
    let invalidVolume = VolumeInstanceID(
        volumeID: VolumeID(uuid: "not-a-uuid", bsdName: "disk12s3"),
        diskInstanceID: disk
    )
    expect(
        HelperRequestCompiler.compile(
            effect: .unmountStandard(
                operationID: operationID,
                target: invalidVolume
            )
        ) == .failure(.invalidIdentity),
        "noncanonical volume identity must fail before helper transport"
    )
}

func trustedExecutableVerifierPinsTheExactOpenedArtifact() async {
    let fileManager = FileManager.default
    let fixtureRoot = URL(
        fileURLWithPath: "/private/tmp",
        isDirectory: true
    ).appendingPathComponent(
        "ntfs-lite-trusted-executable-\(UUID().uuidString)",
        isDirectory: true
    )
    let binURL = fixtureRoot.appendingPathComponent("bin", isDirectory: true)
    let executableURL = binURL.appendingPathComponent("ntfs-3g", isDirectory: false)
    let fixtureData = Data("ntfs-lite-fixture\n".utf8)
    let fixtureDigest = "13979bdc7701f20c912d88b31e6a9a71e90ddf2550242d6731e90a44ddd54c3f"

    func policy(
        path: String? = nil,
        owner: uid_t = getuid(),
        maximumBytes: Int = 1_024,
        digests: Set<String>? = nil
    ) -> TrustedExecutablePolicy {
        TrustedExecutablePolicy(
            executablePath: path ?? executableURL.path,
            expectedBasename: "ntfs-3g",
            expectedOwnerUID: owner,
            maximumBytes: maximumBytes,
            allowedSHA256Digests: digests ?? [fixtureDigest]
        )
    }

    do {
        try fileManager.createDirectory(at: binURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: fixtureRoot)
        }
        try fixtureData.write(to: executableURL)
        guard chmod(executableURL.path, 0o700) == 0 else {
            fatalError("CHECK FAILED: could not prepare executable permission fixture")
        }

        let executableEvidence = TrustedExecutableEvidence(
            sha256Digest: fixtureDigest,
            byteCount: fixtureData.count
        )
        expect(
            TrustedExecutableVerifier.verify(policy: policy())
                == .trusted(executableEvidence),
            "the verifier should trust only the exact bytes read from the opened file"
        )
        let pinnedVersion = SemanticVersion(major: 2026, minor: 7, patch: 7)
        let artifactPolicy = TrustedNTFS3GArtifactPolicy(
            executablePolicy: policy(),
            versionsBySHA256Digest: [fixtureDigest: pinnedVersion]
        )
        expect(
            TrustedNTFS3GArtifactResolver.resolve(policy: artifactPolicy)
                == .trusted(
                    TrustedNTFS3GArtifactEvidence(
                        version: pinnedVersion,
                        executable: executableEvidence
                    )
                ),
            "a pinned digest should resolve its catalogued NTFS-3G version without execution"
        )
        expect(
            TrustedNTFS3GArtifactResolver.resolve(
                policy: TrustedNTFS3GArtifactPolicy(
                    executablePolicy: policy(),
                    versionsBySHA256Digest: [:]
                )
            ) == .failedClosed(.invalidVersionCatalog),
            "an incomplete digest-to-version catalog must fail closed"
        )
        let loader = SystemSetupFactsLoader(
            commandProvider: SetupReadOnlyCommandProvider { _ in
                SetupCommandOutput(
                    standardOutput: "",
                    terminationStatus: 1,
                    wasTruncated: false
                )
            },
            probePolicy: .unconfigured(),
            ntfs3GArtifactPolicy: artifactPolicy
        )
        let mappedFacts = await loader.currentFacts()
        expect(
            mappedFacts.ntfs3GVersion == pinnedVersion,
            "the setup loader should map only a hash-catalogued NTFS-3G version"
        )
        expect(
            TrustedExecutableVerifier.verify(
                policy: policy(digests: [String(repeating: "0", count: 64)])
            ) == .failedClosed(.digestNotAllowed),
            "a valid but unpinned executable digest must fail closed"
        )
        expect(
            TrustedExecutableVerifier.verify(
                policy: policy(digests: [fixtureDigest.uppercased()])
            ) == .failedClosed(.invalidPolicy),
            "the digest allowlist must use one canonical lowercase representation"
        )
        expect(
            TrustedExecutableVerifier.verify(policy: policy(maximumBytes: 4))
                == .failedClosed(.executableTooLarge),
            "an executable above the configured byte bound must be rejected"
        )
        let differentOwner = getuid() == uid_t.max ? getuid() - 1 : getuid() + 1
        expect(
            TrustedExecutableVerifier.verify(policy: policy(owner: differentOwner))
                == .failedClosed(.ownerMismatch),
            "the executable owner must match the fixed policy"
        )

        guard chmod(executableURL.path, 0o6700) == 0 else {
            fatalError("CHECK FAILED: could not prepare privileged executable fixture")
        }
        expect(
            TrustedExecutableVerifier.verify(policy: policy())
                == .failedClosed(.privilegeEscalationBitsPresent),
            "a pinned executable must never carry set-user-ID or set-group-ID bits"
        )

        guard chmod(executableURL.path, 0o600) == 0 else {
            fatalError("CHECK FAILED: could not prepare missing-execute fixture")
        }
        expect(
            TrustedExecutableVerifier.verify(policy: policy())
                == .failedClosed(.executablePermissionMissing),
            "a trusted tool must actually carry an execute permission"
        )
        guard chmod(executableURL.path, 0o770) == 0 else {
            fatalError("CHECK FAILED: could not prepare writable-executable fixture")
        }
        expect(
            TrustedExecutableVerifier.verify(policy: policy())
                == .failedClosed(.unsafeWritePermissions),
            "a group-writable executable must fail before hashing"
        )

        try fileManager.removeItem(at: executableURL)
        let realExecutable = fixtureRoot.appendingPathComponent("real-ntfs-3g")
        try fixtureData.write(to: realExecutable)
        try fileManager.createSymbolicLink(
            at: executableURL,
            withDestinationURL: realExecutable
        )
        expect(
            TrustedExecutableVerifier.verify(policy: policy())
                == .failedClosed(.executableIsSymbolicLink),
            "the verifier must never follow a final executable symbolic link"
        )

        try fileManager.removeItem(at: executableURL)
        guard mkfifo(executableURL.path, 0o600) == 0 else {
            fatalError("CHECK FAILED: could not prepare FIFO executable fixture")
        }
        expect(
            TrustedExecutableVerifier.verify(policy: policy())
                == .failedClosed(.executableIsNotRegularFile),
            "a FIFO must be opened nonblocking and rejected as a non-regular file"
        )
        expect(
            TrustedExecutableVerifier.verify(
                policy: policy(path: "/var/untrusted-parent/ntfs-3g")
            ) == .failedClosed(.pathComponentIsSymbolicLink),
            "a symbolic-link path component such as /var must be rejected"
        )
    } catch {
        fatalError("CHECK FAILED: trusted executable fixtures failed: \(error)")
    }
}

func diagnosticApplicationIdentityUsesOnlyStrictBundleMetadata() {
    expect(
        DiagnosticApplicationIdentityParser.parse(
            shortVersion: "0.1.0",
            buildVersion: "1"
        ) == .success(
            DiagnosticApplicationIdentity(
                version: DiagnosticVersion(major: 0, minor: 1, patch: 0),
                build: 1
            )
        ),
        "canonical bundle version metadata should map to typed diagnostics"
    )

    let invalidFixtures: [(String?, String?, DiagnosticApplicationIdentityFailure)] = [
        (nil, "1", .missingVersion),
        ("0.1.0", nil, .missingBuild),
        ("0.1", "1", .invalidVersion),
        ("0.1.0.1", "1", .invalidVersion),
        ("00.1.0", "1", .invalidVersion),
        ("0.-1.0", "1", .invalidVersion),
        ("０.1.0", "1", .invalidVersion),
        ("0.1.0", "01", .invalidBuild),
        ("0.1.0", "-1", .invalidBuild),
        ("0.1.0", "4294967296", .invalidBuild),
    ]
    for (version, build, failure) in invalidFixtures {
        expect(
            DiagnosticApplicationIdentityParser.parse(
                shortVersion: version,
                buildVersion: build
            ) == .failure(failure),
            "malformed bundle version metadata must fail with a fixed reason"
        )
    }
}

func systemSetupReportPreservesFixedDependencyFailureEvidence() async {
    let macFUSEBundlePolicy = TrustedBundleVersionPolicy(
        bundleRootPath: "/private/tmp/NotConfigured.prefPane",
        expectedBundleIdentifier: "",
        expectedOwnerUID: getuid(),
        approvedVersions: []
    )
    let macFUSEPolicy = TrustedMacFUSEPolicy(
        bundleVersionPolicy: macFUSEBundlePolicy,
        codeSignaturePoliciesByVersion: [:]
    )
    let executablePolicy = TrustedExecutablePolicy(
        executablePath: "/private/tmp/ntfs-3g",
        expectedBasename: "ntfs-3g",
        expectedOwnerUID: getuid(),
        maximumBytes: 1_024,
        allowedSHA256Digests: [String(repeating: "0", count: 64)]
    )
    let loader = SystemSetupFactsLoader(
        authorizationStatus: .unknown,
        authorizationProvider: SetupAuthorizationStatusProvider { .denied },
        commandProvider: SetupReadOnlyCommandProvider { _ in
            SetupCommandOutput(
                standardOutput: "",
                terminationStatus: 1,
                wasTruncated: false
            )
        },
        probePolicy: .unconfigured(),
        macFUSEPolicy: macFUSEPolicy,
        macFUSECodeSignatureEvidenceProvider: TrustedCodeSignatureEvidenceProvider {
            _, _ in
            .observed(
                TrustedCodeSignatureEvidence(
                    teamIdentifier: "ABCDE12345",
                    codeDirectoryHash: Data(repeating: 0xAB, count: 20),
                    securedBundleIdentifier: "com.example.invalid",
                    securedBundleVersionText: "5.3.3"
                )
            )
        },
        ntfs3GArtifactPolicy: TrustedNTFS3GArtifactPolicy(
            executablePolicy: executablePolicy,
            versionsBySHA256Digest: [:]
        )
    )
    let report = await loader.currentReport()
    expect(
        report.macFUSEEvidence == .failedClosed(.bundle(.invalidPolicy)),
        "an untrusted macFUSE policy should preserve its fixed failure reason"
    )
    expect(
        report.ntfs3GEvidence == .failedClosed(.invalidVersionCatalog),
        "an incomplete NTFS-3G catalog should preserve its fixed failure reason"
    )
    expect(
        report.authorizationStatus == .denied
            && report.facts.authorizationStatus == .denied,
        "the typed authorization provider should be the report and facts source of truth"
    )
    expect(
        report.facts.macFUSEVersion == nil && report.facts.ntfs3GVersion == nil,
        "failed dependency evidence must still map to unavailable setup facts"
    )

    let unconfigured = await SystemSetupFactsLoader(
        commandProvider: SetupReadOnlyCommandProvider { _ in
            SetupCommandOutput(
                standardOutput: "",
                terminationStatus: 1,
                wasTruncated: false
            )
        },
        probePolicy: .unconfigured()
    ).currentReport()
    expect(
        unconfigured.macFUSEEvidence == .notConfigured
            && unconfigured.ntfs3GEvidence == .notConfigured,
        "missing production trust policies must remain distinct from rejected evidence"
    )
}

func diagnosticSnapshotArchivePersistsOnlyCanonicalPrivateEvidence() async {
    let fileManager = FileManager.default
    let fixtureRoot = URL(
        fileURLWithPath: "/private/tmp",
        isDirectory: true
    ).appendingPathComponent(
        "ntfs-lite-diagnostic-archive-\(UUID().uuidString)",
        isDirectory: true
    )
    defer {
        try? fileManager.removeItem(at: fixtureRoot)
    }

    do {
        let clock = LockedDateSource(secondsSince1970: 100)
        let policy = try DiagnosticSnapshotArchivePolicy(
            directoryURL: fixtureRoot,
            maxBytes: 8_192,
            maxAge: 10
        )
        let archive = DiagnosticSnapshotArchive(
            policy: policy,
            clock: { clock.now() }
        )
        let diagnostics = Diagnostics(
            policy: try DiagnosticRetentionPolicy(
                maxEntries: 10,
                maxEncodedBytes: 8_192,
                maxAge: 60
            ),
            clock: { clock.now() },
            runIDGenerator: {
                UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
            }
        )
        try await diagnostics.record(
            .inventory(
                DiagnosticInventoryEvent(
                    isComplete: false,
                    physicalDiskCount: 1,
                    volumeCount: 2,
                    issueCodes: [.initialEnumerationPending]
                )
            )
        )
        let diagnosticDisk = try await diagnostics.registerDisk(mediaGeneration: 7)
        let diagnosticVolume = try await diagnostics.registerVolume(on: diagnosticDisk)
        try await diagnostics.record(
            .volume(
                DiagnosticVolumeEvent(
                    target: diagnosticVolume,
                    fileSystem: .ntfs,
                    location: .external,
                    role: .data,
                    health: .unknown,
                    mountAccess: .readOnly,
                    backend: .unknown,
                    state: .readOnlyReady,
                    reason: nil,
                    observationComplete: true,
                    isCanonicalMountPoint: true,
                    isSymbolicLinkMountPoint: false
                )
            )
        )
        let snapshot = await diagnostics.snapshot()

        func saveCurrent(
            _ targetArchive: DiagnosticSnapshotArchive
        ) async -> DiagnosticSnapshotArchiveSaveResult {
            let generation = await targetArchive.currentGeneration()
            return await targetArchive.save(snapshot, generation: generation)
        }

        await expectAsync(
            await saveCurrent(archive) == .saved,
            "a canonical snapshot should save"
        )
        await expectAsync(
            await archive.load() == .loaded(snapshot),
            "the exact canonical snapshot should round-trip from the private archive"
        )
        let staleGeneration = await archive.currentGeneration()
        await expectAsync(
            await archive.clear() == .cleared,
            "the archive should rotate its persistence generation while clearing"
        )
        await expectAsync(
            await archive.save(snapshot, generation: staleGeneration) == .superseded,
            "a save started from the pre-clear generation must never resurrect old diagnostics"
        )
        await expectAsync(
            await archive.load() == .unavailable,
            "a rejected stale save must leave the cleared archive absent"
        )
        let currentGeneration = await archive.currentGeneration()
        await expectAsync(
            await archive.save(snapshot, generation: currentGeneration) == .saved,
            "the post-clear generation should accept a new diagnostic snapshot"
        )
        let secondArchive = DiagnosticSnapshotArchive(
            policy: policy,
            clock: { clock.now() }
        )
        async let firstConcurrentSave = saveCurrent(archive)
        async let secondConcurrentSave = saveCurrent(secondArchive)
        let concurrentSaveResults = await (
            firstConcurrentSave,
            secondConcurrentSave
        )
        expect(
            concurrentSaveResults.0 == .saved && concurrentSaveResults.1 == .saved,
            "independent archive actors must use unique atomic staging files"
        )
        let stagingFiles = try fileManager.contentsOfDirectory(
            at: fixtureRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".tmp") }
        expect(
            stagingFiles.isEmpty,
            "successful atomic saves must not leave staging files behind"
        )

        let fileURL = fixtureRoot.appendingPathComponent("diagnostics-v1.json")
        var status = stat()
        guard lstat(fileURL.path, &status) == 0 else {
            fatalError("CHECK FAILED: the diagnostic archive file should exist")
        }
        expect(
            status.st_mode & mode_t(0o777) == mode_t(0o600),
            "the diagnostic archive must be created with mode 0600"
        )

        guard chmod(fileURL.path, 0o644) == 0 else {
            fatalError("CHECK FAILED: could not prepare an unsafe archive permission fixture")
        }
        await expectAsync(
            await archive.load() == .failedClosed(.unsafeFile),
            "a group-readable diagnostic archive must fail closed"
        )
        guard chmod(fileURL.path, 0o600) == 0 else {
            fatalError("CHECK FAILED: could not restore archive permissions")
        }
        await expectAsync(
            await archive.clear() == .cleared,
            "clearing a trusted archive should remove the persisted snapshot"
        )
        await expectAsync(
            await archive.load() == .unavailable,
            "a cleared archive must not restore the previous run"
        )
        await expectAsync(
            await archive.clear() == .cleared,
            "clearing an already absent archive should be idempotent"
        )
        await expectAsync(
            await saveCurrent(archive) == .saved,
            "a new snapshot should save after a successful clear"
        )

        let canonical = try snapshot.copyText()
        let zeroGeneration = canonical.replacingOccurrences(
            of: "\"mediaGeneration\":7",
            with: "\"mediaGeneration\":0"
        )
        expect(zeroGeneration != canonical, "the target fixture should contain one generation")
        try Data(zeroGeneration.utf8).write(to: fileURL)
        await expectAsync(
            await archive.load() == .failedClosed(.invalidSnapshot),
            "a canonical target with media generation zero must fail semantic validation"
        )
        let mismatchedTargetKind = canonical.replacingOccurrences(
            of: "\"diskOrdinal\":1,\"kind\":\"volume\"",
            with: "\"diskOrdinal\":1,\"kind\":\"disk\""
        )
        expect(
            mismatchedTargetKind != canonical,
            "the target fixture should contain one volume kind"
        )
        try Data(mismatchedTargetKind.utf8).write(to: fileURL)
        await expectAsync(
            await archive.load() == .failedClosed(.invalidSnapshot),
            "a disk target carrying a volume ordinal must fail semantic validation"
        )
        await expectAsync(
            await saveCurrent(archive) == .saved,
            "a valid save should restore the archive after semantic rejection"
        )
        let duplicateSchema = "{\"schemaVersion\":1," + canonical.dropFirst()
        try Data(duplicateSchema.utf8).write(to: fileURL)
        await expectAsync(
            await archive.load() == .failedClosed(.malformed),
            "duplicate JSON members must not enter the diagnostic archive"
        )
        await expectAsync(
            await saveCurrent(archive) == .saved,
            "a valid save should restore the archive"
        )

        let unknownSchema = canonical.replacingOccurrences(
            of: "\"schemaVersion\":1",
            with: "\"schemaVersion\":2"
        )
        expect(unknownSchema != canonical, "the schema fixture should replace one field")
        try Data(unknownSchema.utf8).write(to: fileURL)
        await expectAsync(
            await archive.load() == .failedClosed(.unsupportedSchema),
            "an unknown diagnostic schema must fail closed"
        )
        await expectAsync(
            await saveCurrent(archive) == .saved,
            "a valid save should restore the archive"
        )

        try Data(repeating: 0x41, count: policy.maxBytes + 1).write(to: fileURL)
        await expectAsync(
            await archive.load() == .failedClosed(.oversized),
            "an oversized local archive must be rejected before decoding"
        )
        await expectAsync(
            await saveCurrent(archive) == .saved,
            "a valid save should replace oversized data"
        )

        clock.set(secondsSince1970: 99)
        await expectAsync(
            await archive.load() == .failedClosed(.futureTimestamp),
            "future-dated diagnostic evidence must fail closed"
        )
        await expectAsync(
            await saveCurrent(archive) == .failedClosed(.futureTimestamp),
            "the archive writer must reject future-dated evidence before mutation"
        )
        clock.set(secondsSince1970: 110)
        await expectAsync(
            await archive.load() == .failedClosed(.expired),
            "diagnostic evidence at the exact age boundary must expire"
        )
        await expectAsync(
            await saveCurrent(archive) == .failedClosed(.expired),
            "the archive writer must reject expired evidence before mutation"
        )
        clock.set(secondsSince1970: 100)

        let decoyURL = fixtureRoot.appendingPathComponent("decoy")
        try Data(canonical.utf8).write(to: decoyURL)
        try fileManager.removeItem(at: fileURL)
        try fileManager.createSymbolicLink(at: fileURL, withDestinationURL: decoyURL)
        await expectAsync(
            await archive.load() == .failedClosed(.unsafeFile),
            "the archive reader must never follow a final symbolic link"
        )
        await expectAsync(
            await saveCurrent(archive) == .failedClosed(.unsafeFile),
            "the archive writer must never replace an untrusted symbolic-link target"
        )
        await expectAsync(
            await archive.clear() == .failedClosed(.unsafeFile),
            "clear must not claim success while an untrusted archive entry remains"
        )
        expect(
            fileManager.fileExists(atPath: fileURL.path),
            "a failed-closed clear must leave the untrusted entry untouched"
        )

        let undersizedPolicy = try DiagnosticSnapshotArchivePolicy(
            directoryURL: fixtureRoot.appendingPathComponent("small", isDirectory: true),
            maxBytes: 1,
            maxAge: 10
        )
        let undersizedArchive = DiagnosticSnapshotArchive(
            policy: undersizedPolicy,
            clock: { clock.now() }
        )
        await expectAsync(
            await saveCurrent(undersizedArchive) == .failedClosed(.oversized),
            "the archive writer must enforce its byte bound before filesystem mutation"
        )
    } catch {
        fatalError("CHECK FAILED: diagnostic archive fixtures failed: \(error)")
    }
}

func readOnlyObservationSessionRejectsEveryStaleRefreshResult() {
    var session = ReadOnlyObservationSession()
    expect(
        session.observation.issues.contains(.initialEnumerationPending),
        "a new read-only session must begin with explicit pending evidence"
    )
    let firstToken = session.beginRefresh()
    let firstObservation = DiskInventoryObservation(physicalDisks: [], issues: [])
    expect(
        session.accept(firstObservation, for: firstToken),
        "the current subscription should publish its observation"
    )

    let secondToken = session.beginRefresh()
    let staleObservation = DiskInventoryObservation(
        physicalDisks: [],
        issues: [.mountTableReadFailed]
    )
    expect(
        !session.accept(staleObservation, for: firstToken),
        "a late observation from the old subscription must be ignored"
    )
    expect(
        !session.sourceBecameUnavailable(for: firstToken),
        "an old subscription ending must not replace current pending facts"
    )
    expect(
        session.observation.issues.contains(.initialEnumerationPending),
        "starting a new refresh must clear the previous settled result"
    )
    expect(
        session.accept(firstObservation, for: secondToken),
        "the new subscription should still publish normally"
    )
    expect(
        session.sourceBecameUnavailable(for: secondToken),
        "the current event source ending must produce an explicit unavailable state"
    )
    expect(
        session.observation.issues == [.eventSourceUnavailable],
        "an ended event source must never leave stale confirmed disk facts visible"
    )
}

func finishedObserverOutput(
    _ stream: AsyncStream<DiskInventoryObservation>
) async -> [DiskInventoryObservation]? {
    await withTaskGroup(of: [DiskInventoryObservation]?.self) { group in
        group.addTask {
            var observations: [DiskInventoryObservation] = []
            for await observation in stream {
                observations.append(observation)
            }
            return observations
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(2))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

func readOnlyObserverFinishesAfterSettlementAndKeepsTheFirstZeroDelayEvent() async {
    let idleEvents = AsyncStream<DiskArbitrationEvent>.makeStream()
    let idleObserver = ReadOnlyDiskObserver(
        eventProvider: DiskEventStreamProvider { idleEvents.stream },
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [])
        },
        settleInterval: .milliseconds(10)
    )
    let idleOutput: AsyncStream<DiskInventoryObservation>
    do {
        idleOutput = try idleObserver.observations()
    } catch {
        fatalError("CHECK FAILED: the injected idle observer should start: \(error)")
    }
    let idleCollection = Task { await finishedObserverOutput(idleOutput) }
    try? await Task.sleep(for: .milliseconds(40))
    idleEvents.continuation.finish()
    guard let idleObservations = await idleCollection.value else {
        fatalError("CHECK FAILED: a source ending after settlement must finish output")
    }
    expect(
        idleObservations.contains(where: {
            !$0.isComplete && $0.issues.contains(.enumerationCoverageUnverified)
        }),
        "the idle observer should settle without treating silence as full coverage"
    )

    let wholeDisk = diskDescription(
        bsdName: "disk29",
        physicalDiskBSDName: "disk29",
        isWholeDisk: true
    )
    let immediateEvents = AsyncStream<DiskArbitrationEvent>.makeStream()
    immediateEvents.continuation.yield(
        DiskArbitrationEvent(kind: .appeared, description: wholeDisk)
    )
    immediateEvents.continuation.finish()
    let immediateObserver = ReadOnlyDiskObserver(
        eventProvider: DiskEventStreamProvider { immediateEvents.stream },
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [])
        },
        settleInterval: .zero
    )
    let immediateOutput: AsyncStream<DiskInventoryObservation>
    do {
        immediateOutput = try immediateObserver.observations()
    } catch {
        fatalError("CHECK FAILED: the zero-delay observer should start: \(error)")
    }
    guard let immediateObservations = await finishedObserverOutput(immediateOutput) else {
        fatalError("CHECK FAILED: the zero-delay observer should finish")
    }
    expect(
        immediateObservations.contains(where: { observation in
            observation.issues.contains(.enumerationCoverageUnverified)
                && observation.physicalDisks.first?.instanceID.physicalDiskID.rawValue
                    == "disk29"
        }),
        "a zero-delay initial settlement must not lose the first disk event"
    )
}

func finishedObservationCaptureOutput(
    _ stream: AsyncStream<ReadOnlyDiskObservationCaptureEvent>
) async -> [ReadOnlyDiskObservationCaptureEvent]? {
    await withTaskGroup(of: [ReadOnlyDiskObservationCaptureEvent]?.self) { group in
        group.addTask {
            var events: [ReadOnlyDiskObservationCaptureEvent] = []
            for await event in stream {
                events.append(event)
            }
            return events
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(2))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

func readOnlyObservationCaptureDrainsAcceptedEventsBeforeItsSealBarrier() async {
    let wholeDisk = diskDescription(
        bsdName: "disk62",
        physicalDiskBSDName: "disk62",
        isWholeDisk: true
    )
    let source = AsyncStream<DiskEventStreamItem>.makeStream()
    let sourceSession = DiskEventStreamSession(
        items: source.stream,
        stopAndDrain: {
            source.continuation.yield(.drainBoundary)
            source.continuation.finish()
            return true
        },
        stopImmediately: {
            source.continuation.finish()
        }
    )
    let observer = ReadOnlyDiskObserver(
        eventProvider: DiskEventStreamProvider(session: { sourceSession }),
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [])
        },
        mediaEnumerationProvider: IOMediaEnumerationSnapshotProvider {
            IOMediaEnumerationSnapshot(bsdNames: ["disk62"])
        },
        settleInterval: .zero,
        enumerationTimeout: .milliseconds(100)
    )

    do {
        let capture = try observer.capture()
        let collection = Task {
            await finishedObservationCaptureOutput(capture.events)
        }
        source.continuation.yield(
            .event(
                DiskArbitrationEvent(kind: .appeared, description: wholeDisk)
            )
        )
        let accepted = await capture.stopAndDrain()
        guard let output = await collection.value else {
            fatalError("CHECK FAILED: a drained observation capture should finish")
        }
        expect(accepted, "the injected source should accept one drain barrier")
        expect(
            output.contains(where: { event in
                guard case let .observation(observation) = event else {
                    return false
                }
                return observation.physicalDisks.first?
                    .instanceID.physicalDiskID.rawValue == "disk62"
            }),
            "an event accepted before the drain barrier must reach the capture output"
        )
        expect(
            output.last == .terminal(.drained(finalObservationVerified: true)),
            "a successful drain must finish only after a final verified observation"
        )
    } catch {
        fatalError("CHECK FAILED: drainable observation capture should start: \(error)")
    }
}

func readOnlyObservationCaptureDistinguishesNaturalSourceEndFromDrain() async {
    let source = AsyncStream<DiskEventStreamItem>.makeStream()
    source.continuation.finish()
    let sourceSession = DiskEventStreamSession(
        items: source.stream,
        stopAndDrain: { false },
        stopImmediately: {}
    )
    let observer = ReadOnlyDiskObserver(
        eventProvider: DiskEventStreamProvider(session: { sourceSession }),
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [])
        },
        mediaEnumerationProvider: IOMediaEnumerationSnapshotProvider {
            IOMediaEnumerationSnapshot(bsdNames: [])
        },
        settleInterval: .zero,
        enumerationTimeout: .milliseconds(100)
    )

    do {
        let capture = try observer.capture()
        let collection = Task {
            await finishedObservationCaptureOutput(capture.events)
        }
        let accepted = await capture.stopAndDrain()
        guard let output = await collection.value else {
            fatalError("CHECK FAILED: a naturally ended capture should finish")
        }
        expect(!accepted, "a source that already ended must reject a late drain request")
        expect(
            output.last == .terminal(.sourceEndedUnexpectedly),
            "natural source end racing with seal must remain distinguishable and fail closed"
        )
    } catch {
        fatalError("CHECK FAILED: naturally ending observation capture should start: \(error)")
    }
}

func readOnlyObservationCaptureReportsAnUnverifiedFinalDrainSnapshot() async {
    let source = AsyncStream<DiskEventStreamItem>.makeStream()
    let sourceSession = DiskEventStreamSession(
        items: source.stream,
        stopAndDrain: {
            source.continuation.yield(.drainBoundary)
            source.continuation.finish()
            return true
        },
        stopImmediately: {
            source.continuation.finish()
        }
    )
    let observer = ReadOnlyDiskObserver(
        eventProvider: DiskEventStreamProvider(session: { sourceSession }),
        mountTableProvider: MountTableSnapshotProvider {
            SystemMountTableSnapshot(records: [])
        },
        mediaEnumerationProvider: IOMediaEnumerationSnapshotProvider {
            throw IOMediaEnumerationReadError.unexpectedFailure
        },
        settleInterval: .zero,
        enumerationTimeout: .milliseconds(100)
    )

    do {
        let capture = try observer.capture()
        let collection = Task {
            await finishedObservationCaptureOutput(capture.events)
        }
        let accepted = await capture.stopAndDrain()
        expect(accepted, "the source should accept its drain boundary")
        guard let output = await collection.value else {
            fatalError("CHECK FAILED: an unverified final drain should finish")
        }
        expect(
            output.last == .terminal(.drained(finalObservationVerified: false)),
            "failed final enumeration must be explicit instead of inheriting stale verified facts"
        )
    } catch {
        fatalError("CHECK FAILED: unverified drain capture should start: \(error)")
    }
}

func helperAdmissionIsTheOnlyAtomicBoundedRequestEntryPoint() async {
    let admission = HelperRequestAdmission.processLifetime

    func diskRequest(_ operationID: String) throws -> Data {
        let disk = try HelperDiskInstanceIdentity(
            physicalDiskBSDName: "disk31",
            mediaGeneration: 9
        )
        let request = try HelperRequestEnvelope(
            operationID: HelperOperationID(validating: operationID),
            action: .ejectDisk,
            target: .disk(disk)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(request)
    }

    do {
        let duplicateFixtures = [
            """
            {"schemaVersion":1,"operationID":"duplicate-top","action":"ejectDisk","\\u0061ction":"ejectDisk","target":{"kind":"disk","disk":{"physicalDiskBSDName":"disk31","mediaGeneration":9}}}
            """,
            """
            {"schemaVersion":1,"operationID":"duplicate-target","action":"ejectDisk","target":{"kind":"disk","kind":"disk","disk":{"physicalDiskBSDName":"disk31","mediaGeneration":9}}}
            """,
            """
            {"schemaVersion":1,"operationID":"duplicate-disk","action":"ejectDisk","target":{"kind":"disk","disk":{"physicalDiskBSDName":"disk31","mediaGeneration":9,"mediaGeneration":9}}}
            """,
            """
            {"schemaVersion":1,"operationID":"duplicate-volume","action":"unmountVolume","target":{"kind":"volume","volume":{"volumeUUID":"11111111-1111-1111-1111-111111111111","volumeUUID":"11111111-1111-1111-1111-111111111111","volumeBSDName":"disk31s1","disk":{"physicalDiskBSDName":"disk31","mediaGeneration":9}}}}
            """,
        ]
        for fixture in duplicateFixtures {
            await expectAsync(
                await admission.admit(Data(fixture.utf8)) == .failure(.malformedEnvelope),
                "duplicate JSON members at every request level must fail before consumption"
            )
        }

        for malformed in [Data(), Data("[]".utf8), Data([0xEF, 0xBB, 0xBF, 0x7B, 0x7D])] {
            await expectAsync(
                await admission.admit(malformed) == .failure(.malformedEnvelope),
                "noncanonical helper roots must fail at the raw JSON boundary"
            )
        }

        let unconsumedID = "invalid-does-not-consume"
        let malformedWithValidID = """
        {"schemaVersion":1,"operationID":"\(unconsumedID)","action":"ejectDisk","action":"ejectDisk","target":{"kind":"disk","disk":{"physicalDiskBSDName":"disk31","mediaGeneration":9}}}
        """
        await expectAsync(
            await admission.admit(Data(malformedWithValidID.utf8))
                == .failure(.malformedEnvelope),
            "a malformed request should be rejected"
        )
        let validAfterMalformed = try diskRequest(unconsumedID)
        await expectAsync(
            await admission.admit(validAfterMalformed).isSuccess,
            "a malformed request must not consume its operation ID"
        )
        await expectAsync(
            await admission.admit(validAfterMalformed) == .failure(.replayedOperation),
            "an admitted operation ID must be consumed exactly once"
        )

        let boundedBase = try diskRequest("exact-byte-boundary")
        expect(
            boundedBase.count < HelperProtocolLimits.maximumRequestBytes,
            "the request fixture must leave room for bounded JSON whitespace"
        )
        let exactBound = boundedBase + Data(
            repeating: 0x20,
            count: HelperProtocolLimits.maximumRequestBytes - boundedBase.count
        )
        await expectAsync(
            await admission.admit(exactBound).isSuccess,
            "a canonical request at the exact 4096-byte limit should be admitted"
        )
        await expectAsync(
            await admission.admit(exactBound + Data([0x20]))
                == .failure(.malformedEnvelope),
            "a request above 4096 bytes must fail before replay lookup"
        )

        let concurrentData = try diskRequest("concurrent-single-consume")
        let successfulAdmissions = await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 100 {
                group.addTask {
                    await admission.admit(concurrentData).isSuccess
                }
            }
            var count = 0
            for await succeeded in group where succeeded {
                count += 1
            }
            return count
        }
        expect(
            successfulAdmissions == 1,
            "100 concurrent copies of one request must produce exactly one admission"
        )

        var reachedCapacity = false
        capacityFill: for index in 0 ... HelperProtocolLimits.maximumConsumedOperationIDs {
            let request = try diskRequest("capacity-\(index)")
            switch await admission.admit(request) {
            case .success:
                continue
            case .failure(.operationCapacityReached):
                reachedCapacity = true
                break capacityFill
            case let .failure(rejection):
                fatalError(
                    "CHECK FAILED: capacity fixture had unexpected rejection: \(rejection)"
                )
            }
        }
        expect(reachedCapacity, "the process-lifetime admission set must have a hard capacity")
        let capacityOverflow = try diskRequest("capacity-overflow")
        await expectAsync(
            await admission.admit(capacityOverflow)
                == .failure(.operationCapacityReached),
            "capacity exhaustion must reject a new operation without evicting old IDs"
        )
        await expectAsync(
            await admission.admit(validAfterMalformed) == .failure(.replayedOperation),
            "a known replay must remain a replay even after capacity is exhausted"
        )

        let duplicateResponse = Data(
            "{\"schemaVersion\":1,\"resultCode\":0,\"resultCode\":0,\"exitStatus\":0}"
                .utf8
        )
        expect(
            HelperResponseDecoder().decode(duplicateResponse)
                == .failure(.malformedEnvelope),
            "helper responses must reject duplicate fields before typed decoding"
        )
    } catch {
        fatalError("CHECK FAILED: helper admission fixtures failed: \(error)")
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self {
            return true
        }
        return false
    }
}

healthyExternalNTFSVolumeCanBeginEnablingWrite()
print("PASS: healthy external NTFS volume can begin enabling write access")
hibernatedVolumeCannotBeginEnablingWrite()
print("PASS: hibernated volume cannot begin enabling write access")
unsafeAndOutOfScopeVolumesExposeSpecificWriteBlocks()
print("PASS: unsafe and out-of-scope volumes expose specific write blocks")
duplicateWriteRequestDoesNotStartAnotherOperation()
print("PASS: duplicate write request does not start another operation")
successfulUnmountRequestsAFreshSafetySnapshot()
print("PASS: successful unmount requests a fresh safety snapshot")
freshCleanUnmountedSnapshotProducesSafeMountPlan()
print("PASS: fresh clean unmounted snapshot produces the fixed safe mount plan")
healthChangeAfterUnmountPreventsWritableMount()
print("PASS: health change after unmount prevents writable mount")
changedMediaGenerationInvalidatesPendingWriteOperation()
print("PASS: changed media generation invalidates pending write operation")
staleOperationCompletionIsIgnored()
print("PASS: stale operation completion is ignored")
mountCommandSuccessRequestsVerificationInsteadOfClaimingWritable()
print("PASS: mount command success requests verification instead of claiming writable")
verifiedMountFactsExposeWritableState()
print("PASS: verified mount facts expose writable state")
incompleteOrMismatchedMountEvidenceNeverClaimsWritable()
print("PASS: incomplete or mismatched mount evidence never claims writable")
writableVolumeEjectBeginsByUnmountingWholePhysicalDisk()
print("PASS: writable volume eject begins by unmounting the whole physical disk")
unmountCallbackOnlyRequestsFreshPhysicalDiskInspection()
print("PASS: unmount callback only requests fresh physical-disk inspection")
allSiblingVolumesUnmountedAllowsStandardEject()
print("PASS: all sibling volumes unmounted allows standard eject")
mountedSiblingPreventsEject()
print("PASS: mounted sibling prevents eject")
busyUnmountNeverProducesAForceOperation()
print("PASS: busy unmount never produces a force operation")
ejectCallbackDoesNotClaimSafeToRemove()
print("PASS: eject callback does not claim safe to remove")
onlyFreshMatchingAbsenceMarksSafeToRemove()
print("PASS: only fresh matching absence marks safe to remove")
failedEjectCommandNeverClaimsSafeToRemove()
print("PASS: failed eject command never claims safe to remove")
writeBlocksNeverPreventSafeEject()
print("PASS: write blocks never prevent safe eject")
internalAndBootCampVolumesNeverEmitWholeDiskEjectMutations()
print("PASS: internal and Boot Camp volumes never emit whole-disk eject mutations")
await ejectabilityEvidenceGatesCoordinatorAndFinalPreflight()
print("PASS: physical-disk ejectability gates coordinator and final preflight")
await coordinatorAndPreflightRejectAProtectedSibling()
print("PASS: coordinator and preflight reject a protected sibling")
await ejectPreflightRejectsAChildThatRemountedAfterInspection()
print("PASS: eject preflight rejects a child that remounted after inspection")
await verifiedWholeDiskAbsenceRevokesEverySiblingWorkflow()
print("PASS: verified whole-disk absence revokes every sibling workflow")
await removalBeforeEjectCallbackStillReachesVerifiedSafeRemoval()
print("PASS: removal before eject callback still reaches verified safe removal")
await failedFinalEjectKeepsEverySiblingAtItsFreshObservedMountState()
print("PASS: failed final eject preserves fresh sibling mount facts")
await malformedWholeDiskInventoriesFailClosed()
print("PASS: malformed whole-disk inventories fail closed")
await definitiveWholeDiskUnmountFailureRequiresCompleteReconciliation()
print("PASS: definitive whole-disk unmount failure requires reconciliation")
await normalEjectInspectionsKeepTheLeaseUntilFactsAreComplete()
print("PASS: normal eject inspections retain the lease until facts are complete")
await uncertainFinalEjectPresentReconcilesEverySibling()
print("PASS: present uncertainty reconciliation refreshes every sibling")
await earlyRemovalThenDefinitiveFinalEjectFailureRequiresAbsence()
print("PASS: early removal outranks a later definitive eject failure")
await removalDuringUncertainWholeDiskUnmountStillRequiresCompleteReconciliation()
print("PASS: removal cannot bypass uncertain whole-disk reconciliation")
await ejectTimeoutOrCancellationRequiresQuiescenceAndWholeDiskReconciliation()
print("PASS: eject timeout or cancellation requires quiescence and whole-disk reconciliation")
await volumeCoordinatorSerializesSiblingMutationsAndIgnoresStaleCompletion()
print("PASS: volume coordinator serializes sibling mutations and ignores stale completion")
await inventoryRebuildTargetsOnlyTheCurrentMediaInstance()
print("PASS: inventory rebuild targets only the current media instance")
await mountEngineExecutesOnlyTheClaimedCurrentEffect()
print("PASS: MountEngine executes only the claimed current semantic effect")
await mountEngineRejectsOldInstancesAndReplaysWithoutInvocation()
print("PASS: MountEngine rejects old instances and replays without invocation")
await mountEngineResultsDistinguishTerminationAndFreshEvidenceScope()
print("PASS: MountEngine distinguishes termination and fresh-evidence scope")
await mountEngineConfirmedQuiescenceUnlocksOnlyFreshReconciliation()
print("PASS: MountEngine confirmed quiescence unlocks only fresh reconciliation")
await mountEngineUnconfirmedTerminationRetainsLeaseAndCallbackGate()
print("PASS: MountEngine unconfirmed termination retains its lease and callback gate")
await closureMutationTerminationCannotBeDiscardedAsConfirmedQuiescence()
print("PASS: closure mutation termination cannot be discarded as confirmed quiescence")
await mutationExecutionRejectsReinsertedStaleAndDuplicateEffects()
print("PASS: mutation execution rejects reinserted, stale, and duplicate effects")
setupAssessmentFailsClosedWithActionableIssues()
print("PASS: setup assessment fails closed with actionable issues")
await setupReadinessGatesWriteRequestsAndEveryWriteMutation()
print("PASS: setup readiness gates write requests and every write mutation")
await staleWriteRequestCannotRebindToAReplacementMediaInstance()
print("PASS: stale write request cannot rebind to a replacement media instance")
await finalVolumeEvidenceIsReadAfterPotentiallySlowSetupFacts()
print("PASS: final volume evidence is read after potentially slow setup facts")
await mountPreflightRevalidatesCompleteFreshVolumeFacts()
print("PASS: mount preflight revalidates complete fresh volume facts")
await writePreflightFailsClosedAndPreservesFreshSafetyReasons()
print("PASS: write preflight fails closed and preserves fresh safety reasons")
workflowInitializationReflectsActualMountAccess()
print("PASS: workflow initialization reflects actual mount access")
verifiedWritableIsRevokedByDetachOrReplacement()
print("PASS: verified writable is revoked by detach or replacement")
await physicalDiskLifecycleEventsAtomicallyInvalidateEverySibling()
print("PASS: physical-disk lifecycle events atomically invalidate every sibling")
await systemEvidenceMediaChangeInvalidatesEverySibling()
print("PASS: system evidence media change invalidates every sibling")
await diskRemovalKeepsAnExecutingMutationTombstoneUntilTheProcessStops()
print("PASS: disk removal keeps an executing mutation tombstone until the process stops")
settledWriteFailuresAndInspectionTimeoutsReachATerminalState()
print("PASS: settled write failures and inspection timeouts reach a terminal state")
await commandTimeoutOrCancellationKeepsTheDiskLeaseUntilQuiescedAndReconciled()
print("PASS: command timeout or cancellation keeps the disk lease until quiesced and reconciled")
await mutationCallbacksCannotBypassOrOutrunTheOneShotExecutor()
print("PASS: mutation callbacks cannot bypass or outrun the one-shot executor")
delayedUnmountObservationRetriesUntilFreshFactsOrTimeout()
print("PASS: delayed unmount observation retries until fresh facts or timeout")
presentationLayerKeepsSafetyActionsExplicit()
print("PASS: presentation layer keeps safety actions explicit")
volumePresentationUsesAFixedActionAndDisableMatrix()
print("PASS: VolumePresentation uses a fixed action and disable matrix")
setupPresentationShowsReadyEnvironment()
print("PASS: setup presentation shows a ready environment")
setupPresentationNormalizesActionableFailuresWithoutLeakingDriverNames()
print("PASS: setup presentation normalizes actionable failures without leaking driver names")
setupPresentationFailsClosedWhileRefreshing()
print("PASS: setup presentation fails closed while refreshing")
readOnlySetupGuideLeadsToRecheckAndReportsCompletion()
print("PASS: read-only Setup guide leads to recheck and reports completion")
readOnlySetupFeedbackUsesStableVisibleAndAccessibleText()
print("PASS: read-only Setup feedback uses stable visible and accessible text")
setupPresentationDistinguishesUnconfiguredAndRejectedTrustEvidence()
print("PASS: setup presentation preserves typed trust evidence")
setupReportContradictionsFailClosedAcrossPresentationAndFacts()
print("PASS: contradictory Setup reports fail closed across facts and presentation")
matchingReadOnlySystemEvidenceProducesAnUnknownHealthSnapshot()
print("PASS: matching read-only system evidence produces an unknown-health snapshot")
volumeNameAloneNeverClaimsBootCampIdentity()
print("PASS: volume name alone never claims Boot Camp identity")
unknownExternalNTFSIsVisibleOnlyAsAReadOnlyCandidate()
print("PASS: unknown external NTFS is visible only as a read-only candidate")
await conflictingParentLocationRemovesAReadOnlyCandidate()
print("PASS: conflicting parent location removes a read-only candidate")
await conflictingWholeDiskIdentityRemovesAReadOnlyCandidate()
print("PASS: conflicting whole-disk identity removes a read-only candidate")
await unverifiedEnumerationCoverageDoesNotExposeAReadOnlyCandidate()
print("PASS: unverified enumeration coverage does not expose a read-only candidate")
await unresolvedSiblingTopologyDoesNotExposeAReadOnlyCandidate()
print("PASS: unresolved sibling topology does not expose a read-only candidate")
readOnlyCandidatesRejectEveryAdditionalFactProblem()
print("PASS: read-only candidates reject every additional fact problem")
existingReadWriteMountRemainsUnverifiedForAReadOnlyCandidate()
print("PASS: an existing read-write mount remains unverified for a read-only candidate")
reinsertedCandidateDoesNotReuseTheOldSelection()
print("PASS: a reinserted candidate does not reuse the old selection")
await confirmedCurrentDataVolumeDeclarationProducesOnlyARequestApproval()
print("PASS: a confirmed current data-volume declaration produces only a request approval")
await dataVolumeDeclarationRequestCannotBeConsumedTwice()
print("PASS: a data-volume declaration request cannot be consumed twice")
await dataVolumeDeclarationDoesNotCrossSessionRotationOrApplicationRestart()
print("PASS: a data-volume declaration does not cross session rotation or restart")
await dataVolumeDeclarationRequiresTheCurrentObservationRevision()
print("PASS: a data-volume declaration requires the current observation revision")
await dataVolumeDeclarationRejectsInstanceAndSiblingTopologyDrift()
print("PASS: a data-volume declaration rejects instance and sibling topology drift")
await incompleteDataVolumeRoleObservationCannotApproveADeclaration()
print("PASS: an incomplete data-volume role observation cannot approve a declaration")
await dataVolumeDeclarationCannotOverrideCandidateEligibility()
print("PASS: a data-volume declaration cannot override candidate eligibility")
await protectedOrConflictingSiblingFactsOverrideDataVolumeDeclaration()
print("PASS: protected or conflicting siblings override a data-volume declaration")
await invalidSiblingTopologyCannotApproveADataVolumeDeclaration()
print("PASS: invalid sibling topology cannot approve a data-volume declaration")
await externalWindowsSystemCandidateRemainsUnknownWithoutConfirmation()
print("PASS: an external Windows system candidate remains unknown without confirmation")
trustedProtectedAndDataRolesMapWhileUnknownOrConflictingRolesFailClosed()
print("PASS: trusted protected and data roles map while unknown or conflicting roles fail closed")
contradictoryMountedEvidenceFailsClosed()
print("PASS: contradictory mounted evidence fails closed")
malformedReadOnlyIdentitiesNeverProduceTrustedSnapshots()
print("PASS: malformed read-only identities never produce trusted snapshots")
mountSourceParserAcceptsOnlyCanonicalLocalDiskDevices()
print("PASS: mount source parser accepts only canonical local disk devices")
liveMountTableReaderProducesReadOnlyFacts()
print("PASS: live mount table reader produces read-only facts")
mountTableReaderRequiresTwoConsecutiveStableSnapshots()
print("PASS: mount table reader requires two consecutive stable snapshots")
await liveDiskArbitrationStreamProducesReadOnlyDescriptions()
print("PASS: live Disk Arbitration stream produces read-only descriptions")
liveIOMediaEnumerationProducesAStableReadOnlySnapshot()
print("PASS: live IOMedia enumeration produces a stable read-only snapshot")
await multiVolumeInventorySharesOneGenerationAndDeduplicatesCallbacks()
print("PASS: multi-volume inventory shares one generation and deduplicates callbacks")
await inventoryNeverTreatsStartupSilenceAsACompleteEmptySystem()
print("PASS: inventory never treats startup silence as a complete empty system")
await independentIOMediaCoverageMustExactlyMatchTheDAInventory()
print("PASS: independent IOMedia coverage must exactly match the DA inventory")
iOMediaEnumerationRequiresTwoConsecutiveStableSnapshots()
print("PASS: IOMedia enumeration requires two consecutive stable snapshots")
await inventoryFailsClosedAfterUnidentifiableOrParentlessDiskEvents()
print("PASS: inventory fails closed after unidentifiable or parentless events")
await inventoryExcludesOnlyExplicitNetworkVolumeEvents()
print("PASS: inventory excludes only explicit network volume events")
diskArbitrationBooleanDecoderAcceptsOnlyCFBoolean()
print("PASS: Disk Arbitration boolean decoder accepts only CFBoolean")
await readOnlyObserverSettlesWithoutClaimingEnumerationCoverage()
print("PASS: read-only observer settles without claiming enumeration coverage")
await readOnlyObserverPromotesOnlyExactIndependentCoverage()
print("PASS: read-only observer promotes only exact independent coverage")
await readOnlyObserverCoverageTimeoutFailsClosed()
print("PASS: read-only observer coverage timeout fails closed")
await observerPublishesSettledIncompleteEvidenceWithoutFabricatingSnapshots()
print("PASS: observer publishes settled incomplete evidence without fabricating snapshots")
await liveReadOnlyObserverSettlesTheCurrentSystem()
print("PASS: live read-only observer settles the current system")
await liveReadOnlyObserverVerifiesIndependentEnumerationCoverage()
print("PASS: live read-only observer verifies independent enumeration coverage")
mountPathValidatorSeparatesCanonicalPathsFromSymlinksAndDotSegments()
print("PASS: mount path validator separates canonical paths from symlinks and dot segments")
await wholeDiskDisappearanceRotatesGenerationAfterAnIncompleteChange()
print("PASS: whole-disk disappearance rotates generation after an incomplete change")
gate1EvidenceHeaderAcceptsOnlyOpaqueEvidenceIDs()
print("PASS: Gate 1 evidence header accepts only opaque evidence IDs")
await gate1EvidenceWithoutHardwareCyclesStaysIncomplete()
print("PASS: Gate 1 evidence without hardware cycles stays incomplete")
await gate1EvidenceStatusExposesOnlyAnonymousBoundedProgress()
print("PASS: Gate 1 evidence status exposes only anonymous bounded progress")
await gate1EvidenceProjectsCandidateWithoutRawIdentityOrMutationEligibility()
print("PASS: Gate 1 evidence projects candidate without raw identity or mutation eligibility")
await gate1EvidenceNormalizesEquivalentVolumeUUIDCase()
print("PASS: Gate 1 evidence normalizes equivalent volume UUID case")
await gate1EvidenceCountsOnlyAConfirmedPresentToAbsentCycle()
print("PASS: Gate 1 evidence counts only a confirmed present-to-absent cycle")
await gate1EvidencePermanentlyFailsWhenGenerationChangesBeforeAbsence()
print("PASS: Gate 1 evidence permanently fails when generation changes before absence")
await gate1EvidenceFailsWhenGenerationIsReusedAfterConfirmedAbsence()
print("PASS: Gate 1 evidence fails when generation is reused after confirmed absence")
await gate1EvidenceFailsWhenGenerationRegressesAfterConfirmedAbsence()
print("PASS: Gate 1 evidence fails when generation regresses after confirmed absence")
await gate1EvidenceFailsWhenGenerationIsUnknownAfterConfirmedAbsence()
print("PASS: Gate 1 evidence fails when generation is unknown after confirmed absence")
await gate1EvidenceTracksOneHundredSyntheticCyclesWithoutAwardingGatePass()
print("PASS: Gate 1 evidence tracks 100 synthetic cycles without awarding Gate pass")
await gate1EvidenceRecordsOnlyClosedOperatorCheckpoints()
print("PASS: Gate 1 evidence records only closed operator checkpoints")
gate1EvidenceOperatorCommandParserAcceptsOnlyClosedGrammar()
print("PASS: Gate 1 evidence operator command parser accepts only closed grammar")
await gate1EvidenceInvalidCheckpointFailsClosedPermanently()
print("PASS: Gate 1 evidence invalid checkpoint fails closed permanently")
await gate1EvidenceBecomesReadyOnlyForHumanReviewAfterEveryRequirement()
print("PASS: Gate 1 evidence becomes ready only for human review after every requirement")
await gate1EvidenceRequiresAFinalVerifiedObservationForReviewReadiness()
print("PASS: Gate 1 evidence requires a final verified observation for review readiness")
await gate1EvidenceKeepsOnlyFixedIssueMeaningFromIncompleteObservations()
print("PASS: Gate 1 evidence keeps only fixed issue meaning from incomplete observations")
await gate1EvidenceObservationLimitFailsClosedWithoutEvictingOldEvidence()
print("PASS: Gate 1 evidence observation limit fails closed without evicting old evidence")
gate1EvidencePolicyRejectsZeroAndUnsealableBudgets()
print("PASS: Gate 1 evidence policy rejects zero and unsealable budgets")
await gate1EvidenceRejectsComparisonCheckpointsOutsideTheirTargetCycle()
print("PASS: Gate 1 evidence rejects comparisons outside their target cycle")
await gate1EvidenceDoesNotAggregateDifferentReviewableDisksIntoCycles()
print("PASS: Gate 1 evidence does not aggregate different reviewable disks")
await gate1EvidenceRejectsDuplicateVolumeTopologyAtomically()
print("PASS: Gate 1 evidence rejects duplicate volume topology atomically")
await gate1EvidenceRejectsCaseAliasedTypedVolumeTopology()
print("PASS: Gate 1 evidence rejects typed UUID-case alias topology")
await gate1EvidenceDoesNotCountMediaAlreadyPresentAtSessionStart()
print("PASS: Gate 1 evidence does not count media already present at session start")
await gate1EvidenceCountsPendingThenVerifiedInsertionExactlyOnce()
print("PASS: Gate 1 evidence counts pending then verified insertion exactly once")
await gate1EvidenceIgnoresPermanentNonTargetConnectionsForReadiness()
print("PASS: Gate 1 evidence ignores permanent non-target connections for readiness")
await gate1EvidenceSourceTerminationIsPermanentlyFailedClosed()
print("PASS: Gate 1 evidence source termination is permanently failed closed")
await gate1EvidenceRejectsEveryEventAfterPermanentFailure()
print("PASS: Gate 1 evidence rejects every event after permanent failure")
await gate1EvidenceTimestampRegressionFailsClosedPermanently()
print("PASS: Gate 1 evidence timestamp regression fails closed permanently")
await gate1EvidenceCheckpointLimitFailsClosedWithoutEvictingOldEvidence()
print("PASS: Gate 1 evidence checkpoint limit fails closed without evicting old evidence")
await gate1EvidenceDiskLimitRejectsTheWholeObservationAtomically()
print("PASS: Gate 1 evidence disk limit rejects the whole observation atomically")
await gate1EvidenceRejectsDuplicatePhysicalDiskTopologyAtomically()
print("PASS: Gate 1 evidence rejects duplicate physical disk topology atomically")
await gate1EvidenceVolumeLimitRejectsTheWholeObservationAtomically()
print("PASS: Gate 1 evidence volume limit rejects the whole observation atomically")
await gate1EvidenceEncodedByteLimitFailsClosedWithoutOversizedOutput()
print("PASS: Gate 1 evidence encoded byte limit fails closed without oversized output")
await gate1EvidenceVerifierAdmitsOnlyTheMatchingCanonicalArtifact()
print("PASS: Gate 1 evidence verifier admits only the matching canonical artifact")
await gate1EvidenceSealIsIdempotentAndClosesEveryInput()
print("PASS: Gate 1 evidence seal is idempotent and closes every input")
await gate1EvidenceVerifierRejectsDuplicateJSONMembersBeforeDecoding()
print("PASS: Gate 1 evidence verifier rejects duplicate JSON members before decoding")
await gate1EvidenceVerifierRejectsUnknownSchemaFieldsAndInvalidHeader()
print("PASS: Gate 1 evidence verifier rejects unknown schema fields and invalid header")
await gate1EvidenceVerifierRecomputesDerivedVerdict()
print("PASS: Gate 1 evidence verifier recomputes the derived verdict")
await gate1EvidenceVerifierReplaysEventsInsteadOfTrustingSummaries()
print("PASS: Gate 1 evidence verifier replays events instead of trusting summaries")
await gate1EvidenceVerifierRejectsForbiddenGenerationRelations()
print("PASS: Gate 1 evidence verifier rejects forbidden generation relations")
await gate1EvidenceVerifierAcceptsCanonicalDiskOrderWhenReconnectInputFlips()
print("PASS: Gate 1 evidence verifier accepts canonical order after flipped reconnect input")
semanticVersionParserHandlesTrustedDependencyOutput()
print("PASS: semantic version parser handles trusted dependency output")
setupFailsClosedWhenAuthorizationOrConflictScanIsUnknown()
print("PASS: setup fails closed when authorization or conflict scan is unknown")
setupEnvironmentEvidenceMapsToExplicitFacts()
print("PASS: setup environment evidence maps to explicit facts")
await liveSystemSetupFactsLoaderFailsClosedOnUnverifiedCapabilities()
print("PASS: live system setup facts loader fails closed on unverified capabilities")
await liveSetupProbeProviderExposesOnlyTypedBoundedOutput()
print("PASS: live Setup probe provider exposes only typed bounded output")
await boundedSetupProbeDoesNotWaitForInheritedOutputPipes()
print("PASS: inherited output pipes cannot keep a completed Setup probe alive")
await boundedSetupProbeStopsOnOutputOverflow()
print("PASS: Setup probe output overflow terminates within its fixed bound")
await cancellingSetupProbeStillConfirmsTheDirectProcessStops()
print("PASS: cancelling a Setup probe confirms its direct process stopped")
readOnlyDashboardNeverExposesMutationControlsOrRawIdentifiers()
print("PASS: read-only dashboard never exposes mutation controls or raw identifiers")
readOnlyDashboardGroupsAndSortsLongNamedPartitionsDeterministically()
print("PASS: read-only dashboard groups and sorts long-named partitions deterministically")
readOnlySelectionWaitsForAStableAbsenceBeforeResetting()
print("PASS: read-only selection waits for stable absence before resetting")
observationSubscriptionChangeResetsAnOtherwiseIdenticalSelection()
print("PASS: an observation subscription change resets an otherwise identical selection")
readOnlySelectionNeverResolvesAStaleVolumeAcrossRefreshes()
print("PASS: read-only selection never resolves a stale volume across refreshes")
readOnlyAccessibilityAnnouncementDescribesTheCurrentSelection()
print("PASS: accessibility announcement describes the current selection")
readOnlyDiagnosticFeedbackUsesStableVisibleAndAccessibleText()
print("PASS: read-only diagnostic feedback uses stable visible and accessible text")
await diagnosticsRetainsOnlyTypedBoundedDeterministicEntries()
print("PASS: diagnostics retains only typed bounded deterministic entries")
setupOutputParsersRejectAmbiguityAndUnknownRecords()
print("PASS: setup output parsers reject ambiguity and unknown records")
setupProbeEvaluatorRequiresExactFSKitElectionAndCompleteConflictEvidence()
print("PASS: setup probe evaluator requires exact FSKit election and complete conflict evidence")
candidateScopedConflictCatalogRequiresEveryBoundedEvidenceSource()
print("PASS: candidate-scoped conflict catalog requires every bounded evidence source")
liveConflictFootprintProviderUsesNoFollowTriStateTraversal()
print("PASS: live conflict footprint provider uses no-follow tri-state traversal")
await systemSetupLoaderConsumesTheInjectedScopedFootprintEvidence()
print("PASS: system Setup loader consumes injected scoped footprint evidence")
await diagnosticProjectionDropsRawDomainPoisonValues()
print("PASS: diagnostic projection drops raw domain poison values")
ntfsHealthParserAcceptsOnlyCanonicalBoundedEvidence()
print("PASS: NTFS health parser accepts only canonical bounded evidence")
safeMountCompilerEmitsOnlyTheFixedValidatedInvocation()
print("PASS: safe mount compiler emits only the fixed validated invocation")
await helperProtocolRoundTripsOnlyStrictStructuredRequests()
print("PASS: helper protocol round-trips only strict structured requests")
await trustedBundleVersionReaderRejectsUntrustedFilesystemEvidence()
print("PASS: trusted bundle version reader rejects untrusted filesystem evidence")
trustedMacFUSEEvidenceRejectsMixedFilesystemEpochs()
print("PASS: trusted macFUSE evidence rejects mixed filesystem epochs")
await diagnosticsRetentionIsBoundedByAgeAndEncodedBytes()
print("PASS: diagnostics retention is bounded by age and encoded bytes")
coordinatorEffectsCompileIntoExactlyFourHelperMutations()
print("PASS: coordinator effects compile into exactly four helper mutations")
await trustedExecutableVerifierPinsTheExactOpenedArtifact()
print("PASS: trusted executable verifier pins the exact opened artifact")
diagnosticApplicationIdentityUsesOnlyStrictBundleMetadata()
print("PASS: diagnostic application identity uses only strict bundle metadata")
await systemSetupReportPreservesFixedDependencyFailureEvidence()
print("PASS: system setup report preserves fixed dependency failure evidence")
await diagnosticSnapshotArchivePersistsOnlyCanonicalPrivateEvidence()
print("PASS: diagnostic snapshot archive persists only canonical private evidence")
readOnlyObservationSessionRejectsEveryStaleRefreshResult()
print("PASS: read-only observation session rejects every stale refresh result")
await readOnlyObserverFinishesAfterSettlementAndKeepsTheFirstZeroDelayEvent()
print("PASS: read-only observer finishes and keeps the first zero-delay event")
await readOnlyObservationCaptureDrainsAcceptedEventsBeforeItsSealBarrier()
print("PASS: read-only observation capture drains accepted events before its seal barrier")
await readOnlyObservationCaptureDistinguishesNaturalSourceEndFromDrain()
print("PASS: read-only observation capture distinguishes natural source end from drain")
await readOnlyObservationCaptureReportsAnUnverifiedFinalDrainSnapshot()
print("PASS: read-only observation capture reports an unverified final drain snapshot")
await helperAdmissionIsTheOnlyAtomicBoundedRequestEntryPoint()
print("PASS: helper admission is the only atomic bounded request entry point")

// MARK: - MountEngine adapter skeleton (NTFSLiteMutationPreparation)

func mountEngineActionPlannerRoutesEachClaimedCommandToItsConcreteAction() {
    let volumeTarget = VolumeInstanceID(
        volumeID: VolumeID(uuid: "ADAPTER-VOL-1", bsdName: "disk90s1"),
        diskInstanceID: DiskInstanceID(
            physicalDiskID: PhysicalDiskID(rawValue: "disk90"),
            mediaGeneration: MediaGeneration(rawValue: 90)
        )
    )
    let diskTarget = DiskInstanceID(
        physicalDiskID: PhysicalDiskID(rawValue: "disk90"),
        mediaGeneration: MediaGeneration(rawValue: 90)
    )
    let unmountOp = OperationID(rawValue: "adapter-unmount")
    let diskUnmountOp = OperationID(rawValue: "adapter-disk-unmount")
    let ejectOp = OperationID(rawValue: "adapter-eject")
    let mountPlan = MountPlan(
        operationID: OperationID(rawValue: "adapter-mount"),
        target: volumeTarget,
        policy: .fsKitCurrentUserNoRecovery
    )

    expect(
        MountEngineActionPlanner.action(
            for: .unmountVolumeStandard(operationID: unmountOp, target: volumeTarget)
        ) == .unmountVolume(operationID: unmountOp, target: volumeTarget),
        "a claimed volume unmount must route to a standard volume unmount action"
    )
    expect(
        MountEngineActionPlanner.action(
            for: .unmountDiskStandard(operationID: diskUnmountOp, target: diskTarget)
        ) == .unmountWholeDisk(operationID: diskUnmountOp, target: diskTarget),
        "a claimed whole-disk unmount must route to a standard whole-disk unmount action"
    )
    expect(
        MountEngineActionPlanner.action(
            for: .ejectDiskStandard(operationID: ejectOp, target: diskTarget)
        ) == .ejectWholeDisk(operationID: ejectOp, target: diskTarget),
        "a claimed whole-disk eject must route to a standard whole-disk eject action"
    )
    expect(
        MountEngineActionPlanner.action(for: .mountWrite(mountPlan))
            == .compileAndMountWritable(mountPlan),
        "a claimed writable mount must defer compilation to the execution boundary"
    )
}

func mountEngineTerminationMapperNeverInfersQuiescenceFromDeadlineOrCancellation() {
    let cases: [(MountEngineExecutionObservation, MountEngineTermination, String)] = [
        (.processReaped(terminationStatus: 0), .exited(terminationStatus: 0),
         "a positive reap reports the exact exit status"),
        (.processReaped(terminationStatus: 9), .exited(terminationStatus: 9),
         "a positive reap of a killed child still reports an explicit exit status"),
        (.diskArbitrationCallbackCompleted(posixStatus: 0), .exited(terminationStatus: 0),
         "a fired Disk Arbitration callback is itself quiescence"),
        (.diskArbitrationCallbackCompleted(posixStatus: 16), .exited(terminationStatus: 16),
         "a busy Disk Arbitration callback is still a completed, quiesced result"),
        (.deadlineElapsed(childReaped: true), .timedOutAfterConfirmedQuiescence,
         "a deadline only confirms quiescence once a reap observed the child gone"),
        (.deadlineElapsed(childReaped: false), .terminationUnconfirmed,
         "a deadline without a confirming reap must stay unconfirmed"),
        (.taskCancelled(childReaped: true), .cancelledAfterConfirmedQuiescence,
         "cancellation only confirms quiescence once a reap observed the child gone"),
        (.taskCancelled(childReaped: false), .terminationUnconfirmed,
         "cancellation without a confirming reap must stay unconfirmed"),
        (.unconfirmed, .terminationUnconfirmed,
         "an unconfirmed observation maps straight to an unconfirmed termination"),
    ]
    for (observation, expected, message) in cases {
        expect(
            MountEngineTerminationMapper.termination(from: observation) == expected,
            message
        )
    }
}

actor MountEngineExecutorSpy {
    private(set) var actions: [MountEngineAction] = []
    private let observation: MountEngineExecutionObservation

    init(observation: MountEngineExecutionObservation) {
        self.observation = observation
    }

    func execute(_ action: MountEngineAction) -> MountEngineExecutionObservation {
        actions.append(action)
        return observation
    }
}

func mountEngineAdapterForwardsTheRoutedActionAndMapsTheObservation() async {
    let spy = MountEngineExecutorSpy(observation: .processReaped(terminationStatus: 0))
    let adapter = MountEngineAdapter { action in
        await spy.execute(action)
    }
    let target = VolumeInstanceID(
        volumeID: VolumeID(uuid: "ADAPTER-VOL-2", bsdName: "disk91s1"),
        diskInstanceID: DiskInstanceID(
            physicalDiskID: PhysicalDiskID(rawValue: "disk91"),
            mediaGeneration: MediaGeneration(rawValue: 91)
        )
    )
    let operationID = OperationID(rawValue: "adapter-forward")

    let termination = await adapter.invoke(
        .unmountVolumeStandard(operationID: operationID, target: target)
    )

    expect(
        termination == .exited(terminationStatus: 0),
        "the adapter must map the executor's observation into the engine termination"
    )
    await expectAsync(
        await spy.actions == [.unmountVolume(operationID: operationID, target: target)],
        "the adapter must forward exactly the routed concrete action once"
    )
}

func mountEngineAdapterExecutionUnavailableAlwaysFailsClosed() async {
    let volumeTarget = VolumeInstanceID(
        volumeID: VolumeID(uuid: "ADAPTER-VOL-3", bsdName: "disk92s1"),
        diskInstanceID: DiskInstanceID(
            physicalDiskID: PhysicalDiskID(rawValue: "disk92"),
            mediaGeneration: MediaGeneration(rawValue: 92)
        )
    )
    let diskTarget = DiskInstanceID(
        physicalDiskID: PhysicalDiskID(rawValue: "disk92"),
        mediaGeneration: MediaGeneration(rawValue: 92)
    )
    let commands: [MutationCommand] = [
        .unmountVolumeStandard(operationID: OperationID(rawValue: "u"), target: volumeTarget),
        .unmountDiskStandard(operationID: OperationID(rawValue: "ud"), target: diskTarget),
        .ejectDiskStandard(operationID: OperationID(rawValue: "e"), target: diskTarget),
        .mountWrite(
            MountPlan(
                operationID: OperationID(rawValue: "m"),
                target: volumeTarget,
                policy: .fsKitCurrentUserNoRecovery
            )
        ),
    ]
    for command in commands {
        let termination = await MountEngineAdapter.executionUnavailable.invoke(command)
        expect(
            termination == .terminationUnconfirmed,
            "the execution-unavailable adapter must never report confirmed quiescence"
        )
    }
}

func mountEngineAdapterInvocationIsMountEngineCompatibleAndKeepsTheLeaseWhenUnconfirmed() async {
    let snapshot = makeSnapshot(
        uuid: "ADAPTER-ENGINE-1",
        bsdName: "disk93s1",
        displayName: "ADAPTER-ENGINE",
        physicalDiskID: PhysicalDiskID(rawValue: "adapter-engine-disk"),
        mediaGeneration: MediaGeneration(rawValue: 93)
    )
    let coordinator = makeCoordinator(
        snapshots: [snapshot],
        setupFactsProvider: readySetupFactsProvider()
    )
    guard case let .accepted(effect) = await coordinator.requestEnableWriting(
        target: snapshot.instanceID
    ) else {
        fatalError("CHECK FAILED: adapter engine setup should produce a mutation effect")
    }

    let engine = MountEngine(MountEngineAdapter.executionUnavailable.mountEngineInvocation)
    let result = await coordinator.executeMutation(
        effect: effect,
        resolveEvidence: { volumeMutationEvidence(snapshot) },
        engine: engine
    )

    await expectAsync(
        result == .executed(
            MountEngineResult(
                termination: .terminationUnconfirmed,
                requiredFreshEvidence: .volume(snapshot.instanceID)
            )
        ),
        "the adapter invocation must satisfy the MountEngine contract and report an unconfirmed termination"
    )
    await expectAsync(
        await coordinator.state(for: snapshot.id) == .unmountingForWrite,
        "an unconfirmed adapter termination must keep the operation pending fresh evidence"
    )
}

mountEngineActionPlannerRoutesEachClaimedCommandToItsConcreteAction()
print("PASS: MountEngine adapter routes each claimed command to its concrete action")
mountEngineTerminationMapperNeverInfersQuiescenceFromDeadlineOrCancellation()
print("PASS: MountEngine adapter never infers quiescence from a deadline or cancellation")
await mountEngineAdapterForwardsTheRoutedActionAndMapsTheObservation()
print("PASS: MountEngine adapter forwards the routed action and maps the observation")
await mountEngineAdapterExecutionUnavailableAlwaysFailsClosed()
print("PASS: MountEngine adapter execution-unavailable path always fails closed")
await mountEngineAdapterInvocationIsMountEngineCompatibleAndKeepsTheLeaseWhenUnconfirmed()
print("PASS: MountEngine adapter invocation satisfies the engine contract and keeps the lease when unconfirmed")

// MARK: - Read-only dashboard: an otherwise healthy Mac with no NTFS reads calm

func readOnlyDashboardTreatsNonNTFSPartitionGapsAsAnEmptySystem() {
    // An EFI / container partition: no volume UUID, name or filesystem. This is
    // normal on every Mac and makes the per-record and thus observation-level
    // `isComplete` false even when top-level enumeration is fully trustworthy.
    let systemPartition = ReadOnlyVolumeMapper.map(
        ReadOnlyVolumeEvidence(
            bsdName: "disk0s1",
            volumeUUID: nil,
            physicalDiskBSDName: "disk0",
            displayName: nil,
            fileSystemName: nil,
            isInternal: true,
            roleEvidence: .protected,
            diskArbitrationMountPoint: nil
        ),
        mount: nil,
        mediaGeneration: MediaGeneration(rawValue: 1)
    )
    expect(!systemPartition.isComplete, "a bare system partition record is expectedly incomplete")

    let internalDisk = ReadOnlyPhysicalDiskRecord(
        instanceID: DiskInstanceID(
            physicalDiskID: PhysicalDiskID(rawValue: "disk0"),
            mediaGeneration: MediaGeneration(rawValue: 1)
        ),
        description: DiskArbitrationDescription(
            bsdName: "disk0",
            physicalDiskBSDName: "disk0",
            isWholeDisk: true,
            isInternal: true,
            isEjectable: false,
            isRemovable: false,
            mediaSize: 2_000_000_000,
            mediaUUID: nil,
            volumeUUID: nil,
            volumeName: nil,
            fileSystemName: nil,
            mountPoint: nil
        ),
        volumes: [systemPartition],
        issues: []
    )

    let trustworthy = DiskInventoryObservation(
        physicalDisks: [internalDisk],
        issues: []
    )
    expect(!trustworthy.isComplete, "non-NTFS partition gaps still make the observation not fully complete")

    let calm = ReadOnlyDashboardPresenter.presentation(
        for: trustworthy,
        setupAssessment: SetupChecker.assess(readySetupFacts()),
        isSetupRefreshing: false
    )
    expect(
        calm.phase == .settled && calm.title == "未检测到 NTFS 磁盘",
        "a trustworthy enumeration with no NTFS must read as an empty system, not a read failure"
    )
    expect(!calm.writeControlsAvailable, "an empty settled dashboard still exposes no write controls")

    // A real top-level issue must still fail closed even with the same disks.
    let untrustworthy = ReadOnlyDashboardPresenter.presentation(
        for: DiskInventoryObservation(
            physicalDisks: [internalDisk],
            issues: [.enumerationCoverageUnverified]
        ),
        setupAssessment: SetupChecker.assess(readySetupFacts()),
        isSetupRefreshing: false
    )
    expect(
        untrustworthy.phase == .limited && untrustworthy.title == "磁盘信息尚未确认",
        "an unverified enumeration with no NTFS must keep the fail-closed headline"
    )

    // An incompletely-read *external* disk might be carrying the user's NTFS
    // volume, so it must stay cautious even when top-level facts are consistent.
    let unreadExternalPartition = ReadOnlyVolumeMapper.map(
        ReadOnlyVolumeEvidence(
            bsdName: "disk8s1",
            volumeUUID: nil,
            physicalDiskBSDName: "disk8",
            displayName: nil,
            fileSystemName: nil,
            isInternal: false,
            roleEvidence: .unknown,
            diskArbitrationMountPoint: nil
        ),
        mount: nil,
        mediaGeneration: MediaGeneration(rawValue: 8)
    )
    let externalDisk = ReadOnlyPhysicalDiskRecord(
        instanceID: DiskInstanceID(
            physicalDiskID: PhysicalDiskID(rawValue: "disk8"),
            mediaGeneration: MediaGeneration(rawValue: 8)
        ),
        description: DiskArbitrationDescription(
            bsdName: "disk8",
            physicalDiskBSDName: "disk8",
            isWholeDisk: true,
            isInternal: false,
            isEjectable: true,
            isRemovable: true,
            mediaSize: 64_000_000_000,
            mediaUUID: nil,
            volumeUUID: nil,
            volumeName: nil,
            fileSystemName: nil,
            mountPoint: nil
        ),
        volumes: [unreadExternalPartition],
        issues: []
    )
    let cautiousExternal = ReadOnlyDashboardPresenter.presentation(
        for: DiskInventoryObservation(physicalDisks: [externalDisk], issues: []),
        setupAssessment: SetupChecker.assess(readySetupFacts()),
        isSetupRefreshing: false
    )
    expect(
        cautiousExternal.phase == .limited
            && cautiousExternal.title == "磁盘信息尚未确认",
        "an incompletely-read external disk must not be dismissed as an empty system"
    )
}

readOnlyDashboardTreatsNonNTFSPartitionGapsAsAnEmptySystem()
print("PASS: read-only dashboard treats non-NTFS partition gaps as an empty system, not a read failure")

// MARK: - Read-only volume mapper: APFS snapshot (three-level) BSD names

func readOnlyVolumeMapperAcceptsAPFSSnapshotVolumeBSDNames() {
    // macOS mounts the sealed system volume from an APFS snapshot device whose
    // BSD name has three levels (e.g. disk3s1s1). It must not be flagged as an
    // invalid identity — that noise made every real Mac's observation
    // permanently non-complete.
    let snapshotVolume = ReadOnlyVolumeMapper.map(
        ReadOnlyVolumeEvidence(
            bsdName: "disk3s1s1",
            volumeUUID: "3A1A1A1A-0000-0000-0000-000000000001",
            physicalDiskBSDName: "disk3",
            displayName: "Macintosh HD",
            fileSystemName: "apfs",
            isInternal: true,
            roleEvidence: .protected,
            diskArbitrationMountPoint: nil
        ),
        mount: nil,
        mediaGeneration: MediaGeneration(rawValue: 3)
    )
    expect(
        !snapshotVolume.issues.contains(.invalidBSDName),
        "a three-level APFS snapshot BSD name is a valid volume identity"
    )

    // A path fragment or a whole-disk name must still be rejected.
    for bad in ["../disk9s1", "disk9", "disk9s1s", "disk9s1s2s3", "diskAs1"] {
        let record = ReadOnlyVolumeMapper.map(
            ReadOnlyVolumeEvidence(
                bsdName: bad,
                volumeUUID: "11111111-2222-3333-4444-555555555555",
                physicalDiskBSDName: "disk9",
                displayName: "X",
                fileSystemName: "ntfs",
                isInternal: false,
                roleEvidence: .trustedData,
                diskArbitrationMountPoint: nil
            ),
            mount: nil,
            mediaGeneration: MediaGeneration(rawValue: 9)
        )
        expect(
            record.issues.contains(.invalidBSDName) && record.snapshot == nil,
            "a malformed volume BSD name \(bad) must fail closed"
        )
    }
}

readOnlyVolumeMapperAcceptsAPFSSnapshotVolumeBSDNames()
print("PASS: read-only volume mapper accepts APFS snapshot BSD names and still rejects malformed identities")

func mountedNTFSFileSystemUUIDCanSupplyMissingCandidateIdentity() {
    let uuid = "31000000-0000-0000-0000-000000000001"
    let record = ReadOnlyVolumeMapper.map(
        ReadOnlyVolumeEvidence(
            bsdName: "disk31s1", volumeUUID: nil, physicalDiskBSDName: "disk31",
            displayName: "Fixture", fileSystemName: "ntfs", isInternal: false,
            roleEvidence: .unknown, diskArbitrationMountPoint: "/Volumes/Fixture"
        ),
        mount: ReadOnlyMountEvidence(
            sourceBSDName: "disk31s1", mountPoint: "/Volumes/Fixture", access: .readOnly,
            backend: .unknown, isComplete: true, isCanonical: true, isSymlink: false,
            fileSystemUUID: uuid
        ),
        mediaGeneration: MediaGeneration(rawValue: 31)
    )
    expect(record.candidate?.id.uuid == uuid, "native filesystem UUID should identify the read-only candidate")
    expect(record.evidence.volumeUUID == nil, "original Disk Arbitration evidence must remain unmodified")
    expect(record.snapshot == nil && record.issues == [.unknownVolumeRole], "supplemental identity grants no data role or mutation snapshot")
}

mountedNTFSFileSystemUUIDCanSupplyMissingCandidateIdentity()
print("PASS: mounted NTFS filesystem UUID supplies a missing read-only candidate identity")

func mountedNTFSIdentityNeverOverridesContradictoryEvidence() {
    let nativeUUID = "31000000-0000-0000-0000-000000000001"
    func record(daUUID: String?, source: String = "disk31s1", path: String = "/Volumes/Fixture",
                complete: Bool = true, canonical: Bool = true, symlink: Bool = false,
                role: VolumeRoleEvidence = .unknown, internalDisk: Bool? = false,
                fileSystem: String? = "ntfs", native: String = nativeUUID) -> ReadOnlyVolumeRecord {
        ReadOnlyVolumeMapper.map(
            ReadOnlyVolumeEvidence(
                bsdName: "disk31s1", volumeUUID: daUUID, physicalDiskBSDName: "disk31",
                displayName: "Fixture", fileSystemName: fileSystem, isInternal: internalDisk,
                roleEvidence: role, diskArbitrationMountPoint: "/Volumes/Fixture"
            ),
            mount: ReadOnlyMountEvidence(
                sourceBSDName: source, mountPoint: path, access: .readOnly,
                backend: .unknown, isComplete: complete, isCanonical: canonical, isSymlink: symlink,
                fileSystemUUID: native
            ),
            mediaGeneration: MediaGeneration(rawValue: 31)
        )
    }
    for invalid in [
        record(daUUID: "31000000-0000-0000-0000-000000000002"),
        record(daUUID: "malformed"), record(daUUID: ""),
        record(daUUID: nil, native: "not-a-uuid"),
        record(daUUID: nil, source: "disk32s1"), record(daUUID: nil, path: "/Volumes/Other"),
        record(daUUID: nil, complete: false), record(daUUID: nil, canonical: false),
        record(daUUID: nil, symlink: true), record(daUUID: nil, role: .trustedData),
        record(daUUID: nil, internalDisk: true), record(daUUID: nil, internalDisk: nil),
        record(daUUID: nil, fileSystem: "apfs")
    ] {
        expect(invalid.candidate == nil && invalid.snapshot == nil,
               "conflicting identities or incomplete mount/location/role facts must not be repaired by a supplemental UUID")
    }
    expect(record(daUUID: nativeUUID.uppercased()).candidate != nil,
           "equal UUIDs in different letter case must agree")
}

mountedNTFSIdentityNeverOverridesContradictoryEvidence()
print("PASS: supplemental NTFS identity rejects conflicts and preserves every existing safety constraint")

func mountedFileSystemUUIDDecodingRequiresExactReturnedAttributes() {
    let uuid = UUID(uuidString: "31000000-0000-0000-0000-000000000001")!
    let words: [UInt32] = [40, UInt32(ATTR_CMN_RETURNED_ATTRS), UInt32(ATTR_VOL_UUID), 0, 0, 0]
    var bytes = words.withUnsafeBytes { Data($0) }
    var value = uuid.uuid
    withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
    expect(MountedFileSystemUUIDReader.decode(bytes) == uuid.uuidString.lowercased(),
           "a complete returned ATTR_VOL_UUID must decode to the native filesystem identity")
    for offset in [0, 4, 8, 12, 16, 20] {
        var malformed = bytes
        malformed[offset] ^= 1
        expect(MountedFileSystemUUIDReader.decode(malformed) == nil,
               "length or unexpected returned attribute masks must fail closed")
    }
    for length in 0..<bytes.count {
        expect(MountedFileSystemUUIDReader.decode(Data(bytes.prefix(length))) == nil,
               "every truncated attribute response must fail closed")
    }
    expect(MountedFileSystemUUIDReader.decode(bytes + Data([0])) == nil, "trailing bytes must fail closed")
    let zero = words.withUnsafeBytes { Data($0) } + Data(repeating: 0, count: 16)
    expect(MountedFileSystemUUIDReader.decode(zero) == nil, "an all-zero UUID is not an identity")
}

mountedFileSystemUUIDDecodingRequiresExactReturnedAttributes()
print("PASS: filesystem UUID decoding rejects absent, truncated, unknown and zero attributes")

func mountedFileSystemUUIDReaderBindsTheExpectedMount() {
    var expected = statfs()
    let rootDescriptor = Darwin.open(NSTemporaryDirectory(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    expect(rootDescriptor >= 0, "root directory must open for the OS boundary check")
    defer { Darwin.close(rootDescriptor) }
    expect(fstatfs(rootDescriptor, &expected) == 0, "local root mount facts must be readable for the OS boundary check")
    let foundationUUID = try! URL(fileURLWithPath: NSTemporaryDirectory()).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    let actual = MountedFileSystemUUIDReader.read(for: expected)
    expect(actual != nil && actual == foundationUUID?.lowercased(), "descriptor-bound filesystem UUID must agree with the independent public API")
    var stale = expected
    stale.f_fsid.val.0 ^= 1
    expect(MountedFileSystemUUIDReader.read(for: stale) == nil, "a reused mount point with different fsid must fail closed")
    stale = expected
    stale.f_flags ^= UInt32(MNT_RDONLY)
    expect(MountedFileSystemUUIDReader.read(for: stale) == nil, "changed mount access must fail closed")
    stale = expected
    stale.f_mntfromname.0 = 88
    expect(MountedFileSystemUUIDReader.read(for: stale) == nil, "a different source device must fail closed")
    stale = expected
    stale.f_flags &= ~UInt32(MNT_LOCAL)
    expect(MountedFileSystemUUIDReader.read(for: stale) == nil, "network mounts must not enter the local identity reader")
}

mountedFileSystemUUIDReaderBindsTheExpectedMount()
print("PASS: native filesystem UUID is bound to the expected local mount and rejects stale mount facts")

func stableMountSnapshotsCarryFileSystemIdentity() throws {
    func snapshot(_ uuid: String) -> SystemMountTableSnapshot {
        SystemMountTableSnapshot(records: [SystemMountRecord(
            sourcePath: "/dev/disk31s1", sourceBSDName: "disk31s1", mountPoint: "/Volumes/Fixture",
            fileSystemName: "ntfs", access: .readOnly, backend: .unknown,
            isCanonical: true, isSymlink: false, fileSystemUUID: uuid
        )])
    }
    let first = snapshot("31000000-0000-0000-0000-000000000001")
    let second = snapshot("31000000-0000-0000-0000-000000000002")
    expect(first != second, "same paths with different filesystem UUIDs must not count as a stable mount table")
    expect(first.evidence(forBSDName: "disk31s1")?.fileSystemUUID == first.records[0].fileSystemUUID,
           "the stable mount boundary must deliver native filesystem identity to the volume mapper")
}

try stableMountSnapshotsCarryFileSystemIdentity()
print("PASS: stable mount snapshots compare and forward filesystem UUID evidence")

func ntfsIdentityDisplayObservation(
    uuid: String?, bsdName: String = "disk31s1", fileSystem: String? = "ntfs", issues: [DiskInventoryIssue] = [],
    diskIssues: [DiskInventoryIssue] = [], additionalVolumes: [ReadOnlyVolumeRecord] = []
) -> DiskInventoryObservation {
    let generation = MediaGeneration(rawValue: 31)
    let volume = ReadOnlyVolumeMapper.map(
        ReadOnlyVolumeEvidence(
            bsdName: bsdName, volumeUUID: uuid, physicalDiskBSDName: "disk31",
            displayName: "PRIVATE-LABEL", fileSystemName: fileSystem, isInternal: false,
            roleEvidence: .unknown, diskArbitrationMountPoint: nil
        ), mount: nil, mediaGeneration: generation
    )
    return DiskInventoryObservation(physicalDisks: [ReadOnlyPhysicalDiskRecord(
        instanceID: DiskInstanceID(physicalDiskID: PhysicalDiskID(rawValue: "disk31"), mediaGeneration: generation),
        description: DiskArbitrationDescription(
            bsdName: "disk31", physicalDiskBSDName: "disk31", isWholeDisk: true,
            isInternal: false, isEjectable: true, isRemovable: true, mediaSize: 32_000_000_000,
            mediaUUID: nil, volumeUUID: nil, volumeName: nil, fileSystemName: nil, mountPoint: nil
        ), volumes: [volume] + additionalVolumes, issues: diskIssues
    )], issues: issues)
}

func missingNTFSIdentityHasAnExplicitNonselectableExplanation() {
    let observation = ntfsIdentityDisplayObservation(uuid: nil)
    let dashboard = ReadOnlyDashboardPresenter.presentation(
        for: observation, setupAssessment: SetupAssessment(issues: []), isSetupRefreshing: false
    )
    expect(dashboard.phase == .limited && dashboard.title == "检测到 NTFS，但卷身份尚未确认",
           "a reported NTFS volume with no usable identity needs an explicit headline")
    expect(dashboard.detail.contains("系统未提供可核对的 NTFS 卷标识"), "missing UUID must have an accurate reason")
    expect(dashboard.volumes.isEmpty && dashboard.physicalDisks.isEmpty && !dashboard.writeControlsAvailable,
           "an explanation must not manufacture selectable identity or controls")
    expect(observation.coordinatorInventory == nil, "the explanation must not turn incomplete facts into mutation inventory")
    let announcement = ReadOnlyAccessibilityPresenter.announcement(for: .overview, in: dashboard)
    expect(announcement.contains(dashboard.detail), "overview accessibility must include the same reason")
    expect(!announcement.contains("PRIVATE-LABEL") && !announcement.contains("disk31"), "unverified raw labels and identities must stay private")
}

missingNTFSIdentityHasAnExplicitNonselectableExplanation()
print("PASS: missing NTFS identity is explained without selectable or mutation authority")

func unconfirmedNTFSIdentityExplanationHandlesMixedAndUnverifiedObservations() {
    func dashboard(_ observation: DiskInventoryObservation) -> ReadOnlyDashboardPresentation {
        ReadOnlyDashboardPresenter.presentation(for: observation, setupAssessment: SetupAssessment(issues: []), isSetupRefreshing: false)
    }
    let invalid = dashboard(ntfsIdentityDisplayObservation(uuid: "PRIVATE-INVALID-UUID"))
    expect(invalid.title == "检测到 NTFS，但卷身份尚未确认"
        && invalid.detail.contains("NTFS 卷标识无效或互相矛盾")
        && !invalid.detail.contains("PRIVATE-INVALID-UUID"), "invalid identity must have a precise private explanation")

    let valid = ntfsIdentityDisplayObservation(uuid: "31000000-0000-0000-0000-000000000001", bsdName: "disk31s2")
    let mixed = dashboard(ntfsIdentityDisplayObservation(uuid: nil, additionalVolumes: valid.physicalDisks[0].volumes))
    expect(mixed.title == "部分 NTFS 卷身份尚未确认" && mixed.volumes.count == 1
        && mixed.detail.contains("可查看 1 个 NTFS 卷") && mixed.detail.contains("系统未提供"),
           "one selectable volume must not hide a different incomplete identity")
    for uncertain in [
        ntfsIdentityDisplayObservation(uuid: nil, issues: [.enumerationCoverageUnverified]),
        ntfsIdentityDisplayObservation(uuid: nil, issues: [.mountTableReadFailed]),
        ntfsIdentityDisplayObservation(uuid: nil, diskIssues: [.physicalParentMismatch(bsdName: "disk31")]),
        ntfsIdentityDisplayObservation(uuid: nil, fileSystem: nil),
        ntfsIdentityDisplayObservation(uuid: nil, fileSystem: "exfat")
    ] {
        expect(dashboard(uncertain).title == "磁盘信息尚未确认", "unverified observations must not be promoted to verified NTFS detection")
    }
    let scanning = dashboard(ntfsIdentityDisplayObservation(uuid: nil, issues: [.initialEnumerationPending]))
    expect(scanning.phase == .scanning && !scanning.detail.contains("卷标识"), "refresh must clear the old identity explanation")
    expect(dashboard(valid).volumes.count == 1 && !dashboard(valid).detail.contains("卷标识"), "recovered identity must restore the ordinary candidate")
    let absent = dashboard(DiskInventoryObservation(physicalDisks: [], issues: []))
    expect(absent.title == "未检测到 NTFS 磁盘", "verified disappearance must remove the old identity explanation")
}

unconfirmedNTFSIdentityExplanationHandlesMixedAndUnverifiedObservations()
print("PASS: NTFS identity explanations handle invalid, mixed, uncertain, refreshed and absent observations")

func failedNativeIdentityReadCannotBeHiddenByDAIdentity() {
    let mount = SystemMountRecord(
        sourcePath: "/dev/disk31s1", sourceBSDName: "disk31s1", mountPoint: "/Volumes/Fixture",
        fileSystemName: "ntfs", access: .readOnly, backend: .unknown,
        isCanonical: true, isSymlink: false, isComplete: false
    )
    expect(mount.volumeEvidence?.isComplete == false, "a failed or contradictory native identity read must remain an incomplete mount record")
    let record = ReadOnlyVolumeMapper.map(
        ReadOnlyVolumeEvidence(
            bsdName: "disk31s1", volumeUUID: "31000000-0000-0000-0000-000000000001",
            physicalDiskBSDName: "disk31", displayName: "Fixture", fileSystemName: "ntfs",
            isInternal: false, roleEvidence: .unknown, diskArbitrationMountPoint: "/Volumes/Fixture"
        ), mount: mount.volumeEvidence, mediaGeneration: MediaGeneration(rawValue: 31)
    )
    expect(record.candidate == nil && record.snapshot == nil && record.issues.contains(.incompleteMountTableEntry),
           "an available DA UUID cannot erase a failed native mount identity check")
}

failedNativeIdentityReadCannotBeHiddenByDAIdentity()
print("PASS: native mount identity failures remain incomplete even when DA reports a UUID")

func gate1EvidenceRejectsReplacementTargetReusingTheSameBSDName() async {
    let firstUUID = "73100000-0000-0000-0000-000000000001"
    let secondUUID = "73100000-0000-0000-0000-000000000002"
    func observation(_ uuid: String) async -> DiskInventoryObservation {
        await gate1UnknownCandidateObservation(
            diskBSDName: "disk731", volumeBSDName: "disk731s1",
            volumeUUID: uuid, volumeName: "TARGET", mountPoint: "/Volumes/TARGET"
        )
    }
    let first = await observation(firstUUID)
    for reconnect in [false, true] {
        let second = gate1Observation(
            await observation(secondUUID), replacingMediaGeneration: reconnect ? 2 : 1
        )
        let recorder = Gate1EvidenceRecorder(header: try! Gate1EvidenceHeader(
            evidenceID: gate1FixtureEvidenceID,
            applicationVersion: GateEvidenceVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1, applicationSHA256: String(repeating: "3", count: 64),
            macOSVersion: GateEvidenceVersion(major: 26, minor: 6, patch: 2)
        ))
        let absent = DiskInventoryObservation(physicalDisks: [], issues: [])
        try! await recorder.ingest(absent, at: GateEvidenceTimestamp(millisecondsSince1970: 0))
        try! await recorder.ingest(first, at: GateEvidenceTimestamp(millisecondsSince1970: 1))
        if reconnect {
            try! await recorder.ingest(absent, at: GateEvidenceTimestamp(millisecondsSince1970: 2))
        }
        do {
            try await recorder.ingest(second, at: GateEvidenceTimestamp(millisecondsSince1970: 3))
            fatalError("CHECK FAILED: a different UUID reusing the target BSD name must be rejected")
        } catch let error as Gate1EvidenceRecorderError {
            expect(error == .topologyContradiction, "replacement target must use the closed topology error")
        } catch {
            fatalError("CHECK FAILED: replacement target used an unexpected error: \(error)")
        }
        let status = await recorder.status()
        expect(status.phase == .failedClosed && status.completedCycleCount == (reconnect ? 1 : 0)
            && status.observationCount == (reconnect ? 3 : 2),
            "replacement target must not commit an observation or another cycle")
        let artifact = try! await recorder.seal(at: GateEvidenceTimestamp(millisecondsSince1970: 4))
        expect(artifact.bundle.verdict == .failedClosed, "target replacement must remain failed closed at seal")
        let json = String(decoding: artifact.canonicalJSON, as: UTF8.self)
        expect(!json.contains(firstUUID) && !json.contains(secondUUID) && !json.contains("disk731"),
               "session-only identity checks must not add raw identities to canonical evidence")
        expect(Gate1EvidenceArtifactVerifier.verify(
            canonicalJSON: artifact.canonicalJSON, expectedSHA256Digest: artifact.sha256Digest
        ) == .success(artifact), "identity rejection must still seal a verifiable failed-closed artifact")
    }
}

await gate1EvidenceRejectsReplacementTargetReusingTheSameBSDName()
print("PASS: a different target UUID cannot reuse a BSD name to accumulate Gate cycles")

func boundedSetupProbeRequiresBothOutputStreamsToFinish() async {
    let scripts: [(String, ReadOnlyCommandCompletion)] = [
        ("printf ok", .exited(0)),
        ("printf ok; printf error >&2; exit 7", .exited(7)),
        ("(sleep 1; printf late) 2>/dev/null & printf ok", .outputUnreadable),
        ("(sleep 1; printf late >&2) >/dev/null & printf ok", .outputUnreadable),
    ]
    for (script, expected) in scripts {
        let invocation = SetupProbeInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            timeout: .milliseconds(250), maximumOutputBytes: 64
        )
        let started = ContinuousClock.now
        let result = await BoundedReadOnlyCommandRunner().run(invocation: invocation)
        expect(result.completion == expected,
               "complete output should preserve exit status; a delayed tail on either stream must fail closed")
        expect(result.standardOutput == "ok", "available bounded output should remain available for parsing")
        expect(started.duration(to: .now) < .seconds(1), "unconfirmed output must retain the fixed drain bound")
    }
}

await boundedSetupProbeRequiresBothOutputStreamsToFinish()
print("PASS: Setup probes require EOF on both streams and reject delayed stdout or stderr")
