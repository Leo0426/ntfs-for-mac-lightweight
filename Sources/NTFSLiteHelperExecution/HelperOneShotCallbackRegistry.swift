import Foundation

/// The DA callback receives only a monotonically allocated integer token.
/// Timeout resumes the caller once but retains the callback's resource until
/// the late callback arrives or the helper process exits.
public final class HelperOneShotCallbackRegistry: @unchecked Sendable {
    private final class Pending {
        var continuation: CheckedContinuation<Bool, Never>?
        let retainedResource: AnyObject?

        init(_ continuation: CheckedContinuation<Bool, Never>, retainedResource: AnyObject?) {
            self.continuation = continuation
            self.retainedResource = retainedResource
        }
    }

    private let lock = NSLock()
    private var nextToken: UInt = 1
    private var pending: [UInt: Pending] = [:]

    public init() {}

    public var pendingCount: Int { lock.withLock { pending.count } }

    public func register(
        _ continuation: CheckedContinuation<Bool, Never>, retainedResource: AnyObject?
    ) -> UInt? {
        lock.withLock {
            guard nextToken < UInt.max else { return nil }
            let token = nextToken
            nextToken += 1
            pending[token] = Pending(continuation, retainedResource: retainedResource)
            return token
        }
    }

    /// True only when this callback wins the race to resume the continuation.
    @discardableResult
    public func complete(_ token: UInt, result: Bool) -> Bool {
        let continuation = lock.withLock { pending.removeValue(forKey: token)?.continuation }
        continuation?.resume(returning: result)
        return continuation != nil
    }

    /// The pending entry remains registered so a late C callback never reads
    /// freed context. The disk is kept alive until that callback or process exit.
    @discardableResult
    public func timeout(_ token: UInt) -> Bool {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard let entry = pending[token] else { return nil }
            let saved = entry.continuation
            entry.continuation = nil
            return saved
        }
        continuation?.resume(returning: false)
        return continuation != nil
    }
}
