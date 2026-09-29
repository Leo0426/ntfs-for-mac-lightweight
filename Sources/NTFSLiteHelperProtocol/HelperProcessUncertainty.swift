import Foundation

/// A child whose termination cannot be confirmed may still perform its fixed operation.
/// Keep the daemon closed to further requests for the remainder of this process lifetime.
public final class HelperProcessUncertainty: @unchecked Sendable {
    public static let processLifetime = HelperProcessUncertainty()

    private let lock = NSLock()
    private var unknown = false

    public init() {}

    public var isUnknown: Bool { lock.withLock { unknown } }

    public func markUnknown() {
        lock.withLock { unknown = true }
    }
}
