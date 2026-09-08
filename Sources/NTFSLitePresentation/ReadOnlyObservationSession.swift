import Foundation
import NTFSLiteSystem

public struct ReadOnlyObservationRefreshToken: Equatable, Hashable, Sendable {
    fileprivate let rawValue: UUID
}

/// Presentation identity for one observation subscription. The underlying
/// value is intentionally opaque and must not be displayed or persisted.
public struct ReadOnlySelectionResetEpoch: Equatable, Hashable, Sendable {
    fileprivate let rawValue: UUID
}

/// A small, synchronous state machine that prevents observations from an old
/// refresh task from replacing facts produced by the current subscription.
public struct ReadOnlyObservationSession: Equatable, Sendable {
    public private(set) var observation: DiskInventoryObservation
    public private(set) var selectionResetEpoch: ReadOnlySelectionResetEpoch
    private var activeToken: ReadOnlyObservationRefreshToken?

    public init() {
        observation = Self.pendingObservation
        selectionResetEpoch = ReadOnlySelectionResetEpoch(rawValue: UUID())
    }

    @discardableResult
    public mutating func beginRefresh() -> ReadOnlyObservationRefreshToken {
        let rawValue = UUID()
        let token = ReadOnlyObservationRefreshToken(rawValue: rawValue)
        activeToken = token
        selectionResetEpoch = ReadOnlySelectionResetEpoch(rawValue: rawValue)
        observation = Self.pendingObservation
        return token
    }

    public func isCurrent(_ token: ReadOnlyObservationRefreshToken) -> Bool {
        activeToken == token
    }

    @discardableResult
    public mutating func accept(
        _ newObservation: DiskInventoryObservation,
        for token: ReadOnlyObservationRefreshToken
    ) -> Bool {
        guard isCurrent(token) else {
            return false
        }
        observation = newObservation
        return true
    }

    @discardableResult
    public mutating func sourceBecameUnavailable(
        for token: ReadOnlyObservationRefreshToken
    ) -> Bool {
        guard isCurrent(token) else {
            return false
        }
        observation = DiskInventoryObservation(
            physicalDisks: [],
            issues: [.eventSourceUnavailable]
        )
        return true
    }

    private static var pendingObservation: DiskInventoryObservation {
        DiskInventoryObservation(
            physicalDisks: [],
            issues: [.initialEnumerationPending]
        )
    }
}
