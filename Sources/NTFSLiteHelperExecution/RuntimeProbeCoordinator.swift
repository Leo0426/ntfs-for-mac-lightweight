import Foundation

public enum RuntimeProbeResult: Equatable, Sendable { case ready, unavailable, unresolved }
public enum RuntimeProbeMount: Equatable, Sendable { case absent, owned(writable: Bool), unknown }
public enum RuntimeProbeDriver: Equatable, Sendable { case running, reaped(success: Bool), unknown }
public enum RuntimeProbeQualification: Equatable, Sendable { case absent, present, unknown }

/// One disposable image only; no physical target or caller-supplied path enters this interface.
public protocol RuntimeProbeSystem: Sendable {
    func prepare() async -> Bool?
    func start() async -> Bool?
    func mount() async -> RuntimeProbeMount
    func driver() async -> RuntimeProbeDriver
    func standardUnmount() async -> Bool?
    func remove() async -> Bool
    func pause() async
}

/// A process-wide qualification, independent of per-physical-disk execution leases.
public actor RuntimeProbeCoordinator {
    private var retained: (any RuntimeProbeSystem)?
    private var unresolved = false
    private let pollLimit: Int

    public init(pollLimit: Int = 80) {
        precondition(pollLimit > 0)
        self.pollLimit = pollLimit
    }
    public func isHoldingResources(persistentQualification: RuntimeProbeQualification = .absent) -> Bool {
        retained != nil || persistentQualification != .absent
    }

    public func run(system: any RuntimeProbeSystem) async -> RuntimeProbeResult {
        guard retained == nil else { return unresolved ? .unresolved : .unavailable }
        retained = system
        let prepared = await system.prepare()
        guard prepared == true else { return finish(prepared == false ? .unavailable : .unresolved) }
        let started = await system.start()
        guard started == true else {
            guard started == false, await system.remove() else { return finish(.unresolved) }
            return finish(.unavailable)
        }

        var mountedWritable = false
        var observed = RuntimeProbeMount.absent
        for _ in 0..<pollLimit {
            observed = await system.mount()
            if case let .owned(writable) = observed { mountedWritable = writable; break }
            guard observed == .absent else { return finish(.unresolved) }
            let driver = await system.driver()
            if case .reaped = driver { break }
            guard driver == .running else { return finish(.unresolved) }
            await system.pause()
        }
        // Recheck ownership immediately before unmounting, including the startup-timeout path.
        observed = await system.mount()
        var standardUnmountVerified = false
        if case let .owned(writable) = observed {
            mountedWritable = mountedWritable && writable
            guard await system.standardUnmount() == true else { return finish(.unresolved) }
            standardUnmountVerified = true
        } else if observed != .absent {
            return finish(.unresolved)
        }
        guard await system.mount() == .absent else { return finish(.unresolved) }
        var exitSuccess: Bool?
        for _ in 0..<pollLimit {
            switch await system.driver() {
            case let .reaped(success): exitSuccess = success
            case .running: await system.pause()
            case .unknown: return finish(.unresolved)
            }
            if exitSuccess != nil { break }
        }
        guard let exitSuccess, await system.mount() == .absent,
              await system.remove() else { return finish(.unresolved) }
        return finish(mountedWritable && standardUnmountVerified && exitSuccess && !Task.isCancelled ? .ready : .unavailable)
    }

    private func finish(_ result: RuntimeProbeResult) -> RuntimeProbeResult {
        if result == .unresolved { unresolved = true }
        else { retained = nil }
        return result
    }
}
