import Foundation

public enum DiskEventStreamItem: Equatable, Sendable {
    case event(DiskArbitrationEvent)
    case drainBoundary
}

public struct DiskEventStreamSession: Sendable {
    public let items: AsyncStream<DiskEventStreamItem>

    private let requestStopAndDrain: @Sendable () async -> Bool
    private let requestImmediateStop: @Sendable () -> Void

    public init(
        items: AsyncStream<DiskEventStreamItem>,
        stopAndDrain: @escaping @Sendable () async -> Bool,
        stopImmediately: @escaping @Sendable () -> Void
    ) {
        self.items = items
        requestStopAndDrain = stopAndDrain
        requestImmediateStop = stopImmediately
    }

    public func stopAndDrain() async -> Bool {
        await requestStopAndDrain()
    }

    public func stopImmediately() {
        requestImmediateStop()
    }
}

public struct DiskEventStreamProvider: Sendable {
    private let loadSession: @Sendable () throws -> DiskEventStreamSession

    public init(
        _ loadEvents: @escaping @Sendable () throws -> AsyncStream<DiskArbitrationEvent>
    ) {
        loadSession = {
            let events = try loadEvents()
            let pair = AsyncStream<DiskEventStreamItem>.makeStream()
            let forwardingTask = Task {
                for await event in events {
                    guard !Task.isCancelled else {
                        break
                    }
                    guard case .terminated = pair.continuation.yield(.event(event)) else {
                        continue
                    }
                    break
                }
                pair.continuation.finish()
            }
            pair.continuation.onTermination = { @Sendable _ in
                forwardingTask.cancel()
            }
            return DiskEventStreamSession(
                items: pair.stream,
                stopAndDrain: { false },
                stopImmediately: {
                    forwardingTask.cancel()
                    pair.continuation.finish()
                }
            )
        }
    }

    public init(
        session loadSession: @escaping @Sendable () throws -> DiskEventStreamSession
    ) {
        self.loadSession = loadSession
    }

    public func session() throws -> DiskEventStreamSession {
        try loadSession()
    }

    public static let live = DiskEventStreamProvider(session: {
        try DiskArbitrationEventSource().eventStreamSession()
    })
}

public enum ReadOnlyDiskObservationCaptureTerminal: Equatable, Sendable {
    case drained(finalObservationVerified: Bool)
    case sourceEndedUnexpectedly
}

public enum ReadOnlyDiskObservationCaptureEvent: Equatable, Sendable {
    case observation(DiskInventoryObservation)
    case terminal(ReadOnlyDiskObservationCaptureTerminal)
}

public struct ReadOnlyDiskObservationCapture: Sendable {
    public let events: AsyncStream<ReadOnlyDiskObservationCaptureEvent>

    private let requestStopAndDrain: @Sendable () async -> Bool
    private let requestImmediateStop: @Sendable () -> Void

    fileprivate init(
        events: AsyncStream<ReadOnlyDiskObservationCaptureEvent>,
        stopAndDrain: @escaping @Sendable () async -> Bool,
        stopImmediately: @escaping @Sendable () -> Void
    ) {
        self.events = events
        requestStopAndDrain = stopAndDrain
        requestImmediateStop = stopImmediately
    }

    public func stopAndDrain() async -> Bool {
        await requestStopAndDrain()
    }

    public func stopImmediately() {
        requestImmediateStop()
    }
}

public struct ReadOnlyDiskObserver: Sendable {
    private let eventProvider: DiskEventStreamProvider
    private let mountTableProvider: MountTableSnapshotProvider
    private let mediaEnumerationProvider: IOMediaEnumerationSnapshotProvider
    private let settleInterval: Duration
    private let enumerationTimeout: Duration

    public init(
        eventProvider: DiskEventStreamProvider = .live,
        mountTableProvider: MountTableSnapshotProvider = .live,
        mediaEnumerationProvider: IOMediaEnumerationSnapshotProvider = .live,
        settleInterval: Duration = .milliseconds(200),
        enumerationTimeout: Duration = .seconds(1)
    ) {
        self.eventProvider = eventProvider
        self.mountTableProvider = mountTableProvider
        self.mediaEnumerationProvider = mediaEnumerationProvider
        self.settleInterval = settleInterval
        self.enumerationTimeout = enumerationTimeout
    }

    public func observations() throws -> AsyncStream<DiskInventoryObservation> {
        let capture = try capture()
        return AsyncStream { continuation in
            let forwardingTask = Task {
                for await event in capture.events {
                    guard !Task.isCancelled else {
                        break
                    }
                    guard case let .observation(observation) = event else {
                        continue
                    }
                    if case .terminated = continuation.yield(observation) {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                forwardingTask.cancel()
                capture.stopImmediately()
            }
        }
    }

    public func capture() throws -> ReadOnlyDiskObservationCapture {
        let eventSession = try eventProvider.session()
        let pair = AsyncStream<ReadOnlyDiskObservationCaptureEvent>.makeStream()
        let controller = ReadOnlyObservationController(
            inventory: ReadOnlyDiskInventory(
                mountTableProvider: mountTableProvider
            ),
            continuation: pair.continuation,
            eventSession: eventSession,
            mediaEnumerationProvider: mediaEnumerationProvider,
            settleInterval: settleInterval,
            enumerationTimeout: enumerationTimeout
        )
        pair.continuation.onTermination = { @Sendable _ in
            controller.stop()
        }
        controller.start()
        return ReadOnlyDiskObservationCapture(
            events: pair.stream,
            stopAndDrain: {
                await controller.stopAndDrain()
            },
            stopImmediately: {
                controller.stop()
            }
        )
    }
}

private final class ReadOnlyObservationController: @unchecked Sendable {
    private enum Input: Sendable {
        case event(DiskArbitrationEvent)
        case sourceFinished(wasRequestedDrain: Bool)
        case settle(UUID)
        case enumeration(
            UUID,
            Result<IOMediaEnumerationSnapshot, IOMediaEnumerationReadError>
        )
    }

    private final class ProcessingState {
        var revision: UUID
        var sourceFinished = false
        var sourceEndedByRequestedDrain = false
        var isSettled = false
        var isEnumerationPending = false

        init(revision: UUID) {
            self.revision = revision
        }
    }

    private let inventory: ReadOnlyDiskInventory
    private let eventSession: DiskEventStreamSession
    private let mediaEnumerationProvider: IOMediaEnumerationSnapshotProvider
    private let settleInterval: Duration
    private let enumerationTimeout: Duration
    private let inputs: AsyncStream<Input>
    private let inputContinuation: AsyncStream<Input>.Continuation
    private let lock = NSLock()
    private var continuation:
        AsyncStream<ReadOnlyDiskObservationCaptureEvent>.Continuation?
    private var eventTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var settleRevision: UUID?
    private var enumerationTask: Task<Void, Never>?
    private var enumerationTimeoutTask: Task<Void, Never>?
    private var started = false
    private var stopped = false

    init(
        inventory: ReadOnlyDiskInventory,
        continuation: AsyncStream<ReadOnlyDiskObservationCaptureEvent>.Continuation,
        eventSession: DiskEventStreamSession,
        mediaEnumerationProvider: IOMediaEnumerationSnapshotProvider,
        settleInterval: Duration,
        enumerationTimeout: Duration
    ) {
        let inputStream = AsyncStream<Input>.makeStream()
        self.inventory = inventory
        self.continuation = continuation
        self.eventSession = eventSession
        self.mediaEnumerationProvider = mediaEnumerationProvider
        self.settleInterval = settleInterval
        self.enumerationTimeout = enumerationTimeout
        inputs = inputStream.stream
        inputContinuation = inputStream.continuation
    }

    func start() {
        lock.lock()
        guard !started, !stopped else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        let initialRevision = UUID()
        scheduleSettlement(for: initialRevision)

        let processingTask = Task { [weak self, inputs] in
            let state = ProcessingState(revision: initialRevision)
            for await input in inputs {
                let shouldContinue: Bool
                do {
                    guard let controller = self else {
                        return
                    }
                    shouldContinue = await controller.process(input, state: state)
                }
                guard shouldContinue else {
                    return
                }
            }
        }
        let eventSession = eventSession
        let eventTask = Task { [weak self] in
            var sawDrainBoundary = false
            var sourceProtocolValid = true
            for await item in eventSession.items {
                guard !Task.isCancelled else {
                    break
                }
                switch item {
                case let .event(event):
                    guard !sawDrainBoundary else {
                        sourceProtocolValid = false
                        continue
                    }
                    guard self?.submit(.event(event)) == true else {
                        return
                    }
                case .drainBoundary:
                    if sawDrainBoundary {
                        sourceProtocolValid = false
                    }
                    sawDrainBoundary = true
                }
            }
            guard !Task.isCancelled else {
                return
            }
            _ = self?.submit(
                .sourceFinished(
                    wasRequestedDrain: sawDrainBoundary && sourceProtocolValid
                )
            )
        }

        lock.lock()
        guard !stopped else {
            lock.unlock()
            processingTask.cancel()
            eventTask.cancel()
            return
        }
        self.processingTask = processingTask
        self.eventTask = eventTask
        lock.unlock()
    }

    func stop() {
        finish(output: false)
    }

    func stopAndDrain() async -> Bool {
        await eventSession.stopAndDrain()
    }

    private func finish(
        output shouldFinishOutput: Bool,
        terminal: ReadOnlyDiskObservationCaptureTerminal? = nil
    ) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let eventTask = eventTask
        let processingTask = processingTask
        let settleTask = settleTask
        let enumerationTask = enumerationTask
        let enumerationTimeoutTask = enumerationTimeoutTask
        let activeContinuation = shouldFinishOutput ? continuation : nil
        self.eventTask = nil
        self.processingTask = nil
        self.settleTask = nil
        self.enumerationTask = nil
        self.enumerationTimeoutTask = nil
        settleRevision = nil
        continuation = nil
        lock.unlock()

        inputContinuation.finish()
        if shouldFinishOutput, let terminal {
            _ = activeContinuation?.yield(.terminal(terminal))
        }
        eventTask?.cancel()
        processingTask?.cancel()
        settleTask?.cancel()
        enumerationTask?.cancel()
        enumerationTimeoutTask?.cancel()
        activeContinuation?.finish()
        eventSession.stopImmediately()
    }

    private func process(_ input: Input, state: ProcessingState) async -> Bool {
        guard isActive else {
            return false
        }

        switch input {
        case let .event(event):
            state.revision = UUID()
            state.isSettled = false
            state.isEnumerationPending = false
            cancelSettlement()
            cancelEnumeration()

            await inventory.markEnumerationPending()
            await inventory.handle(event)
            let pendingObservation = await inventory.currentInventory()
            guard publish(pendingObservation) else {
                return false
            }
            scheduleSettlement(for: state.revision)

        case let .sourceFinished(wasRequestedDrain):
            guard !state.sourceFinished else {
                return true
            }
            state.sourceFinished = true
            state.sourceEndedByRequestedDrain = wasRequestedDrain
            state.revision = UUID()
            state.isSettled = false
            state.isEnumerationPending = false
            cancelSettlement()
            cancelEnumeration()
            await inventory.markEnumerationPending()
            let pendingObservation = await inventory.currentInventory()
            guard publish(pendingObservation) else {
                return false
            }
            scheduleSettlement(for: state.revision)

        case let .settle(expectedRevision):
            guard expectedRevision == state.revision else {
                return true
            }
            clearSettlement(for: expectedRevision)
            await inventory.markEnumerationSettledWithoutCoverage()
            let settledObservation = await inventory.currentInventory()
            guard publish(settledObservation) else {
                return false
            }
            state.isSettled = true
            state.isEnumerationPending = true
            scheduleEnumeration(for: expectedRevision)

        case let .enumeration(expectedRevision, result):
            guard expectedRevision == state.revision,
                  state.isSettled,
                  state.isEnumerationPending
            else {
                return true
            }
            state.isEnumerationPending = false
            clearEnumerationTasks()
            if case let .success(snapshot) = result {
                _ = await inventory.verifyEnumerationCoverage(using: snapshot)
            }
            let verifiedObservation = await inventory.currentInventory()
            guard publish(verifiedObservation) else {
                return false
            }
            if state.sourceFinished {
                let terminal: ReadOnlyDiskObservationCaptureTerminal =
                    state.sourceEndedByRequestedDrain
                        ? .drained(
                            finalObservationVerified:
                                verifiedObservation.issues.isEmpty
                        )
                        : .sourceEndedUnexpectedly
                finish(output: true, terminal: terminal)
                return false
            }
        }

        return true
    }

    private func scheduleSettlement(for expectedRevision: UUID) {
        let task = Task { [weak self] in
            do {
                guard let settleInterval = self?.settleInterval else {
                    return
                }
                try await Task.sleep(for: settleInterval)
            } catch {
                return
            }
            _ = self?.submit(.settle(expectedRevision))
        }

        lock.lock()
        if stopped {
            lock.unlock()
            task.cancel()
            return
        }
        let oldSettleTask = settleTask
        settleTask = task
        settleRevision = expectedRevision
        lock.unlock()
        oldSettleTask?.cancel()
    }

    private func cancelSettlement() {
        lock.lock()
        let task = settleTask
        settleTask = nil
        settleRevision = nil
        lock.unlock()
        task?.cancel()
    }

    private func clearSettlement(for expectedRevision: UUID) {
        lock.lock()
        if settleRevision == expectedRevision {
            settleTask = nil
            settleRevision = nil
        }
        lock.unlock()
    }

    private func scheduleEnumeration(for expectedRevision: UUID) {
        cancelEnumeration()

        let provider = mediaEnumerationProvider
        let enumerationTask = Task.detached(priority: .utility) { [weak self] in
            let result: Result<IOMediaEnumerationSnapshot, IOMediaEnumerationReadError>
            do {
                result = .success(try provider.currentSnapshot())
            } catch let error as IOMediaEnumerationReadError {
                result = .failure(error)
            } catch {
                result = .failure(.unexpectedFailure)
            }
            guard !Task.isCancelled else {
                return
            }
            _ = self?.submit(.enumeration(expectedRevision, result))
        }
        let timeout = enumerationTimeout
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            _ = self?.submit(
                .enumeration(expectedRevision, .failure(.timedOut))
            )
        }

        lock.lock()
        if stopped {
            lock.unlock()
            enumerationTask.cancel()
            timeoutTask.cancel()
            return
        }
        self.enumerationTask = enumerationTask
        enumerationTimeoutTask = timeoutTask
        lock.unlock()
    }

    private func cancelEnumeration() {
        lock.lock()
        let enumerationTask = enumerationTask
        let timeoutTask = enumerationTimeoutTask
        self.enumerationTask = nil
        enumerationTimeoutTask = nil
        lock.unlock()
        enumerationTask?.cancel()
        timeoutTask?.cancel()
    }

    private func clearEnumerationTasks() {
        cancelEnumeration()
    }

    private var isActive: Bool {
        lock.lock()
        let result = !stopped
        lock.unlock()
        return result
    }

    private func submit(_ input: Input) -> Bool {
        lock.lock()
        let isActive = !stopped
        lock.unlock()
        guard isActive else {
            return false
        }
        if case .terminated = inputContinuation.yield(input) {
            stop()
            return false
        }
        return true
    }

    private func publish(_ observation: DiskInventoryObservation) -> Bool {
        lock.lock()
        let activeContinuation = stopped ? nil : continuation
        lock.unlock()
        guard let activeContinuation else {
            return false
        }
        if case .terminated = activeContinuation.yield(.observation(observation)) {
            stop()
            return false
        }
        return true
    }
}
