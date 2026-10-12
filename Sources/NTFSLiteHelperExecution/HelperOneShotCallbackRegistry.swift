import Foundation

/// The DA callback receives only a monotonically allocated integer token.
/// Timeout resumes the caller once but retains the callback's resource until
/// the late callback arrives or the helper process exits.
public final class HelperCallbackRegistry<Result: Sendable>: @unchecked Sendable {
    private final class Pending {
        var continuation: CheckedContinuation<Result, Never>?
        let retainedResource: AnyObject?

        init(_ continuation: CheckedContinuation<Result, Never>, retainedResource: AnyObject?) {
            self.continuation = continuation
            self.retainedResource = retainedResource
        }
    }

    private let lock = NSLock()
    private var nextToken: UInt = 1
    private var pending: [UInt: Pending] = [:]

    private let timeoutResult: Result

    public init(timeoutResult: Result) { self.timeoutResult = timeoutResult }

    public var pendingCount: Int { lock.withLock { pending.count } }

    public func register(
        _ continuation: CheckedContinuation<Result, Never>, retainedResource: AnyObject?
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
    public func complete(_ token: UInt, result: Result) -> Bool {
        let continuation = lock.withLock { pending.removeValue(forKey: token)?.continuation }
        continuation?.resume(returning: result)
        return continuation != nil
    }

    /// The pending entry remains registered so a late C callback never reads
    /// freed context. The disk is kept alive until that callback or process exit.
    @discardableResult
    public func timeout(_ token: UInt) -> Bool {
        let continuation = lock.withLock { () -> CheckedContinuation<Result, Never>? in
            guard let entry = pending[token] else { return nil }
            let saved = entry.continuation
            entry.continuation = nil
            return saved
        }
        continuation?.resume(returning: timeoutResult)
        return continuation != nil
    }
}

public typealias HelperOneShotCallbackRegistry = HelperCallbackRegistry<Bool>

public extension HelperCallbackRegistry where Result == Bool {
    convenience init() { self.init(timeoutResult: false) }
}
