import Foundation

public enum DiagnosticRetentionPolicyError: Error, Equatable, Sendable {
    case maxEntriesMustBePositive
    case maxEncodedBytesMustBePositive
    case maxEncodedBytesBelowMinimum(minimum: Int)
    case maxAgeMustBePositive
}

public struct DiagnosticRetentionPolicy: Equatable, Sendable {
    public let maxEntries: Int
    public let maxEncodedBytes: Int
    public let maxAge: TimeInterval

    fileprivate let maxAgeMilliseconds: Int64

    public static let minimumEncodedSnapshotBytes: Int = {
        let snapshot = DiagnosticSnapshot(
            runID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            generatedAt: DiagnosticTimestamp(millisecondsSince1970: Int64.min),
            entries: []
        )
        return (try? snapshot.encodedJSON().count) ?? 256
    }()

    public init(
        maxEntries: Int,
        maxEncodedBytes: Int = 256 * 1_024,
        maxAge: TimeInterval = 7 * 24 * 60 * 60
    ) throws {
        guard maxEntries > 0 else {
            throw DiagnosticRetentionPolicyError.maxEntriesMustBePositive
        }
        guard maxEncodedBytes > 0 else {
            throw DiagnosticRetentionPolicyError.maxEncodedBytesMustBePositive
        }
        guard maxEncodedBytes >= Self.minimumEncodedSnapshotBytes else {
            throw DiagnosticRetentionPolicyError.maxEncodedBytesBelowMinimum(
                minimum: Self.minimumEncodedSnapshotBytes
            )
        }
        guard maxAge.isFinite, maxAge > 0 else {
            throw DiagnosticRetentionPolicyError.maxAgeMustBePositive
        }

        self.maxEntries = maxEntries
        self.maxEncodedBytes = maxEncodedBytes
        self.maxAge = maxAge
        self.maxAgeMilliseconds = Self.milliseconds(for: maxAge)
    }

    public static let `default` = DiagnosticRetentionPolicy(
        validatedMaxEntries: 500,
        validatedMaxEncodedBytes: 256 * 1_024,
        validatedMaxAge: 7 * 24 * 60 * 60
    )

    private init(
        validatedMaxEntries: Int,
        validatedMaxEncodedBytes: Int,
        validatedMaxAge: TimeInterval
    ) {
        self.maxEntries = validatedMaxEntries
        self.maxEncodedBytes = validatedMaxEncodedBytes
        self.maxAge = validatedMaxAge
        self.maxAgeMilliseconds = Self.milliseconds(for: validatedMaxAge)
    }

    private static func milliseconds(for seconds: TimeInterval) -> Int64 {
        let milliseconds = seconds * 1_000
        guard milliseconds.isFinite, milliseconds < Double(Int64.max) else {
            return Int64.max
        }
        return max(1, Int64(milliseconds.rounded(.up)))
    }
}

public enum DiagnosticsError: Error, Equatable, Sendable {
    case staleTarget
    case unregisteredTarget
    case expectedDiskTarget
    case expectedVolumeTarget
    case aliasSpaceExhausted
    case sequenceSpaceExhausted
}

public actor Diagnostics {
    private let policy: DiagnosticRetentionPolicy
    private let clock: @Sendable () -> Date
    private let runIDGenerator: @Sendable () -> UUID

    private var runID: UUID
    private var entries: [DiagnosticEntry] = []
    private var issuedTargets: Set<DiagnosticTarget> = []
    private var nextSequence: UInt64 = 1
    private var nextDiskOrdinal: UInt64 = 1
    private var nextVolumeOrdinal: UInt64 = 1
    private var latestObservedTime: DiagnosticTimestamp?

    public init(
        policy: DiagnosticRetentionPolicy = .default,
        clock: @escaping @Sendable () -> Date = { Date() },
        runIDGenerator: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.policy = policy
        self.clock = clock
        self.runIDGenerator = runIDGenerator
        self.runID = runIDGenerator()
    }

    public func registerDisk(mediaGeneration: UInt64) throws -> DiagnosticTarget {
        guard nextDiskOrdinal <= UInt64(UInt32.max) else {
            throw DiagnosticsError.aliasSpaceExhausted
        }
        let target = DiagnosticTarget(
            runID: runID,
            kind: .disk,
            diskOrdinal: UInt32(nextDiskOrdinal),
            volumeOrdinal: nil,
            mediaGeneration: mediaGeneration
        )
        issuedTargets.insert(target)
        nextDiskOrdinal += 1
        return target
    }

    public func registerVolume(on disk: DiagnosticTarget) throws -> DiagnosticTarget {
        try validateIssued(disk)
        guard disk.kind == .disk, disk.volumeOrdinal == nil else {
            throw DiagnosticsError.expectedDiskTarget
        }
        guard nextVolumeOrdinal <= UInt64(UInt32.max) else {
            throw DiagnosticsError.aliasSpaceExhausted
        }
        let target = DiagnosticTarget(
            runID: runID,
            kind: .volume,
            diskOrdinal: disk.diskOrdinal,
            volumeOrdinal: UInt32(nextVolumeOrdinal),
            mediaGeneration: disk.mediaGeneration
        )
        issuedTargets.insert(target)
        nextVolumeOrdinal += 1
        return target
    }

    public func record(_ input: DiagnosticInput) throws {
        let now = effectiveNow()
        removeExpiredEntries(relativeTo: now)

        if let target = input.target {
            try validateIssued(target)
            if input.requiresVolumeTarget,
               (target.kind != .volume || target.volumeOrdinal == nil)
            {
                throw DiagnosticsError.expectedVolumeTarget
            }
        }

        guard nextSequence < UInt64.max else {
            throw DiagnosticsError.sequenceSpaceExhausted
        }
        entries.append(
            DiagnosticEntry(
                sequence: nextSequence,
                occurredAt: now,
                event: input
            )
        )
        nextSequence += 1
        enforceRetentionLimits(generatedAt: now)
    }

    public func snapshot() -> DiagnosticSnapshot {
        let now = effectiveNow()
        removeExpiredEntries(relativeTo: now)
        enforceRetentionLimits(generatedAt: now)
        return makeSnapshot(generatedAt: now)
    }

    public func clear() {
        let previousRunID = runID
        let generatedRunID = runIDGenerator()
        runID = generatedRunID == previousRunID ? UUID() : generatedRunID
        entries.removeAll(keepingCapacity: false)
        issuedTargets.removeAll(keepingCapacity: false)
        nextSequence = 1
        nextDiskOrdinal = 1
        nextVolumeOrdinal = 1
    }

    private func validateCurrent(_ target: DiagnosticTarget) throws {
        guard target.runID == runID else {
            throw DiagnosticsError.staleTarget
        }
    }

    private func validateIssued(_ target: DiagnosticTarget) throws {
        try validateCurrent(target)
        guard issuedTargets.contains(target) else {
            throw DiagnosticsError.unregisteredTarget
        }
    }

    private func trimToEntryLimit() {
        let overflow = entries.count - policy.maxEntries
        if overflow > 0 {
            entries.removeFirst(overflow)
        }
    }

    private func effectiveNow() -> DiagnosticTimestamp {
        let observed = DiagnosticTimestamp(date: clock())
        if let latestObservedTime, observed < latestObservedTime {
            return latestObservedTime
        }
        latestObservedTime = observed
        return observed
    }

    private func removeExpiredEntries(relativeTo now: DiagnosticTimestamp) {
        let (cutoff, underflow) = now.millisecondsSince1970.subtractingReportingOverflow(
            policy.maxAgeMilliseconds
        )
        guard !underflow else {
            return
        }
        entries.removeAll { entry in
            entry.occurredAt.millisecondsSince1970 <= cutoff
        }
    }

    private func enforceRetentionLimits(generatedAt: DiagnosticTimestamp) {
        trimToEntryLimit()

        while !entries.isEmpty {
            guard let encodedByteCount = encodedByteCount(generatedAt: generatedAt) else {
                entries.removeAll(keepingCapacity: false)
                return
            }
            guard encodedByteCount > policy.maxEncodedBytes else {
                return
            }
            entries.removeFirst()
        }
    }

    private func encodedByteCount(generatedAt: DiagnosticTimestamp) -> Int? {
        do {
            return try makeSnapshot(generatedAt: generatedAt).encodedJSON().count
        } catch {
            // Every retained value is a closed Codable type. If that invariant is
            // ever broken, fail closed and force eviction instead of retaining an
            // archive whose bounded encoded representation cannot be proven.
            return nil
        }
    }

    private func makeSnapshot(generatedAt: DiagnosticTimestamp) -> DiagnosticSnapshot {
        DiagnosticSnapshot(
            runID: runID,
            generatedAt: generatedAt,
            entries: entries
        )
    }
}
