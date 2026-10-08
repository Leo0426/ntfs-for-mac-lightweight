import Foundation

// Deterministic OS boundary: the real coordinator owns sequencing and admission.
actor ProbeSystem: RuntimeProbeSystem {
    var mountValue: RuntimeProbeMount = .absent
    var driverValue: RuntimeProbeDriver
    var events: [String] = []
    var reads: [RuntimeProbeMount]
    let prepared: Bool?
    let started: Bool?
    let unmounted: Bool?
    let removed: Bool
    let exitAfterUnmount: RuntimeProbeDriver
    var preparationPaused: Bool
    var continuation: CheckedContinuation<Void, Never>?
    init(reads: [RuntimeProbeMount] = [], driver: RuntimeProbeDriver = .running,
         prepared: Bool? = true, started: Bool? = true, unmounted: Bool? = true,
         removed: Bool = true, exitAfterUnmount: RuntimeProbeDriver = .reaped(success: true),
         pausePreparation: Bool = false) {
        self.reads = reads; self.driverValue = driver; self.prepared = prepared
        self.started = started; self.unmounted = unmounted; self.removed = removed
        self.exitAfterUnmount = exitAfterUnmount; preparationPaused = pausePreparation
    }
    func prepare() async -> Bool? {
        events.append("prepare")
        if preparationPaused { await withCheckedContinuation { continuation = $0 } }
        return prepared
    }
    func releasePreparation() { preparationPaused = false; continuation?.resume(); continuation = nil }
    func isPaused() -> Bool { continuation != nil }
    func start() -> Bool? { events.append("start"); mountValue = .owned(writable: true); return started }
    func mount() -> RuntimeProbeMount {
        if !reads.isEmpty { mountValue = reads.removeFirst() }
        return mountValue
    }
    func driver() -> RuntimeProbeDriver { driverValue }
    func standardUnmount() -> Bool? {
        events.append("unmount")
        if unmounted == true { mountValue = .absent; driverValue = exitAfterUnmount }
        return unmounted
    }
    func remove() -> Bool { events.append("remove"); return removed }
    func pause() async {}
}
func expect(_ condition: Bool, _ message: String) {
    guard condition else { print("CHECK FAILED: " + message); exit(1) }
}
@main struct RuntimeProbeChecks {
    static func main() async {
        let coordinator = RuntimeProbeCoordinator(pollLimit: 2)
        let system = ProbeSystem()
        expect(await coordinator.run(system: system) == .ready,
               "owned writable image and full standard cleanup must authorize runtime without FSClient visibility")
        expect(await system.events == ["prepare", "start", "unmount", "remove"], "success follows normal cleanup")
        expect(await coordinator.isHoldingResources() == false, "complete cleanup releases qualification")
        for state in [RuntimeProbeQualification.present, .unknown] {
            expect(await coordinator.isHoldingResources(persistentQualification: state),
                   "a new daemon must block all mutations and idle exit when persistent qualification exists or is unknown")
        }
        let next = ProbeSystem()
        expect(await coordinator.run(system: next) == .ready, "later requests run a fresh image proof")
        expect(await next.events == ["prepare", "start", "unmount", "remove"], "readiness must not be cached")

        let vanished = ProbeSystem(reads: [.owned(writable: true), .absent], driver: .reaped(success: true))
        expect(await RuntimeProbeCoordinator(pollLimit: 2).run(system: vanished) != .ready,
               "disappeared mount without verified standard unmount cannot grant readiness")
        let readOnly = ProbeSystem(reads: [.owned(writable: false)])
        expect(await RuntimeProbeCoordinator(pollLimit: 2).run(system: readOnly) == .unavailable,
               "known owned read-only mount must be normally cleaned and refuse readiness")
        expect(await readOnly.events.contains("unmount"), "failed writable verification still cleans owned mount")
        let changed = ProbeSystem(reads: [.owned(writable: true), .owned(writable: false)])
        expect(await RuntimeProbeCoordinator(pollLimit: 2).run(system: changed) == .unavailable,
               "writable proof must remain true immediately before standard unmount")
        let failedStart = ProbeSystem(started: false)
        expect(await RuntimeProbeCoordinator(pollLimit: 2).run(system: failedStart) == .unavailable,
               "known failed spawn removes only the disposable image")
        expect(await failedStart.events == ["prepare", "start", "remove"], "spawn failure cannot unmount any target")
        let failedMount = ProbeSystem(reads: [.absent], driver: .reaped(success: false))
        expect(await RuntimeProbeCoordinator(pollLimit: 2).run(system: failedMount) == .unavailable,
               "disabled or unavailable backend leaves physical target untouched")
        expect(await failedMount.events == ["prepare", "start", "remove"], "no mount means no unmount")

        for failed in [ProbeSystem(reads: [.unknown]), ProbeSystem(unmounted: false),
                       ProbeSystem(unmounted: nil), ProbeSystem(exitAfterUnmount: .running),
                       ProbeSystem(exitAfterUnmount: .unknown), ProbeSystem(removed: false),
                       ProbeSystem(prepared: nil), ProbeSystem(started: nil),
                       ProbeSystem(reads: [.absent])] {
            let blocked = RuntimeProbeCoordinator(pollLimit: 2)
            expect(await blocked.run(system: failed) == .unresolved, "unknown cleanup must retain qualification")
            expect(await blocked.isHoldingResources(), "unresolved work must block daemon idle exit")
            let retry = ProbeSystem()
            expect(await blocked.run(system: retry) == .unresolved, "no new probe after unresolved cleanup")
            expect(await retry.events.isEmpty, "blocked qualification cannot create another image")
        }
        let unknown = ProbeSystem(reads: [.unknown])
        _ = await RuntimeProbeCoordinator(pollLimit: 2).run(system: unknown)
        expect(await unknown.events == ["prepare", "start"], "unknown ownership never unmounts or deletes")
        let noSeed = ProbeSystem(prepared: false)
        expect(await RuntimeProbeCoordinator(pollLimit: 2).run(system: noSeed) == .unavailable,
               "known preparation failure refuses without spawning")
        expect(await noSeed.events == ["prepare"], "untrusted seed cannot start a driver")

        let gated = ProbeSystem(pausePreparation: true)
        let concurrent = RuntimeProbeCoordinator(pollLimit: 2)
        let pending = Task { await concurrent.run(system: gated) }
        for _ in 0..<10000 { if await gated.isPaused() { break }; await Task.yield() }
        expect(await gated.isPaused(), "deterministic concurrent preparation checkpoint")
        let overlapping = ProbeSystem()
        expect(await concurrent.run(system: overlapping) == .unavailable, "concurrent proof cannot steal qualification")
        expect(await overlapping.events.isEmpty, "concurrent proof cannot allocate or spawn")
        pending.cancel()
        await gated.releasePreparation()
        expect(await pending.value == .unavailable, "cancelled request cannot grant readiness")
        expect(await gated.events == ["prepare", "start", "unmount", "remove"], "cancellation must still finish normal cleanup")
        expect(await concurrent.isHoldingResources() == false, "completed cancellation releases qualification")
        print("PASS: runtime image proof is fresh, exclusive, cleaned before readiness and retained on unknown outcomes")
    }
}
