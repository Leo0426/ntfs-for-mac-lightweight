import Foundation

/// Keeps request admission and idle-exit decisions under one lock.
final class HelperIdleExitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var lastActivity: Date
    private var exiting = false

    init(lastActivity: Date = Date()) {
        self.lastActivity = lastActivity
    }

    func begin(now: Date = Date()) -> Bool {
        lock.withLock {
            guard !exiting else { return false }
            inFlight += 1
            lastActivity = now
            return true
        }
    }

    func end(now: Date = Date()) {
        lock.withLock {
            inFlight -= 1
            lastActivity = now
        }
    }

    func isIdle(now: Date = Date(), idleSeconds: TimeInterval) -> Bool {
        lock.withLock { !exiting && inFlight == 0 && now.timeIntervalSince(lastActivity) > idleSeconds }
    }

    func beginExitIfIdle(now: Date = Date(), idleSeconds: TimeInterval) -> Bool {
        lock.withLock {
            guard !exiting && inFlight == 0 && now.timeIntervalSince(lastActivity) > idleSeconds else {
                return false
            }
            // Admission closes before the caller leaves this lock to exit.
            exiting = true
            return true
        }
    }
}
