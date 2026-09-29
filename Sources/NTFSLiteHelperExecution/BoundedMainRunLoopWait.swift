import Foundation

/// A bounded callback wait for child-process APIs that may dispatch their
/// completion onto the caller's main run loop. A missing callback stays nil.
public enum BoundedMainRunLoopWait {
    public static func wait(
        timeout: TimeInterval,
        start: (@escaping @Sendable (Bool) -> Void) -> Void
    ) -> Bool? {
        guard timeout > 0, timeout <= 5 else { return nil }
        let result = CallbackResult()
        start { result.store($0) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while result.value == nil {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(min(0.05, remaining)))
        }
        return result.value
    }
}

private final class CallbackResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    var value: Bool? { lock.withLock { stored } }
    func store(_ value: Bool) { lock.withLock { stored = value } }
}
