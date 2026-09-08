import NTFSLiteCore

/// The concrete action a future execution adapter must perform for one
/// coordinator-claimed `MutationCommand`.
///
/// Producing this value is pure: it starts no process, issues no Disk
/// Arbitration call and compiles no mount invocation. Compilation of a writable
/// mount is deliberately deferred to `compileAndMountWritable` so that the
/// trusted-artifact evidence cannot go stale between "planned" and "launched".
package enum MountEngineAction: Equatable, Sendable {
    /// Standard (non-forced) unmount of a single volume.
    case unmountVolume(operationID: OperationID, target: VolumeInstanceID)
    /// Standard (non-forced) unmount of every mount on a whole physical disk.
    case unmountWholeDisk(operationID: OperationID, target: DiskInstanceID)
    /// Standard eject of a whole physical disk.
    case ejectWholeDisk(operationID: OperationID, target: DiskInstanceID)
    /// The executor must, immediately before process creation and as close to
    /// atomically as the launch boundary allows:
    ///
    /// 1. compile this plan with `SafeMountInvocationCompiler`,
    /// 2. pass `SafeMountInvocation.executionArtifactGate
    ///    .revalidateImmediatelyBeforeExecution()`,
    /// 3. only then create the mount process.
    ///
    /// If any step fails, no process is created and the executor reports
    /// `.unconfirmed`.
    case compileAndMountWritable(MountPlan)
}

/// Pure classification of a coordinator-claimed `MutationCommand` into the
/// concrete action a real executor must carry out. Total and side-effect free.
package enum MountEngineActionPlanner {
    package static func action(for command: MutationCommand) -> MountEngineAction {
        switch command {
        case let .unmountVolumeStandard(operationID, target):
            .unmountVolume(operationID: operationID, target: target)
        case let .unmountDiskStandard(operationID, target):
            .unmountWholeDisk(operationID: operationID, target: target)
        case let .ejectDiskStandard(operationID, target):
            .ejectWholeDisk(operationID: operationID, target: target)
        case let .mountWrite(plan):
            .compileAndMountWritable(plan)
        }
    }
}

/// Observed facts reported by a real launch-and-wait, as opposed to a verdict.
/// `MountEngineTerminationMapper` turns this into a `MountEngineTermination`.
///
/// The distinction matters: the coordinator releases a whole-disk lease only
/// when the returned termination has confirmed quiescence, so anything short of
/// a positive reap or a completed callback must stay `.unconfirmed`.
package enum MountEngineExecutionObservation: Equatable, Sendable {
    /// `waitpid` / a termination handler positively observed the child leave the
    /// process table with this status.
    case processReaped(terminationStatus: Int32)
    /// The Disk Arbitration completion callback for an unmount or eject fired
    /// with this POSIX status (`0` == success). A DA operation leaves no child
    /// process, so a fired callback is itself quiescence.
    case diskArbitrationCallbackCompleted(posixStatus: Int32)
    /// The operation deadline elapsed. `childReaped` is `true` only if a
    /// subsequent reap positively observed the child gone.
    case deadlineElapsed(childReaped: Bool)
    /// The task was cancelled. `childReaped` follows the same rule.
    case taskCancelled(childReaped: Bool)
    /// A termination signal was sent but no reap confirmed the child is gone; or
    /// the launcher never produced a child; or compilation / the pre-execution
    /// artifact gate failed; or no execution primitive is available.
    case unconfirmed
}

/// Pure mapping from observed execution facts to a `MountEngineTermination`.
///
/// Invariant: quiescence is asserted **only** from a positive reap or a fired
/// Disk Arbitration callback. A deadline, a cancellation or a sent signal never
/// *infers* that the child stopped.
package enum MountEngineTerminationMapper {
    package static func termination(
        from observation: MountEngineExecutionObservation
    ) -> MountEngineTermination {
        switch observation {
        case let .processReaped(status):
            .exited(terminationStatus: status)
        case let .diskArbitrationCallbackCompleted(status):
            .exited(terminationStatus: status)
        case let .deadlineElapsed(childReaped):
            childReaped ? .timedOutAfterConfirmedQuiescence : .terminationUnconfirmed
        case let .taskCancelled(childReaped):
            childReaped ? .cancelledAfterConfirmedQuiescence : .terminationUnconfirmed
        case .unconfirmed:
            .terminationUnconfirmed
        }
    }
}

/// Skeleton of the real `MountEngine` execution adapter.
///
/// It owns the pure half of the contract — routing a claimed command to its
/// concrete action and mapping the observed outcome back to a
/// `MountEngineTermination` — and takes the impure half (the actual launch and
/// wait) as an injected `Executor`. This module intentionally ships **no**
/// process- or Disk-Arbitration-backed executor: that belongs to a future
/// target that first defines an FD-bound launch boundary and passes the
/// hardware Gates. Use `executionUnavailable` for any wiring that must compile
/// today.
package struct MountEngineAdapter: Sendable {
    package typealias Executor =
        @Sendable (MountEngineAction) async -> MountEngineExecutionObservation

    private let executor: Executor

    package init(executor: @escaping Executor) {
        self.executor = executor
    }

    /// `MountEngine`-compatible entry point: pass `adapter.mountEngineInvocation`
    /// to `VolumeCoordinator.executeMutation(effect:resolveEvidence:invoke:)`.
    package func invoke(_ command: MutationCommand) async -> MountEngineTermination {
        MountEngineTerminationMapper.termination(
            from: await executor(MountEngineActionPlanner.action(for: command))
        )
    }

    package var mountEngineInvocation:
        @Sendable (MutationCommand) async -> MountEngineTermination
    {
        { await invoke($0) }
    }

    /// A fail-closed adapter safe to reference from wiring code: every command is
    /// classified, but the executor always reports `.unconfirmed`, so every call
    /// maps to `.terminationUnconfirmed` and the coordinator keeps the
    /// whole-disk lease and forces a fresh observation.
    package static let executionUnavailable = MountEngineAdapter(
        executor: { _ in .unconfirmed }
    )
}
