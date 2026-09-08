import CryptoKit
import Foundation
import NTFSLiteCore
import NTFSLiteStrictJSON
import NTFSLiteSystem

public struct GateEvidenceVersion: Codable, Equatable, Sendable {
    public let major: UInt32
    public let minor: UInt32
    public let patch: UInt32

    public init(major: UInt32, minor: UInt32, patch: UInt32) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
}

public struct GateEvidenceTimestamp: Codable, Equatable, Comparable, Sendable {
    public let millisecondsSince1970: Int64

    public init(millisecondsSince1970: Int64) {
        self.millisecondsSince1970 = millisecondsSince1970
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.millisecondsSince1970 < rhs.millisecondsSince1970
    }
}

public struct GateEvidenceClock: Sendable {
    private let read: @Sendable () -> GateEvidenceTimestamp

    public init(_ read: @escaping @Sendable () -> GateEvidenceTimestamp) {
        self.read = read
    }

    public func now() -> GateEvidenceTimestamp {
        read()
    }

    public static let live = GateEvidenceClock {
        let milliseconds = Date().timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds <= Double(Int64.max)
        else {
            return GateEvidenceTimestamp(millisecondsSince1970: -1)
        }
        return GateEvidenceTimestamp(millisecondsSince1970: Int64(milliseconds))
    }
}

public enum Gate1EvidenceHeaderError: Error, Equatable, Sendable {
    case invalidEvidenceID
    case invalidApplicationBuild
    case invalidApplicationSHA256
}

public struct Gate1EvidenceHeader: Codable, Equatable, Sendable {
    public let evidenceID: String
    public let applicationVersion: GateEvidenceVersion
    public let applicationBuild: UInt32
    public let applicationSHA256: String
    public let macOSVersion: GateEvidenceVersion

    public init(
        evidenceID: String,
        applicationVersion: GateEvidenceVersion,
        applicationBuild: UInt32,
        applicationSHA256: String,
        macOSVersion: GateEvidenceVersion
    ) throws {
        guard Self.isEvidenceID(evidenceID) else {
            throw Gate1EvidenceHeaderError.invalidEvidenceID
        }
        guard applicationBuild > 0 else {
            throw Gate1EvidenceHeaderError.invalidApplicationBuild
        }
        guard Self.isSHA256(applicationSHA256) else {
            throw Gate1EvidenceHeaderError.invalidApplicationSHA256
        }
        self.evidenceID = evidenceID
        self.applicationVersion = applicationVersion
        self.applicationBuild = applicationBuild
        self.applicationSHA256 = applicationSHA256
        self.macOSVersion = macOSVersion
    }

    private static func isEvidenceID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 35,
              bytes[0 ... 2] == Array("G1-".utf8)[0 ... 2]
        else {
            return false
        }
        return bytes.dropFirst(3).allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 70).contains(byte)
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }
}

public enum Gate1EvidenceVerdict: String, Codable, Equatable, Sendable {
    case failedClosed
    case incomplete
    case readyForHumanReview
}

public enum Gate1EvidenceFailureCode: String, Codable, Equatable, Hashable, CaseIterable, Sendable {
    case checkpointContradicted
    case checkpointLimitExceeded
    case diskLimitExceeded
    case encodedByteLimitExceeded
    case eventQueueOverflow
    case finalObservationUnverified
    case invalidCheckpoint
    case invalidTimestamp
    case mediaGenerationChangedBeforeAbsence
    case mediaGenerationRegressedAfterAbsence
    case mediaGenerationReusedAfterAbsence
    case mediaGenerationUnknownAfterAbsence
    case nonMonotonicTimestamp
    case observationLimitExceeded
    case observationStreamEnded
    case targetCycleEvidenceInterrupted
    case topologyContradiction
    case unclassifiedObservationFailure
    case unclassifiedOperatorFailure
    case volumeLimitExceeded
}

public enum Gate1EvidencePolicyError: Error, Equatable, Sendable {
    case invalidLimit
}

public struct Gate1EvidencePolicy: Equatable, Sendable {
    public static let minimumEncodedBytes = 4 * 1_024
    public static let maximumObservations = 4_096
    public static let maximumCheckpoints = 1_024
    public static let maximumDisksPerObservation = 64
    public static let maximumVolumesPerDisk = 256
    public static let maximumEncodedBytes = 16 * 1_024 * 1_024

    public static let `default` = try! Gate1EvidencePolicy(
        maxObservations: maximumObservations,
        maxCheckpoints: maximumCheckpoints,
        maxDisksPerObservation: maximumDisksPerObservation,
        maxVolumesPerDisk: maximumVolumesPerDisk,
        maxEncodedBytes: maximumEncodedBytes
    )

    public let maxObservations: Int
    public let maxCheckpoints: Int
    public let maxDisksPerObservation: Int
    public let maxVolumesPerDisk: Int
    public let maxEncodedBytes: Int

    public init(
        maxObservations: Int,
        maxCheckpoints: Int,
        maxDisksPerObservation: Int,
        maxVolumesPerDisk: Int,
        maxEncodedBytes: Int
    ) throws {
        guard maxObservations > 0,
              maxObservations <= Self.maximumObservations,
              maxCheckpoints > 0,
              maxCheckpoints <= Self.maximumCheckpoints,
              maxDisksPerObservation > 0,
              maxDisksPerObservation <= Self.maximumDisksPerObservation,
              maxVolumesPerDisk > 0,
              maxVolumesPerDisk <= Self.maximumVolumesPerDisk,
              maxEncodedBytes >= Self.minimumEncodedBytes,
              maxEncodedBytes <= Self.maximumEncodedBytes
        else {
            throw Gate1EvidencePolicyError.invalidLimit
        }
        self.maxObservations = maxObservations
        self.maxCheckpoints = maxCheckpoints
        self.maxDisksPerObservation = maxDisksPerObservation
        self.maxVolumesPerDisk = maxVolumesPerDisk
        self.maxEncodedBytes = maxEncodedBytes
    }
}

public enum Gate1ObservationCoverage: String, Codable, Equatable, Sendable {
    case verified
    case unverified
}

public enum Gate1MediaGenerationRelation: String, Codable, Equatable, Sendable {
    case first
    case unchanged
    case advanced
    case reusedWithoutAdvance
    case regressed
    case unknown
}

public enum Gate1EvidenceIssueCode: String, Codable, Equatable, Hashable, Sendable {
    case childLocationMismatch
    case conflictingVolumeRole
    case contradictoryEjectability
    case duplicateMountTableEntry
    case enumerationCoverageUnverified
    case eventSourceUnavailable
    case incompleteMountTableEntry
    case initialEnumerationPending
    case invalidBSDName
    case invalidMediaGeneration
    case invalidPhysicalDiskBSDName
    case invalidVolumeUUID
    case missingBSDName
    case missingDisplayName
    case missingEjectability
    case missingFileSystemName
    case missingLocation
    case missingMountTableEntry
    case missingPhysicalDiskBSDName
    case missingPhysicalDiskDescription
    case missingPhysicalLocation
    case missingRemovability
    case missingVolumeUUID
    case mountAccessMismatch
    case mountPointMismatch
    case mountTableReadFailed
    case nonCanonicalMountPoint
    case physicalParentMismatch
    case sourceDeviceMismatch
    case symbolicLinkMountPoint
    case unidentifiedDiskEvent
    case unexpectedMountTableEntry
    case unknownDiskKind
    case unknownVolumeRole
}

public struct Gate1EvidenceDiskFrame: Codable, Equatable, Sendable {
    public let diskOrdinal: UInt32
    public let connectionOrdinal: UInt32
    public let mediaGenerationRelation: Gate1MediaGenerationRelation
    public let volumeOrdinals: [UInt32]
    public let candidateVolumeOrdinals: [UInt32]
    public let mutationSnapshotVolumeOrdinals: [UInt32]
    public let unverifiedVolumeOrdinals: [UInt32]
    public let issueCodes: [Gate1EvidenceIssueCode]

    public var volumeCount: UInt32 {
        UInt32(volumeOrdinals.count)
    }

    public var candidateCount: UInt32 {
        UInt32(candidateVolumeOrdinals.count)
    }

    public var mutationSnapshotCount: UInt32 {
        UInt32(mutationSnapshotVolumeOrdinals.count)
    }

    fileprivate init(
        diskOrdinal: UInt32,
        connectionOrdinal: UInt32,
        mediaGenerationRelation: Gate1MediaGenerationRelation,
        volumeOrdinals: [UInt32],
        candidateVolumeOrdinals: [UInt32],
        mutationSnapshotVolumeOrdinals: [UInt32],
        unverifiedVolumeOrdinals: [UInt32],
        issueCodes: [Gate1EvidenceIssueCode]
    ) {
        self.diskOrdinal = diskOrdinal
        self.connectionOrdinal = connectionOrdinal
        self.mediaGenerationRelation = mediaGenerationRelation
        self.volumeOrdinals = volumeOrdinals
        self.candidateVolumeOrdinals = candidateVolumeOrdinals
        self.mutationSnapshotVolumeOrdinals = mutationSnapshotVolumeOrdinals
        self.unverifiedVolumeOrdinals = unverifiedVolumeOrdinals
        self.issueCodes = issueCodes
    }
}

public struct Gate1EvidenceObservationFrame: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let occurredAt: GateEvidenceTimestamp
    public let coverage: Gate1ObservationCoverage
    public let coordinatorInventoryPresent: Bool
    public let disks: [Gate1EvidenceDiskFrame]
    public let confirmedAbsentDiskOrdinals: [UInt32]
    public let issueCodes: [Gate1EvidenceIssueCode]

    fileprivate init(
        sequence: UInt64,
        occurredAt: GateEvidenceTimestamp,
        coverage: Gate1ObservationCoverage,
        coordinatorInventoryPresent: Bool,
        disks: [Gate1EvidenceDiskFrame],
        confirmedAbsentDiskOrdinals: [UInt32],
        issueCodes: [Gate1EvidenceIssueCode]
    ) {
        self.sequence = sequence
        self.occurredAt = occurredAt
        self.coverage = coverage
        self.coordinatorInventoryPresent = coordinatorInventoryPresent
        self.disks = disks
        self.confirmedAbsentDiskOrdinals = confirmedAbsentDiskOrdinals
        self.issueCodes = issueCodes
    }
}

public enum Gate1CheckpointKind: String, Codable, Equatable, Hashable, CaseIterable, Sendable {
    case multiPartitionTopology
    case sleep
    case wakeResubscription
    case applicationRestart
    case systemInventoryComparison
    case mountTableComparison
    case declarationInvalidatedAfterReinsert
    case declarationInvalidatedAfterWake
    case declarationInvalidatedAfterRestart
    case declarationInvalidatedAfterTopologyChange
    case declarationInvalidatedAfterConsumption
    case strictReleaseChecks
    case readOnlyBoundaryReview
}

public enum Gate1CheckpointFinding: String, Codable, Equatable, Sendable {
    case confirmed
    case contradicted
    case notPerformed
}

public struct Gate1OperatorCheckpoint: Equatable, Sendable {
    public let kind: Gate1CheckpointKind
    public let roundOrdinal: UInt16?
    public let finding: Gate1CheckpointFinding

    public init(
        kind: Gate1CheckpointKind,
        roundOrdinal: UInt16?,
        finding: Gate1CheckpointFinding
    ) {
        self.kind = kind
        self.roundOrdinal = roundOrdinal
        self.finding = finding
    }
}

public enum Gate1EvidenceOperatorCommand: Equatable, Sendable {
    case status
    case seal
    case checkpoint(Gate1OperatorCheckpoint)
}

public enum Gate1EvidenceOperatorCommandError: Error, Equatable, Sendable {
    case invalidCommand
}

public enum Gate1EvidenceOperatorCommandParser {
    public static func parse(
        _ input: String
    ) -> Result<Gate1EvidenceOperatorCommand, Gate1EvidenceOperatorCommandError> {
        guard input.utf8.count <= 256 else {
            return .failure(.invalidCommand)
        }
        let tokens = input.split(whereSeparator: \Character.isWhitespace).map(String.init)
        if tokens == ["status"] {
            return .success(.status)
        }
        if tokens == ["seal"] {
            return .success(.seal)
        }
        guard tokens.first == "checkpoint",
              tokens.count == 3 || tokens.count == 4,
              let kind = Gate1CheckpointKind(rawValue: tokens[1])
        else {
            return .failure(.invalidCommand)
        }
        let requiresRound = kind == .systemInventoryComparison
            || kind == .mountTableComparison
        let roundOrdinal: UInt16?
        let findingToken: String
        if requiresRound {
            guard tokens.count == 4,
                  let round = UInt16(tokens[2]),
                  (1 ... Gate1EvidenceRules.requiredCycleCount).contains(round)
            else {
                return .failure(.invalidCommand)
            }
            roundOrdinal = round
            findingToken = tokens[3]
        } else {
            guard tokens.count == 3 else {
                return .failure(.invalidCommand)
            }
            roundOrdinal = nil
            findingToken = tokens[2]
        }
        guard let finding = Gate1CheckpointFinding(rawValue: findingToken) else {
            return .failure(.invalidCommand)
        }
        return .success(
            .checkpoint(
                Gate1OperatorCheckpoint(
                    kind: kind,
                    roundOrdinal: roundOrdinal,
                    finding: finding
                )
            )
        )
    }
}

public struct Gate1EvidenceCheckpoint: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let occurredAt: GateEvidenceTimestamp
    public let kind: Gate1CheckpointKind
    public let roundOrdinal: UInt16?
    public let finding: Gate1CheckpointFinding

    public init(
        sequence: UInt64,
        occurredAt: GateEvidenceTimestamp,
        kind: Gate1CheckpointKind,
        roundOrdinal: UInt16?,
        finding: Gate1CheckpointFinding
    ) {
        self.sequence = sequence
        self.occurredAt = occurredAt
        self.kind = kind
        self.roundOrdinal = roundOrdinal
        self.finding = finding
    }
}

private struct Gate1EvidenceCycleInterval: Equatable, Sendable {
    let roundOrdinal: UInt16
    let startSequence: UInt64
    let endSequence: UInt64?
}

private struct Gate1EvidenceCheckpointKey: Hashable {
    let kind: Gate1CheckpointKind
    let roundOrdinal: UInt16?
}

private enum Gate1EvidenceRules {
    static let requiredCycleCount: UInt16 = 100

    static func isReviewableCandidateDisk(
        _ disk: Gate1EvidenceDiskFrame,
        in observation: Gate1EvidenceObservationFrame
    ) -> Bool {
        observation.coverage == .verified
            && !observation.coordinatorInventoryPresent
            && !disk.candidateVolumeOrdinals.isEmpty
            && disk.mutationSnapshotVolumeOrdinals.isEmpty
            && disk.unverifiedVolumeOrdinals.isEmpty
            && disk.issueCodes.contains(.unknownVolumeRole)
            && disk.issueCodes.allSatisfy { $0 == .unknownVolumeRole }
    }

    static func checkpointRequirementMet(
        _ checkpoints: [Gate1EvidenceCheckpoint],
        cycleIntervals: [Gate1EvidenceCycleInterval]
    ) -> Bool {
        let requiredScenarioKinds: Set<Gate1CheckpointKind> = [
            .multiPartitionTopology,
            .sleep,
            .wakeResubscription,
            .applicationRestart,
            .declarationInvalidatedAfterReinsert,
            .declarationInvalidatedAfterWake,
            .declarationInvalidatedAfterRestart,
            .declarationInvalidatedAfterTopologyChange,
            .declarationInvalidatedAfterConsumption,
            .strictReleaseChecks,
            .readOnlyBoundaryReview,
        ]
        let confirmedScenarioKinds = Set(
            checkpoints.compactMap { checkpoint in
                checkpoint.finding == .confirmed && checkpoint.roundOrdinal == nil
                    ? checkpoint.kind
                    : nil
            }
        )
        guard requiredScenarioKinds.isSubset(of: confirmedScenarioKinds) else {
            return false
        }
        let completedRounds = Set(
            cycleIntervals.compactMap { interval in
                interval.endSequence == nil ? nil : interval.roundOrdinal
            }
        )
        let requiredRounds = Set(UInt16(1) ... requiredCycleCount)
        guard requiredRounds.isSubset(of: completedRounds) else {
            return false
        }
        for comparisonKind in [
            Gate1CheckpointKind.systemInventoryComparison,
            .mountTableComparison,
        ] {
            let confirmedRounds = Set(
                checkpoints.compactMap { checkpoint in
                    checkpoint.kind == comparisonKind
                        && checkpoint.finding == .confirmed
                        ? checkpoint.roundOrdinal
                        : nil
                }
            )
            guard confirmedRounds == requiredRounds else {
                return false
            }
        }
        return true
    }

    static func checkpointsAreValid(
        _ checkpoints: [Gate1EvidenceCheckpoint],
        cycleIntervals: [Gate1EvidenceCycleInterval],
        observations: [Gate1EvidenceObservationFrame],
        targetDiskOrdinal: UInt32?
    ) -> Bool {
        let keys = checkpoints.map {
            Gate1EvidenceCheckpointKey(
                kind: $0.kind,
                roundOrdinal: $0.roundOrdinal
            )
        }
        guard Set(keys).count == keys.count else {
            return false
        }
        return checkpoints.allSatisfy { checkpoint in
            let requiresRound = checkpoint.kind == .systemInventoryComparison
                || checkpoint.kind == .mountTableComparison
            if !requiresRound {
                return checkpoint.roundOrdinal == nil
            }
            guard let roundOrdinal = checkpoint.roundOrdinal,
                  (1 ... requiredCycleCount).contains(roundOrdinal),
                  let interval = cycleIntervals.first(where: {
                      $0.roundOrdinal == roundOrdinal
                  }),
                  checkpoint.sequence > interval.startSequence,
                  let targetDiskOrdinal,
                  let latestObservation = observations.last(where: {
                      $0.sequence < checkpoint.sequence
                  }),
                  let targetFrame = latestObservation.disks.first(where: {
                      $0.diskOrdinal == targetDiskOrdinal
                  }),
                  isReviewableCandidateDisk(
                      targetFrame,
                      in: latestObservation
                  )
            else {
                return false
            }
            if let endSequence = interval.endSequence {
                return checkpoint.sequence < endSequence
            }
            return true
        }
    }

    static func verdict(
        failureCodes: [Gate1EvidenceFailureCode],
        cycleRequirementMet: Bool,
        checkpointRequirementMet: Bool,
        multiPartitionObservationPresent: Bool,
        finalObservationVerified: Bool,
        openConnectionCount: UInt32
    ) -> Gate1EvidenceVerdict {
        if !failureCodes.isEmpty {
            return .failedClosed
        }
        if cycleRequirementMet
            && checkpointRequirementMet
            && multiPartitionObservationPresent
            && finalObservationVerified
            && openConnectionCount == 0
        {
            return .readyForHumanReview
        }
        return .incomplete
    }
}

public struct Gate1EvidenceBundle: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt16 = 2

    public let schemaVersion: UInt16
    public let header: Gate1EvidenceHeader
    public let sealedAt: GateEvidenceTimestamp
    public let verdict: Gate1EvidenceVerdict
    public let requiredCycleCount: UInt16
    public let completedCycleCount: UInt16
    public let cycleRequirementMet: Bool
    public let checkpointRequirementMet: Bool
    public let multiPartitionObservationPresent: Bool
    public let targetDiskOrdinal: UInt32?
    public let openConnectionCount: UInt32
    public let observations: [Gate1EvidenceObservationFrame]
    public let checkpoints: [Gate1EvidenceCheckpoint]
    public let failureCodes: [Gate1EvidenceFailureCode]

    fileprivate init(
        header: Gate1EvidenceHeader,
        sealedAt: GateEvidenceTimestamp,
        verdict: Gate1EvidenceVerdict,
        requiredCycleCount: UInt16,
        completedCycleCount: UInt16,
        checkpointRequirementMet: Bool,
        multiPartitionObservationPresent: Bool,
        targetDiskOrdinal: UInt32?,
        openConnectionCount: UInt32,
        observations: [Gate1EvidenceObservationFrame],
        checkpoints: [Gate1EvidenceCheckpoint],
        failureCodes: [Gate1EvidenceFailureCode]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.header = header
        self.sealedAt = sealedAt
        self.verdict = verdict
        self.requiredCycleCount = requiredCycleCount
        self.completedCycleCount = completedCycleCount
        cycleRequirementMet = completedCycleCount >= requiredCycleCount
        self.checkpointRequirementMet = checkpointRequirementMet
        self.multiPartitionObservationPresent = multiPartitionObservationPresent
        self.targetDiskOrdinal = targetDiskOrdinal
        self.openConnectionCount = openConnectionCount
        self.observations = observations
        self.checkpoints = checkpoints
        self.failureCodes = failureCodes
    }

    public func encodedCanonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

public struct Gate1EvidenceArtifact: Equatable, Sendable {
    public let bundle: Gate1EvidenceBundle
    public let canonicalJSON: Data
    public let sha256Digest: String

    fileprivate init(bundle: Gate1EvidenceBundle, canonicalJSON: Data) {
        self.bundle = bundle
        self.canonicalJSON = canonicalJSON
        sha256Digest = Self.lowercaseHex(SHA256.hash(data: canonicalJSON))
    }

    private static func lowercaseHex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum Gate1EvidenceVerificationFailure: Error, Equatable, Sendable {
    case emptyInput
    case encodedByteLimitExceeded
    case invalidDigest
    case digestMismatch
    case malformedJSON
    case unsupportedSchema
    case nonCanonical
    case invalidBundle
}

public enum Gate1EvidenceArtifactVerifier {
    private struct ReplayConnection {
        let connectionOrdinal: UInt32
        var knownVolumeOrdinals: Set<UInt32>
        var nextVolumeOrdinal: UInt64
        var reviewableCandidateVolumeOrdinals: Set<UInt32>
        var cycleEligible: Bool
        var verifiedPresentBeforeTargetBinding: Bool
        var firstReviewableSequence: UInt64?
        var remainedReviewableSinceStart: Bool
        var sawReviewableMultiPartition: Bool
    }

    private struct ReplaySummary {
        let completedCycleCount: UInt16
        let openConnectionCount: UInt32
        let targetDiskOrdinal: UInt32?
        let cycleIntervals: [Gate1EvidenceCycleInterval]
        let multiPartitionObservationPresent: Bool
    }

    public static func verify(
        canonicalJSON: Data,
        expectedSHA256Digest: String,
        policy: Gate1EvidencePolicy = .default
    ) -> Result<Gate1EvidenceArtifact, Gate1EvidenceVerificationFailure> {
        guard !canonicalJSON.isEmpty else {
            return .failure(.emptyInput)
        }
        guard canonicalJSON.count <= policy.maxEncodedBytes else {
            return .failure(.encodedByteLimitExceeded)
        }
        guard isLowercaseSHA256(expectedSHA256Digest) else {
            return .failure(.invalidDigest)
        }
        let actualDigest = lowercaseHex(SHA256.hash(data: canonicalJSON))
        guard actualDigest == expectedSHA256Digest else {
            return .failure(.digestMismatch)
        }
        guard StrictJSONObjectValidator.accepts(canonicalJSON) else {
            return .failure(.malformedJSON)
        }

        let bundle: Gate1EvidenceBundle
        do {
            bundle = try JSONDecoder().decode(
                Gate1EvidenceBundle.self,
                from: canonicalJSON
            )
        } catch {
            return .failure(.malformedJSON)
        }
        guard bundle.schemaVersion == Gate1EvidenceBundle.currentSchemaVersion else {
            return .failure(.unsupportedSchema)
        }
        do {
            guard try bundle.encodedCanonicalJSON() == canonicalJSON else {
                return .failure(.nonCanonical)
            }
        } catch {
            return .failure(.malformedJSON)
        }
        guard isSemanticallyValid(bundle, policy: policy) else {
            return .failure(.invalidBundle)
        }
        return .success(
            Gate1EvidenceArtifact(bundle: bundle, canonicalJSON: canonicalJSON)
        )
    }

    private static func isSemanticallyValid(
        _ bundle: Gate1EvidenceBundle,
        policy: Gate1EvidencePolicy
    ) -> Bool {
        guard (try? Gate1EvidenceHeader(
            evidenceID: bundle.header.evidenceID,
            applicationVersion: bundle.header.applicationVersion,
            applicationBuild: bundle.header.applicationBuild,
            applicationSHA256: bundle.header.applicationSHA256,
            macOSVersion: bundle.header.macOSVersion
        )) != nil,
        bundle.sealedAt.millisecondsSince1970 >= 0,
        bundle.requiredCycleCount == Gate1EvidenceRules.requiredCycleCount,
        bundle.observations.count <= policy.maxObservations,
        bundle.checkpoints.count <= policy.maxCheckpoints,
        isStrictlyIncreasing(bundle.observations.map(\.sequence)),
        isStrictlyIncreasing(bundle.checkpoints.map(\.sequence)),
        areSortedUnique(bundle.failureCodes),
        eventsAreContiguousAndMonotonic(bundle),
        let replay = replay(bundle.observations, policy: policy),
        Gate1EvidenceRules.checkpointsAreValid(
            bundle.checkpoints,
            cycleIntervals: replay.cycleIntervals,
            observations: bundle.observations,
            targetDiskOrdinal: replay.targetDiskOrdinal
        ),
        replay.completedCycleCount == bundle.completedCycleCount,
        replay.openConnectionCount == bundle.openConnectionCount,
        replay.targetDiskOrdinal == bundle.targetDiskOrdinal
        else {
            return false
        }
        let cycleRequirementMet = replay.completedCycleCount
            >= Gate1EvidenceRules.requiredCycleCount
        let checkpointRequirementMet = Gate1EvidenceRules.checkpointRequirementMet(
            bundle.checkpoints,
            cycleIntervals: replay.cycleIntervals
        )
        let multiPartitionObservationPresent = replay.multiPartitionObservationPresent
        let hasContradictedCheckpoint = bundle.checkpoints.contains {
            $0.finding == .contradicted
        }
        guard bundle.cycleRequirementMet == cycleRequirementMet,
              bundle.checkpointRequirementMet == checkpointRequirementMet,
              bundle.multiPartitionObservationPresent
                == multiPartitionObservationPresent,
              bundle.failureCodes.contains(.checkpointContradicted)
                == hasContradictedCheckpoint
        else {
            return false
        }
        return bundle.verdict == Gate1EvidenceRules.verdict(
            failureCodes: bundle.failureCodes,
            cycleRequirementMet: cycleRequirementMet,
            checkpointRequirementMet: checkpointRequirementMet,
            multiPartitionObservationPresent: multiPartitionObservationPresent,
            finalObservationVerified:
                bundle.observations.last?.coverage == .verified,
            openConnectionCount: replay.openConnectionCount
        )
    }

    private static func eventsAreContiguousAndMonotonic(
        _ bundle: Gate1EvidenceBundle
    ) -> Bool {
        let events = bundle.observations.map {
            ($0.sequence, $0.occurredAt.millisecondsSince1970)
        } + bundle.checkpoints.map {
            ($0.sequence, $0.occurredAt.millisecondsSince1970)
        }
        let sortedEvents = events.sorted { $0.0 < $1.0 }
        var previousTimestamp: Int64?
        for (index, event) in sortedEvents.enumerated() {
            guard event.0 == UInt64(index) + 1,
                  event.1 >= 0,
                  event.1 <= bundle.sealedAt.millisecondsSince1970
            else {
                return false
            }
            if let previousTimestamp, event.1 < previousTimestamp {
                return false
            }
            previousTimestamp = event.1
        }
        return true
    }

    private static func replay(
        _ observations: [Gate1EvidenceObservationFrame],
        policy: Gate1EvidencePolicy
    ) -> ReplaySummary? {
        var activeConnections: [UInt32: ReplayConnection] = [:]
        var seenDiskOrdinals: Set<UInt32> = []
        var nextDiskOrdinal: UInt64 = 1
        var nextConnectionOrdinal: UInt64 = 1
        var completedCycleCount: UInt32 = 0
        var targetDiskOrdinal: UInt32?
        var targetAbsenceBaselineEstablished = false
        var cycleIntervals: [Gate1EvidenceCycleInterval] = []
        var multiPartitionObservationPresent = false

        for observation in observations {
            guard observation.disks.count <= policy.maxDisksPerObservation,
                  areSortedUnique(observation.issueCodes),
                  isSortedUnique(observation.confirmedAbsentDiskOrdinals),
                  isStrictlyIncreasing(
                      observation.disks.map { UInt64($0.diskOrdinal) }
                  ),
                  (observation.coverage == .verified)
                    == observation.issueCodes.isEmpty
            else {
                return nil
            }
            let presentDiskOrdinals = observation.disks.map(\.diskOrdinal)
            guard Set(presentDiskOrdinals).count == presentDiskOrdinals.count else {
                return nil
            }
            let newConnectionOrdinals = observation.disks.compactMap { disk in
                activeConnections[disk.diskOrdinal] == nil
                    ? disk.connectionOrdinal
                    : nil
            }.sorted()
            let expectedNewConnectionOrdinals = (0 ..< newConnectionOrdinals.count)
                .map { offset in
                    UInt32(nextConnectionOrdinal + UInt64(offset))
                }
            guard newConnectionOrdinals == expectedNewConnectionOrdinals else {
                return nil
            }
            nextConnectionOrdinal += UInt64(newConnectionOrdinals.count)

            for disk in observation.disks {
                guard disk.diskOrdinal > 0,
                      disk.connectionOrdinal > 0,
                      Int(disk.volumeCount) <= policy.maxVolumesPerDisk,
                      isSortedUnique(disk.volumeOrdinals),
                      isSortedUnique(disk.candidateVolumeOrdinals),
                      isSortedUnique(disk.mutationSnapshotVolumeOrdinals),
                      isSortedUnique(disk.unverifiedVolumeOrdinals),
                      disk.volumeOrdinals.allSatisfy({ $0 > 0 }),
                      Set(disk.candidateVolumeOrdinals).isSubset(
                          of: Set(disk.volumeOrdinals)
                      ),
                      Set(disk.mutationSnapshotVolumeOrdinals).isSubset(
                          of: Set(disk.volumeOrdinals)
                      ),
                      Set(disk.unverifiedVolumeOrdinals).isSubset(
                          of: Set(disk.volumeOrdinals)
                      ),
                      Set(disk.candidateVolumeOrdinals).isDisjoint(
                          with: Set(disk.mutationSnapshotVolumeOrdinals)
                      ),
                      Set(disk.candidateVolumeOrdinals).isDisjoint(
                          with: Set(disk.unverifiedVolumeOrdinals)
                      ),
                      Set(disk.mutationSnapshotVolumeOrdinals).isDisjoint(
                          with: Set(disk.unverifiedVolumeOrdinals)
                      ),
                      areSortedUnique(disk.issueCodes)
                else {
                    return nil
                }

                let wasSeen = seenDiskOrdinals.contains(disk.diskOrdinal)
                if !wasSeen {
                    guard UInt64(disk.diskOrdinal) == nextDiskOrdinal else {
                        return nil
                    }
                    seenDiskOrdinals.insert(disk.diskOrdinal)
                    nextDiskOrdinal += 1
                }

                let reviewableCandidate = Gate1EvidenceRules
                    .isReviewableCandidateDisk(disk, in: observation)
                let reviewableMultiPartition = reviewableCandidate
                    && disk.volumeOrdinals.count > 1
                    && disk.unverifiedVolumeOrdinals.isEmpty
                if var active = activeConnections[disk.diskOrdinal] {
                    guard active.connectionOrdinal == disk.connectionOrdinal,
                          disk.mediaGenerationRelation == .unchanged
                    else {
                        return nil
                    }
                    for ordinal in disk.volumeOrdinals
                    where !active.knownVolumeOrdinals.contains(ordinal) {
                        guard UInt64(ordinal) == active.nextVolumeOrdinal else {
                            return nil
                        }
                        active.knownVolumeOrdinals.insert(ordinal)
                        active.nextVolumeOrdinal += 1
                    }
                    guard active.reviewableCandidateVolumeOrdinals.isDisjoint(
                        with: Set(disk.mutationSnapshotVolumeOrdinals)
                    ) else {
                        return nil
                    }
                    let targetWasUnbound = targetDiskOrdinal == nil
                    if let target = targetDiskOrdinal,
                       reviewableCandidate,
                       target != disk.diskOrdinal
                    {
                        return nil
                    }
                    if reviewableCandidate, targetDiskOrdinal == nil {
                        targetDiskOrdinal = disk.diskOrdinal
                    }
                    if targetWasUnbound,
                       !reviewableCandidate,
                       observation.coverage == .verified
                    {
                        active.verifiedPresentBeforeTargetBinding = true
                    }
                    if targetWasUnbound,
                       reviewableCandidate,
                       targetAbsenceBaselineEstablished,
                       !active.verifiedPresentBeforeTargetBinding
                    {
                        active.cycleEligible = true
                    }
                    if targetDiskOrdinal == disk.diskOrdinal,
                       observation.coverage == .verified
                    {
                        if active.cycleEligible,
                           active.firstReviewableSequence == nil,
                           observation.coverage == .verified,
                           !reviewableCandidate
                        {
                            return nil
                        }
                        if active.cycleEligible,
                           active.firstReviewableSequence == nil,
                           reviewableCandidate
                        {
                            active.firstReviewableSequence = observation.sequence
                            active.remainedReviewableSinceStart = true
                        } else if active.firstReviewableSequence != nil,
                                  !reviewableCandidate
                        {
                            return nil
                        }
                        if reviewableCandidate {
                            active.reviewableCandidateVolumeOrdinals.formUnion(
                                disk.candidateVolumeOrdinals
                            )
                            active.sawReviewableMultiPartition =
                                active.sawReviewableMultiPartition
                                    || reviewableMultiPartition
                        }
                    }
                    activeConnections[disk.diskOrdinal] = active
                } else {
                    if wasSeen {
                        guard disk.mediaGenerationRelation == .advanced else {
                            return nil
                        }
                    } else if disk.mediaGenerationRelation != .first {
                        return nil
                    }
                    var knownVolumeOrdinals: Set<UInt32> = []
                    var nextVolumeOrdinal: UInt64 = 1
                    for ordinal in disk.volumeOrdinals {
                        guard UInt64(ordinal) == nextVolumeOrdinal else {
                            return nil
                        }
                        knownVolumeOrdinals.insert(ordinal)
                        nextVolumeOrdinal += 1
                    }
                    if let target = targetDiskOrdinal,
                       reviewableCandidate,
                       target != disk.diskOrdinal
                    {
                        return nil
                    }
                    if reviewableCandidate, targetDiskOrdinal == nil {
                        targetDiskOrdinal = disk.diskOrdinal
                    }
                    let cycleEligible = targetDiskOrdinal == disk.diskOrdinal
                        && targetAbsenceBaselineEstablished
                    if cycleEligible,
                       observation.coverage == .verified,
                       !reviewableCandidate
                    {
                        return nil
                    }
                    activeConnections[disk.diskOrdinal] = ReplayConnection(
                        connectionOrdinal: disk.connectionOrdinal,
                        knownVolumeOrdinals: knownVolumeOrdinals,
                        nextVolumeOrdinal: nextVolumeOrdinal,
                        reviewableCandidateVolumeOrdinals: reviewableCandidate
                            ? Set(disk.candidateVolumeOrdinals)
                            : [],
                        cycleEligible: cycleEligible,
                        verifiedPresentBeforeTargetBinding:
                            targetDiskOrdinal == nil
                                && observation.coverage == .verified
                                && !reviewableCandidate,
                        firstReviewableSequence: reviewableCandidate
                            && cycleEligible
                            ? observation.sequence
                            : nil,
                        remainedReviewableSinceStart: reviewableCandidate
                            && cycleEligible,
                        sawReviewableMultiPartition: reviewableMultiPartition
                            && cycleEligible
                    )
                }
            }

            let presentSet = Set(presentDiskOrdinals)
            let expectedAbsent = activeConnections.keys
                .filter { !presentSet.contains($0) }
                .sorted()
            if observation.coverage == .verified {
                guard observation.confirmedAbsentDiskOrdinals == expectedAbsent else {
                    return nil
                }
                for diskOrdinal in expectedAbsent {
                    guard let removed = activeConnections.removeValue(
                        forKey: diskOrdinal
                    ) else {
                        return nil
                    }
                    if diskOrdinal == targetDiskOrdinal,
                       let startSequence = removed.firstReviewableSequence,
                       removed.remainedReviewableSinceStart
                    {
                        guard completedCycleCount < UInt32(UInt16.max) else {
                            return nil
                        }
                        completedCycleCount += 1
                        guard let roundOrdinal = UInt16(
                            exactly: completedCycleCount
                        ) else {
                            return nil
                        }
                        cycleIntervals.append(
                            Gate1EvidenceCycleInterval(
                                roundOrdinal: roundOrdinal,
                                startSequence: startSequence,
                                endSequence: observation.sequence
                            )
                        )
                        multiPartitionObservationPresent =
                            multiPartitionObservationPresent
                                || removed.sawReviewableMultiPartition
                    }
                }
            } else if !observation.confirmedAbsentDiskOrdinals.isEmpty {
                return nil
            }
            if observation.coverage == .verified {
                if let targetDiskOrdinal {
                    if !presentSet.contains(targetDiskOrdinal) {
                        targetAbsenceBaselineEstablished = true
                    }
                } else if !observation.disks.contains(where: {
                    Gate1EvidenceRules.isReviewableCandidateDisk(
                        $0,
                        in: observation
                    )
                }) {
                    targetAbsenceBaselineEstablished = true
                }
            }
        }

        guard let completed = UInt16(exactly: completedCycleCount),
              let open = UInt32(exactly: targetDiskOrdinal.flatMap {
                  activeConnections[$0]
              } == nil ? 0 : 1)
        else {
            return nil
        }
        if let targetDiskOrdinal,
           let active = activeConnections[targetDiskOrdinal],
           let startSequence = active.firstReviewableSequence,
           active.remainedReviewableSinceStart,
           completed < UInt16.max
        {
            cycleIntervals.append(
                Gate1EvidenceCycleInterval(
                    roundOrdinal: completed + 1,
                    startSequence: startSequence,
                    endSequence: nil
                )
            )
        }
        return ReplaySummary(
            completedCycleCount: completed,
            openConnectionCount: open,
            targetDiskOrdinal: targetDiskOrdinal,
            cycleIntervals: cycleIntervals,
            multiPartitionObservationPresent: multiPartitionObservationPresent
        )
    }

    private static func areSortedUnique<T>(_ values: [T]) -> Bool
    where T: RawRepresentable & Hashable, T.RawValue == String {
        let rawValues = values.map(\.rawValue)
        return rawValues == rawValues.sorted()
            && Set(rawValues).count == rawValues.count
    }

    private static func isSortedUnique(_ values: [UInt32]) -> Bool {
        values == values.sorted() && Set(values).count == values.count
    }

    private static func isStrictlyIncreasing(_ values: [UInt64]) -> Bool {
        zip(values, values.dropFirst()).allSatisfy(<)
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }

    private static func lowercaseHex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum Gate1EvidenceRecorderError: Error, Equatable, Sendable {
    case invalidTimestamp
    case nonMonotonicTimestamp
    case sealed
    case failedClosed
    case countOutOfRange
    case aliasSpaceExhausted
    case mediaGenerationChangedBeforeAbsence
    case mediaGenerationRegressedAfterAbsence
    case mediaGenerationReusedAfterAbsence
    case mediaGenerationUnknownAfterAbsence
    case invalidCheckpoint
    case checkpointLimitExceeded
    case diskLimitExceeded
    case encodedByteLimitExceeded
    case observationLimitExceeded
    case targetCycleEvidenceInterrupted
    case topologyContradiction
    case volumeLimitExceeded
}

public enum Gate1EvidenceSourceFailure: Equatable, Sendable {
    case eventQueueOverflow
    case finalObservationUnverified
    case observationStreamEnded
    case unclassifiedObservationFailure
    case unclassifiedOperatorFailure
}

public enum Gate1EvidenceRecorderPhase: String, Equatable, Sendable {
    case recording
    case failedClosed
    case sealed
}

public struct Gate1EvidenceRecorderStatus: Equatable, Sendable {
    public let phase: Gate1EvidenceRecorderPhase
    public let observationCount: UInt64
    public let checkpointCount: UInt64
    public let completedCycleCount: UInt16
    public let requiredCycleCount: UInt16
    public let openConnectionCount: UInt64
    public let failureCodes: [Gate1EvidenceFailureCode]

    public init(
        phase: Gate1EvidenceRecorderPhase,
        observationCount: UInt64,
        checkpointCount: UInt64,
        completedCycleCount: UInt16,
        requiredCycleCount: UInt16,
        openConnectionCount: UInt64,
        failureCodes: [Gate1EvidenceFailureCode]
    ) {
        self.phase = phase
        self.observationCount = observationCount
        self.checkpointCount = checkpointCount
        self.completedCycleCount = completedCycleCount
        self.requiredCycleCount = requiredCycleCount
        self.openConnectionCount = openConnectionCount
        self.failureCodes = failureCodes
    }
}

public actor Gate1EvidenceRecorder {
    private struct VolumeEvidenceKey: Hashable, Sendable {
        let volumeUUID: String
        let bsdName: String
    }

    private struct ProjectedVolume: Sendable {
        let key: VolumeEvidenceKey?
        let candidatePresent: Bool
        let mutationSnapshotPresent: Bool
    }

    private struct ActiveConnection: Sendable {
        let diskOrdinal: UInt32
        let connectionOrdinal: UInt32
        let mediaGeneration: MediaGeneration
        var volumeOrdinals: [VolumeEvidenceKey: UInt32]
        var nextVolumeOrdinal: UInt64
        var reviewableCandidateVolumeOrdinals: Set<UInt32>
        var cycleEligible: Bool
        var verifiedPresentBeforeTargetBinding: Bool
        var firstReviewableSequence: UInt64?
        var remainedReviewableSinceStart: Bool
        var sawReviewableMultiPartition: Bool
    }

    private static let requiredCycleCount = Gate1EvidenceRules.requiredCycleCount

    private let header: Gate1EvidenceHeader
    private let policy: Gate1EvidencePolicy
    private let clock: GateEvidenceClock
    private var sealedArtifact: Gate1EvidenceArtifact?
    private var observations: [Gate1EvidenceObservationFrame] = []
    private var diskOrdinals: [PhysicalDiskID: UInt32] = [:]
    private var nextDiskOrdinal: UInt64 = 1
    private var activeConnections: [PhysicalDiskID: ActiveConnection] = [:]
    private var lastConfirmedGenerations: [PhysicalDiskID: MediaGeneration] = [:]
    private var nextConnectionOrdinal: UInt64 = 1
    private var completedCycleCount: UInt16 = 0
    private var targetDiskOrdinal: UInt32?
    // Session-only identity evidence. BSD names can be reused by a different
    // disk after removal; none of these UUIDs enter the anonymous artifact.
    private var targetCandidateVolumeUUIDs: [String]?
    private var targetAbsenceBaselineEstablished = false
    private var completedCycleIntervals: [Gate1EvidenceCycleInterval] = []
    private var multiPartitionObservationPresent = false
    private var latestObservationPermitsComparison = false
    private var checkpoints: [Gate1EvidenceCheckpoint] = []
    private var failureCodes: Set<Gate1EvidenceFailureCode> = []
    private var lastTimestamp: GateEvidenceTimestamp?

    public init(
        header: Gate1EvidenceHeader,
        policy: Gate1EvidencePolicy = .default,
        clock: GateEvidenceClock = .live
    ) {
        self.header = header
        self.policy = policy
        self.clock = clock
    }

    public func status() -> Gate1EvidenceRecorderStatus {
        let phase: Gate1EvidenceRecorderPhase
        if sealedArtifact != nil {
            phase = .sealed
        } else if failureCodes.isEmpty {
            phase = .recording
        } else {
            phase = .failedClosed
        }
        return Gate1EvidenceRecorderStatus(
            phase: phase,
            observationCount: UInt64(observations.count),
            checkpointCount: UInt64(checkpoints.count),
            completedCycleCount: completedCycleCount,
            requiredCycleCount: Self.requiredCycleCount,
            openConnectionCount: targetDiskOrdinal.flatMap { target in
                activeConnections.values.first { $0.diskOrdinal == target }
            } == nil ? 0 : 1,
            failureCodes: failureCodes.sorted { $0.rawValue < $1.rawValue }
        )
    }

    public func ingest(
        _ observation: DiskInventoryObservation
    ) throws {
        try ingest(observation, at: clock.now())
    }

    public func ingest(
        _ observation: DiskInventoryObservation,
        at timestamp: GateEvidenceTimestamp
    ) throws {
        guard sealedArtifact == nil else {
            throw Gate1EvidenceRecorderError.sealed
        }
        guard failureCodes.isEmpty else {
            throw Gate1EvidenceRecorderError.failedClosed
        }
        try validateTimestamp(timestamp)
        guard observations.count < policy.maxObservations else {
            failureCodes.insert(.observationLimitExceeded)
            throw Gate1EvidenceRecorderError.observationLimitExceeded
        }
        guard observation.physicalDisks.count <= policy.maxDisksPerObservation else {
            failureCodes.insert(.diskLimitExceeded)
            throw Gate1EvidenceRecorderError.diskLimitExceeded
        }
        let physicalDiskIDs = observation.physicalDisks.map {
            $0.instanceID.physicalDiskID
        }
        guard Set(physicalDiskIDs).count == physicalDiskIDs.count else {
            failureCodes.insert(.topologyContradiction)
            throw Gate1EvidenceRecorderError.topologyContradiction
        }
        guard observation.physicalDisks.allSatisfy({
            $0.volumes.count <= policy.maxVolumesPerDisk
        }) else {
            failureCodes.insert(.volumeLimitExceeded)
            throw Gate1EvidenceRecorderError.volumeLimitExceeded
        }
        let sequence = try nextEventSequence()

        var candidateOrdinals = diskOrdinals
        var candidateNextDiskOrdinal = nextDiskOrdinal
        var candidateConnections = activeConnections
        var candidateLastGenerations = lastConfirmedGenerations
        var candidateNextConnectionOrdinal = nextConnectionOrdinal
        var candidateCompletedCycleCount = completedCycleCount
        var candidateTargetDiskOrdinal = targetDiskOrdinal
        var candidateTargetVolumeUUIDs = targetCandidateVolumeUUIDs
        var candidateTargetAbsenceBaselineEstablished =
            targetAbsenceBaselineEstablished
        var candidateCycleIntervals = completedCycleIntervals
        var candidateMultiPartitionObservationPresent =
            multiPartitionObservationPresent
        var frames: [Gate1EvidenceDiskFrame] = []
        for disk in observation.physicalDisks {
            let physicalDiskID = disk.instanceID.physicalDiskID
            let diskOrdinal: UInt32
            if let existing = candidateOrdinals[physicalDiskID] {
                diskOrdinal = existing
            } else {
                guard candidateNextDiskOrdinal <= UInt64(UInt32.max) else {
                    throw Gate1EvidenceRecorderError.aliasSpaceExhausted
                }
                diskOrdinal = UInt32(candidateNextDiskOrdinal)
                candidateOrdinals[physicalDiskID] = diskOrdinal
                candidateNextDiskOrdinal += 1
            }
            guard let projectedVolumes = Self.projectedVolumes(
                disk.volumes,
                for: disk.instanceID
            ) else {
                failureCodes.insert(.topologyContradiction)
                throw Gate1EvidenceRecorderError.topologyContradiction
            }
            var connection: ActiveConnection
            let isNewConnection: Bool
            let generationRelation: Gate1MediaGenerationRelation
            if let existing = candidateConnections[physicalDiskID] {
                guard existing.mediaGeneration == disk.instanceID.mediaGeneration else {
                    failureCodes.insert(.mediaGenerationChangedBeforeAbsence)
                    throw Gate1EvidenceRecorderError.mediaGenerationChangedBeforeAbsence
                }
                generationRelation = .unchanged
                connection = existing
                isNewConnection = false
            } else {
                guard candidateNextConnectionOrdinal <= UInt64(UInt32.max) else {
                    throw Gate1EvidenceRecorderError.aliasSpaceExhausted
                }
                generationRelation = Self.generationRelation(
                    previous: candidateLastGenerations[physicalDiskID],
                    current: disk.instanceID.mediaGeneration
                )
                if generationRelation == .reusedWithoutAdvance {
                    failureCodes.insert(.mediaGenerationReusedAfterAbsence)
                    throw Gate1EvidenceRecorderError.mediaGenerationReusedAfterAbsence
                }
                if generationRelation == .regressed {
                    failureCodes.insert(.mediaGenerationRegressedAfterAbsence)
                    throw Gate1EvidenceRecorderError.mediaGenerationRegressedAfterAbsence
                }
                if generationRelation == .unknown {
                    failureCodes.insert(.mediaGenerationUnknownAfterAbsence)
                    throw Gate1EvidenceRecorderError.mediaGenerationUnknownAfterAbsence
                }
                let created = ActiveConnection(
                    diskOrdinal: diskOrdinal,
                    connectionOrdinal: UInt32(candidateNextConnectionOrdinal),
                    mediaGeneration: disk.instanceID.mediaGeneration,
                    volumeOrdinals: [:],
                    nextVolumeOrdinal: 1,
                    reviewableCandidateVolumeOrdinals: [],
                    cycleEligible: false,
                    verifiedPresentBeforeTargetBinding: false,
                    firstReviewableSequence: nil,
                    remainedReviewableSinceStart: false,
                    sawReviewableMultiPartition: false
                )
                candidateNextConnectionOrdinal += 1
                connection = created
                isNewConnection = true
            }
            var localKeys: Set<VolumeEvidenceKey> = []
            var volumeOrdinals: [UInt32] = []
            var candidateVolumeOrdinals: [UInt32] = []
            var mutationSnapshotVolumeOrdinals: [UInt32] = []
            var unverifiedVolumeOrdinals: [UInt32] = []
            for volume in projectedVolumes {
                let volumeOrdinal: UInt32
                if let key = volume.key {
                    guard localKeys.insert(key).inserted else {
                        failureCodes.insert(.topologyContradiction)
                        throw Gate1EvidenceRecorderError.topologyContradiction
                    }
                    if let existing = connection.volumeOrdinals[key] {
                        volumeOrdinal = existing
                    } else {
                        guard connection.nextVolumeOrdinal <= UInt64(UInt32.max) else {
                            throw Gate1EvidenceRecorderError.aliasSpaceExhausted
                        }
                        volumeOrdinal = UInt32(connection.nextVolumeOrdinal)
                        connection.volumeOrdinals[key] = volumeOrdinal
                        connection.nextVolumeOrdinal += 1
                    }
                } else {
                    guard connection.nextVolumeOrdinal <= UInt64(UInt32.max) else {
                        throw Gate1EvidenceRecorderError.aliasSpaceExhausted
                    }
                    volumeOrdinal = UInt32(connection.nextVolumeOrdinal)
                    connection.nextVolumeOrdinal += 1
                    unverifiedVolumeOrdinals.append(volumeOrdinal)
                }
                volumeOrdinals.append(volumeOrdinal)
                if volume.candidatePresent {
                    candidateVolumeOrdinals.append(volumeOrdinal)
                }
                if volume.mutationSnapshotPresent {
                    mutationSnapshotVolumeOrdinals.append(volumeOrdinal)
                }
            }
            volumeOrdinals.sort()
            candidateVolumeOrdinals.sort()
            mutationSnapshotVolumeOrdinals.sort()
            unverifiedVolumeOrdinals.sort()
            guard connection.reviewableCandidateVolumeOrdinals.isDisjoint(
                with: Set(mutationSnapshotVolumeOrdinals)
            ) else {
                failureCodes.insert(.topologyContradiction)
                throw Gate1EvidenceRecorderError.topologyContradiction
            }
            let issueCodes = Self.normalizedIssueCodes(
                disk.issues.map(Self.issueCode)
                    + disk.volumes.flatMap { volume in
                        volume.issues.map(Self.issueCode)
                    }
            )
            let reviewableCandidate = Self.isReviewableCandidateDisk(
                observation: observation,
                candidateVolumeOrdinals: candidateVolumeOrdinals,
                mutationSnapshotVolumeOrdinals:
                    mutationSnapshotVolumeOrdinals,
                unverifiedVolumeOrdinals: unverifiedVolumeOrdinals,
                issueCodes: issueCodes
            )
            let reviewableMultiPartition = reviewableCandidate
                && volumeOrdinals.count > 1
                && unverifiedVolumeOrdinals.isEmpty
            let targetWasUnbound = candidateTargetDiskOrdinal == nil
            if reviewableCandidate {
                if let target = candidateTargetDiskOrdinal,
                   target != diskOrdinal
                {
                    failureCodes.insert(.topologyContradiction)
                    throw Gate1EvidenceRecorderError.topologyContradiction
                }
                let currentUUIDs = projectedVolumes.filter(\.candidatePresent)
                    .compactMap { $0.key?.volumeUUID }.sorted()
                if let boundUUIDs = candidateTargetVolumeUUIDs,
                   boundUUIDs != currentUUIDs
                {
                    failureCodes.insert(.topologyContradiction)
                    throw Gate1EvidenceRecorderError.topologyContradiction
                }
                candidateTargetVolumeUUIDs = currentUUIDs
                candidateTargetDiskOrdinal = diskOrdinal
            }
            if targetWasUnbound,
               !reviewableCandidate,
               observation.issues.isEmpty
            {
                connection.verifiedPresentBeforeTargetBinding = true
            }
            if targetWasUnbound,
               reviewableCandidate,
               candidateTargetAbsenceBaselineEstablished,
               !connection.verifiedPresentBeforeTargetBinding
            {
                connection.cycleEligible = true
            }
            if isNewConnection,
               candidateTargetDiskOrdinal == diskOrdinal
            {
                connection.cycleEligible =
                    candidateTargetAbsenceBaselineEstablished
            }
            if candidateTargetDiskOrdinal == diskOrdinal,
               observation.issues.isEmpty,
               connection.cycleEligible,
               connection.firstReviewableSequence == nil,
               observation.issues.isEmpty,
               !reviewableCandidate
            {
                failureCodes.insert(.targetCycleEvidenceInterrupted)
                throw Gate1EvidenceRecorderError.targetCycleEvidenceInterrupted
            }
            if candidateTargetDiskOrdinal == diskOrdinal,
               observation.issues.isEmpty
            {
                if connection.cycleEligible,
                   connection.firstReviewableSequence == nil,
                   reviewableCandidate
                {
                    connection.firstReviewableSequence = sequence
                    connection.remainedReviewableSinceStart = true
                } else if connection.firstReviewableSequence != nil,
                          !reviewableCandidate
                {
                    failureCodes.insert(.targetCycleEvidenceInterrupted)
                    throw Gate1EvidenceRecorderError.targetCycleEvidenceInterrupted
                }
                if reviewableCandidate {
                    connection.reviewableCandidateVolumeOrdinals.formUnion(
                        candidateVolumeOrdinals
                    )
                    connection.sawReviewableMultiPartition =
                        connection.sawReviewableMultiPartition
                            || reviewableMultiPartition
                }
            }
            candidateConnections[physicalDiskID] = connection
            frames.append(
                Gate1EvidenceDiskFrame(
                    diskOrdinal: diskOrdinal,
                    connectionOrdinal: connection.connectionOrdinal,
                    mediaGenerationRelation: generationRelation,
                    volumeOrdinals: volumeOrdinals,
                    candidateVolumeOrdinals: candidateVolumeOrdinals,
                    mutationSnapshotVolumeOrdinals: mutationSnapshotVolumeOrdinals,
                    unverifiedVolumeOrdinals: unverifiedVolumeOrdinals,
                    issueCodes: issueCodes
                )
            )
        }
        frames.sort { $0.diskOrdinal < $1.diskOrdinal }
        var confirmedAbsentDiskOrdinals: [UInt32] = []
        if observation.issues.isEmpty {
            let presentPhysicalDiskIDs = Set(
                observation.physicalDisks.map(\.instanceID.physicalDiskID)
            )
            for physicalDiskID in candidateConnections.keys.sorted(by: {
                $0.rawValue < $1.rawValue
            }) where !presentPhysicalDiskIDs.contains(physicalDiskID) {
                guard let removed = candidateConnections.removeValue(
                    forKey: physicalDiskID
                ) else {
                    continue
                }
                candidateLastGenerations[physicalDiskID] = removed.mediaGeneration
                confirmedAbsentDiskOrdinals.append(removed.diskOrdinal)
                if removed.diskOrdinal == candidateTargetDiskOrdinal,
                   let startSequence = removed.firstReviewableSequence,
                   removed.remainedReviewableSinceStart
                {
                    guard candidateCompletedCycleCount < UInt16.max else {
                        throw Gate1EvidenceRecorderError.countOutOfRange
                    }
                    candidateCompletedCycleCount += 1
                    candidateCycleIntervals.append(
                        Gate1EvidenceCycleInterval(
                            roundOrdinal: candidateCompletedCycleCount,
                            startSequence: startSequence,
                            endSequence: sequence
                        )
                    )
                    candidateMultiPartitionObservationPresent =
                        candidateMultiPartitionObservationPresent
                            || removed.sawReviewableMultiPartition
                }
            }
        }
        let frame = Gate1EvidenceObservationFrame(
            sequence: sequence,
            occurredAt: timestamp,
            coverage: observation.issues.isEmpty ? .verified : .unverified,
            coordinatorInventoryPresent: observation.coordinatorInventory != nil,
            disks: frames,
            confirmedAbsentDiskOrdinals: confirmedAbsentDiskOrdinals.sorted(),
            issueCodes: Self.normalizedIssueCodes(
                observation.issues.map(Self.issueCode)
            )
        )
        if frame.coverage == .verified {
            if let candidateTargetDiskOrdinal {
                if !frame.disks.contains(where: {
                    $0.diskOrdinal == candidateTargetDiskOrdinal
                }) {
                    candidateTargetAbsenceBaselineEstablished = true
                }
            } else if !frame.disks.contains(where: {
                Gate1EvidenceRules.isReviewableCandidateDisk($0, in: frame)
            }) {
                candidateTargetAbsenceBaselineEstablished = true
            }
        }
        let candidateLatestObservationPermitsComparison =
            candidateTargetDiskOrdinal.flatMap { target in
                frame.disks.first { $0.diskOrdinal == target }
            }.map { targetFrame in
                Gate1EvidenceRules.isReviewableCandidateDisk(
                    targetFrame,
                    in: frame
                )
            } ?? false
        var candidateObservations = observations
        candidateObservations.append(frame)
        guard try fitsEncodedBudget(
            observations: candidateObservations,
            checkpoints: checkpoints,
            completedCycleCount: candidateCompletedCycleCount,
            targetDiskOrdinal: candidateTargetDiskOrdinal,
            activeConnections: candidateConnections,
            completedCycleIntervals: candidateCycleIntervals,
            multiPartitionObservationPresent:
                candidateMultiPartitionObservationPresent
        ) else {
            failureCodes.insert(.encodedByteLimitExceeded)
            throw Gate1EvidenceRecorderError.encodedByteLimitExceeded
        }
        diskOrdinals = candidateOrdinals
        nextDiskOrdinal = candidateNextDiskOrdinal
        activeConnections = candidateConnections
        lastConfirmedGenerations = candidateLastGenerations
        nextConnectionOrdinal = candidateNextConnectionOrdinal
        completedCycleCount = candidateCompletedCycleCount
        targetDiskOrdinal = candidateTargetDiskOrdinal
        targetCandidateVolumeUUIDs = candidateTargetVolumeUUIDs
        targetAbsenceBaselineEstablished =
            candidateTargetAbsenceBaselineEstablished
        completedCycleIntervals = candidateCycleIntervals
        multiPartitionObservationPresent =
            candidateMultiPartitionObservationPresent
        latestObservationPermitsComparison =
            candidateLatestObservationPermitsComparison
        observations = candidateObservations
        lastTimestamp = timestamp
    }

    public func record(
        _ checkpoint: Gate1OperatorCheckpoint
    ) throws {
        try record(checkpoint, at: clock.now())
    }

    public func record(
        _ checkpoint: Gate1OperatorCheckpoint,
        at timestamp: GateEvidenceTimestamp
    ) throws {
        guard sealedArtifact == nil else {
            throw Gate1EvidenceRecorderError.sealed
        }
        guard failureCodes.isEmpty else {
            throw Gate1EvidenceRecorderError.failedClosed
        }
        try validateTimestamp(timestamp)
        guard checkpoints.count < policy.maxCheckpoints else {
            failureCodes.insert(.checkpointLimitExceeded)
            throw Gate1EvidenceRecorderError.checkpointLimitExceeded
        }
        let requiresRound = checkpoint.kind == .systemInventoryComparison
            || checkpoint.kind == .mountTableComparison
        if requiresRound {
            guard let roundOrdinal = checkpoint.roundOrdinal,
                  (1 ... Self.requiredCycleCount).contains(roundOrdinal)
            else {
                failureCodes.insert(.invalidCheckpoint)
                throw Gate1EvidenceRecorderError.invalidCheckpoint
            }
            guard completedCycleCount < Self.requiredCycleCount,
                  roundOrdinal == completedCycleCount + 1,
                  let targetDiskOrdinal,
                  latestObservationPermitsComparison,
                  let targetConnection = activeConnections.values.first(where: {
                      $0.diskOrdinal == targetDiskOrdinal
                  }),
                  targetConnection.firstReviewableSequence != nil,
                  targetConnection.remainedReviewableSinceStart
            else {
                failureCodes.insert(.invalidCheckpoint)
                throw Gate1EvidenceRecorderError.invalidCheckpoint
            }
        } else if checkpoint.roundOrdinal != nil {
            failureCodes.insert(.invalidCheckpoint)
            throw Gate1EvidenceRecorderError.invalidCheckpoint
        }
        let checkpointKey = Gate1EvidenceCheckpointKey(
            kind: checkpoint.kind,
            roundOrdinal: checkpoint.roundOrdinal
        )
        guard !checkpoints.contains(where: {
            Gate1EvidenceCheckpointKey(
                kind: $0.kind,
                roundOrdinal: $0.roundOrdinal
            ) == checkpointKey
        }) else {
            failureCodes.insert(.invalidCheckpoint)
            throw Gate1EvidenceRecorderError.invalidCheckpoint
        }
        let candidateCheckpoint = Gate1EvidenceCheckpoint(
            sequence: try nextEventSequence(),
            occurredAt: timestamp,
            kind: checkpoint.kind,
            roundOrdinal: checkpoint.roundOrdinal,
            finding: checkpoint.finding
        )
        var candidateCheckpoints = checkpoints
        candidateCheckpoints.append(candidateCheckpoint)
        guard try fitsEncodedBudget(
            observations: observations,
            checkpoints: candidateCheckpoints,
            completedCycleCount: completedCycleCount,
            targetDiskOrdinal: targetDiskOrdinal,
            activeConnections: activeConnections,
            completedCycleIntervals: completedCycleIntervals,
            multiPartitionObservationPresent:
                multiPartitionObservationPresent
        ) else {
            failureCodes.insert(.encodedByteLimitExceeded)
            throw Gate1EvidenceRecorderError.encodedByteLimitExceeded
        }
        checkpoints = candidateCheckpoints
        if checkpoint.finding == .contradicted {
            failureCodes.insert(.checkpointContradicted)
        }
        lastTimestamp = timestamp
    }

    public func seal(
    ) throws -> Gate1EvidenceArtifact {
        try seal(at: clock.now())
    }

    public func failClosed(
        _ sourceFailure: Gate1EvidenceSourceFailure
    ) throws {
        try failClosed(sourceFailure, at: clock.now())
    }

    public func failClosed(
        _ sourceFailure: Gate1EvidenceSourceFailure,
        at timestamp: GateEvidenceTimestamp
    ) throws {
        guard sealedArtifact == nil else {
            throw Gate1EvidenceRecorderError.sealed
        }
        guard failureCodes.isEmpty else {
            throw Gate1EvidenceRecorderError.failedClosed
        }
        try validateTimestamp(timestamp)
        switch sourceFailure {
        case .eventQueueOverflow:
            failureCodes.insert(.eventQueueOverflow)
        case .finalObservationUnverified:
            failureCodes.insert(.finalObservationUnverified)
        case .observationStreamEnded:
            failureCodes.insert(.observationStreamEnded)
        case .unclassifiedObservationFailure:
            failureCodes.insert(.unclassifiedObservationFailure)
        case .unclassifiedOperatorFailure:
            failureCodes.insert(.unclassifiedOperatorFailure)
        }
        lastTimestamp = timestamp
    }

    public func seal(
        at timestamp: GateEvidenceTimestamp
    ) throws -> Gate1EvidenceArtifact {
        if let sealedArtifact {
            return sealedArtifact
        }
        try validateTimestamp(timestamp)
        var bundle = try Self.makeBundle(
            header: header,
            sealedAt: timestamp,
            completedCycleCount: completedCycleCount,
            targetDiskOrdinal: targetDiskOrdinal,
            openConnectionCount: Self.openTargetConnectionCount(
                targetDiskOrdinal: targetDiskOrdinal,
                activeConnections: activeConnections
            ),
            cycleIntervals: Self.cycleIntervalsIncludingOpenTarget(
                completedCycleCount: completedCycleCount,
                targetDiskOrdinal: targetDiskOrdinal,
                activeConnections: activeConnections,
                completedCycleIntervals: completedCycleIntervals
            ),
            multiPartitionObservationPresent:
                multiPartitionObservationPresent,
            observations: observations,
            checkpoints: checkpoints,
            failureCodes: failureCodes
        )
        var canonicalJSON = try bundle.encodedCanonicalJSON()
        if canonicalJSON.count > policy.maxEncodedBytes {
            failureCodes.insert(.encodedByteLimitExceeded)
            bundle = try Self.makeBundle(
                header: header,
                sealedAt: timestamp,
                completedCycleCount: completedCycleCount,
                targetDiskOrdinal: targetDiskOrdinal,
                openConnectionCount: Self.openTargetConnectionCount(
                    targetDiskOrdinal: targetDiskOrdinal,
                    activeConnections: activeConnections
                ),
                cycleIntervals: Self.cycleIntervalsIncludingOpenTarget(
                    completedCycleCount: completedCycleCount,
                    targetDiskOrdinal: targetDiskOrdinal,
                    activeConnections: activeConnections,
                    completedCycleIntervals: completedCycleIntervals
                ),
                multiPartitionObservationPresent:
                    multiPartitionObservationPresent,
                observations: observations,
                checkpoints: checkpoints,
                failureCodes: failureCodes
            )
            canonicalJSON = try bundle.encodedCanonicalJSON()
            guard canonicalJSON.count <= policy.maxEncodedBytes else {
                throw Gate1EvidenceRecorderError.encodedByteLimitExceeded
            }
        }
        let artifact = Gate1EvidenceArtifact(bundle: bundle, canonicalJSON: canonicalJSON)
        sealedArtifact = artifact
        return artifact
    }

    private func nextEventSequence() throws -> UInt64 {
        guard observations.count <= Int.max - checkpoints.count else {
            throw Gate1EvidenceRecorderError.countOutOfRange
        }
        let eventCount = observations.count + checkpoints.count
        guard eventCount < Int.max else {
            throw Gate1EvidenceRecorderError.countOutOfRange
        }
        return UInt64(eventCount) + 1
    }

    private func fitsEncodedBudget(
        observations: [Gate1EvidenceObservationFrame],
        checkpoints: [Gate1EvidenceCheckpoint],
        completedCycleCount: UInt16,
        targetDiskOrdinal: UInt32?,
        activeConnections: [PhysicalDiskID: ActiveConnection],
        completedCycleIntervals: [Gate1EvidenceCycleInterval],
        multiPartitionObservationPresent: Bool
    ) throws -> Bool {
        let reservedFailureCodes = Set(Gate1EvidenceFailureCode.allCases)
            .union(failureCodes)
        let reservedBundle = try Self.makeBundle(
            header: header,
            sealedAt: GateEvidenceTimestamp(
                millisecondsSince1970: Int64.max
            ),
            completedCycleCount: completedCycleCount,
            targetDiskOrdinal: targetDiskOrdinal,
            openConnectionCount: Self.openTargetConnectionCount(
                targetDiskOrdinal: targetDiskOrdinal,
                activeConnections: activeConnections
            ),
            cycleIntervals: Self.cycleIntervalsIncludingOpenTarget(
                completedCycleCount: completedCycleCount,
                targetDiskOrdinal: targetDiskOrdinal,
                activeConnections: activeConnections,
                completedCycleIntervals: completedCycleIntervals
            ),
            multiPartitionObservationPresent:
                multiPartitionObservationPresent,
            observations: observations,
            checkpoints: checkpoints,
            failureCodes: reservedFailureCodes
        )
        return try reservedBundle.encodedCanonicalJSON().count
            <= policy.maxEncodedBytes
    }

    private static func makeBundle(
        header: Gate1EvidenceHeader,
        sealedAt: GateEvidenceTimestamp,
        completedCycleCount: UInt16,
        targetDiskOrdinal: UInt32?,
        openConnectionCount: UInt32,
        cycleIntervals: [Gate1EvidenceCycleInterval],
        multiPartitionObservationPresent: Bool,
        observations: [Gate1EvidenceObservationFrame],
        checkpoints: [Gate1EvidenceCheckpoint],
        failureCodes: Set<Gate1EvidenceFailureCode>
    ) throws -> Gate1EvidenceBundle {
        let sortedFailureCodes = failureCodes.sorted { $0.rawValue < $1.rawValue }
        let checkpointRequirementMet = Gate1EvidenceRules.checkpointsAreValid(
            checkpoints,
            cycleIntervals: cycleIntervals,
            observations: observations,
            targetDiskOrdinal: targetDiskOrdinal
        ) && Gate1EvidenceRules.checkpointRequirementMet(
            checkpoints,
            cycleIntervals: cycleIntervals
        )
        let cycleRequirementMet = completedCycleCount >= requiredCycleCount
        let verdict = Gate1EvidenceRules.verdict(
            failureCodes: sortedFailureCodes,
            cycleRequirementMet: cycleRequirementMet,
            checkpointRequirementMet: checkpointRequirementMet,
            multiPartitionObservationPresent: multiPartitionObservationPresent,
            finalObservationVerified:
                observations.last?.coverage == .verified,
            openConnectionCount: openConnectionCount
        )
        return Gate1EvidenceBundle(
            header: header,
            sealedAt: sealedAt,
            verdict: verdict,
            requiredCycleCount: requiredCycleCount,
            completedCycleCount: completedCycleCount,
            checkpointRequirementMet: checkpointRequirementMet,
            multiPartitionObservationPresent: multiPartitionObservationPresent,
            targetDiskOrdinal: targetDiskOrdinal,
            openConnectionCount: openConnectionCount,
            observations: observations,
            checkpoints: checkpoints,
            failureCodes: sortedFailureCodes
        )
    }

    private static func openTargetConnectionCount(
        targetDiskOrdinal: UInt32?,
        activeConnections: [PhysicalDiskID: ActiveConnection]
    ) -> UInt32 {
        targetDiskOrdinal.flatMap { target in
            activeConnections.values.first { $0.diskOrdinal == target }
        } == nil ? 0 : 1
    }

    private static func cycleIntervalsIncludingOpenTarget(
        completedCycleCount: UInt16,
        targetDiskOrdinal: UInt32?,
        activeConnections: [PhysicalDiskID: ActiveConnection],
        completedCycleIntervals: [Gate1EvidenceCycleInterval]
    ) -> [Gate1EvidenceCycleInterval] {
        guard completedCycleCount < UInt16.max,
              let targetDiskOrdinal,
              let active = activeConnections.values.first(where: {
                  $0.diskOrdinal == targetDiskOrdinal
              }),
              let startSequence = active.firstReviewableSequence,
              active.remainedReviewableSinceStart
        else {
            return completedCycleIntervals
        }
        return completedCycleIntervals + [
            Gate1EvidenceCycleInterval(
                roundOrdinal: completedCycleCount + 1,
                startSequence: startSequence,
                endSequence: nil
            ),
        ]
    }

    private func validateTimestamp(_ timestamp: GateEvidenceTimestamp) throws {
        guard timestamp.millisecondsSince1970 >= 0 else {
            failureCodes.insert(.invalidTimestamp)
            throw Gate1EvidenceRecorderError.invalidTimestamp
        }
        if let lastTimestamp, timestamp < lastTimestamp {
            failureCodes.insert(.nonMonotonicTimestamp)
            throw Gate1EvidenceRecorderError.nonMonotonicTimestamp
        }
    }

    private static func projectedVolumes(
        _ volumes: [ReadOnlyVolumeRecord],
        for diskInstanceID: DiskInstanceID
    ) -> [ProjectedVolume]? {
        var projected: [ProjectedVolume] = []
        projected.reserveCapacity(volumes.count)
        for volume in volumes {
            guard volume.candidate == nil || volume.snapshot == nil else {
                return nil
            }
            let instanceID = volume.candidate?.instanceID
                ?? volume.snapshot?.instanceID
            let key: VolumeEvidenceKey?
            if let instanceID {
                guard instanceID.diskInstanceID == diskInstanceID else {
                    return nil
                }
                guard let canonicalInstanceUUID = canonicalVolumeUUID(
                    instanceID.volumeID.uuid
                ) else {
                    return nil
                }
                if let evidenceBSDName = volume.evidence.bsdName,
                   evidenceBSDName != instanceID.volumeID.bsdName
                {
                    return nil
                }
                if let evidenceUUID = volume.evidence.volumeUUID,
                   canonicalVolumeUUID(evidenceUUID) != canonicalInstanceUUID
                {
                    return nil
                }
                key = VolumeEvidenceKey(
                    volumeUUID: canonicalInstanceUUID,
                    bsdName: instanceID.volumeID.bsdName
                )
            } else if let volumeUUID = volume.evidence.volumeUUID,
                      !volumeUUID.isEmpty,
                      let bsdName = volume.evidence.bsdName,
                      !bsdName.isEmpty
            {
                if let physicalDiskBSDName =
                    volume.evidence.physicalDiskBSDName,
                   physicalDiskBSDName != diskInstanceID.physicalDiskID.rawValue
                {
                    return nil
                }
                key = VolumeEvidenceKey(
                    volumeUUID: canonicalVolumeUUID(volumeUUID) ?? volumeUUID,
                    bsdName: bsdName
                )
            } else {
                key = nil
            }
            projected.append(
                ProjectedVolume(
                    key: key,
                    candidatePresent: volume.candidate != nil,
                    mutationSnapshotPresent: volume.snapshot != nil
                )
            )
        }
        return projected
    }

    private static func canonicalVolumeUUID(_ value: String) -> String? {
        UUID(uuidString: value)?.uuidString.lowercased()
    }

    private static func isReviewableCandidateDisk(
        observation: DiskInventoryObservation,
        candidateVolumeOrdinals: [UInt32],
        mutationSnapshotVolumeOrdinals: [UInt32],
        unverifiedVolumeOrdinals: [UInt32],
        issueCodes: [Gate1EvidenceIssueCode]
    ) -> Bool {
        observation.issues.isEmpty
            && !candidateVolumeOrdinals.isEmpty
            && mutationSnapshotVolumeOrdinals.isEmpty
            && unverifiedVolumeOrdinals.isEmpty
            && observation.coordinatorInventory == nil
            && issueCodes.contains(.unknownVolumeRole)
            && issueCodes.allSatisfy { $0 == .unknownVolumeRole }
    }

    private static func generationRelation(
        previous: MediaGeneration?,
        current: MediaGeneration
    ) -> Gate1MediaGenerationRelation {
        guard current.rawValue > 0 else {
            return .unknown
        }
        guard let previous else {
            return .first
        }
        if current.rawValue > previous.rawValue {
            return .advanced
        }
        if current.rawValue == previous.rawValue {
            return .reusedWithoutAdvance
        }
        return .regressed
    }

    private static func normalizedIssueCodes(
        _ codes: [Gate1EvidenceIssueCode]
    ) -> [Gate1EvidenceIssueCode] {
        Array(Set(codes)).sorted { $0.rawValue < $1.rawValue }
    }

    private static func issueCode(
        _ issue: DiskInventoryIssue
    ) -> Gate1EvidenceIssueCode {
        switch issue {
        case .initialEnumerationPending:
            .initialEnumerationPending
        case .enumerationCoverageUnverified:
            .enumerationCoverageUnverified
        case .eventSourceUnavailable:
            .eventSourceUnavailable
        case .unidentifiedDiskEvent:
            .unidentifiedDiskEvent
        case .mountTableReadFailed:
            .mountTableReadFailed
        case .missingPhysicalDiskDescription:
            .missingPhysicalDiskDescription
        case .unknownDiskKind:
            .unknownDiskKind
        case .physicalParentMismatch:
            .physicalParentMismatch
        case .missingPhysicalLocation:
            .missingPhysicalLocation
        case .missingEjectability:
            .missingEjectability
        case .missingRemovability:
            .missingRemovability
        case .contradictoryEjectability:
            .contradictoryEjectability
        case .childLocationMismatch:
            .childLocationMismatch
        case .duplicateMountTableEntry:
            .duplicateMountTableEntry
        }
    }

    private static func issueCode(
        _ issue: ReadOnlyObservationIssue
    ) -> Gate1EvidenceIssueCode {
        switch issue {
        case .missingBSDName:
            .missingBSDName
        case .invalidBSDName:
            .invalidBSDName
        case .missingVolumeUUID:
            .missingVolumeUUID
        case .invalidVolumeUUID:
            .invalidVolumeUUID
        case .missingPhysicalDiskBSDName:
            .missingPhysicalDiskBSDName
        case .invalidPhysicalDiskBSDName:
            .invalidPhysicalDiskBSDName
        case .invalidMediaGeneration:
            .invalidMediaGeneration
        case .missingDisplayName:
            .missingDisplayName
        case .missingFileSystemName:
            .missingFileSystemName
        case .missingLocation:
            .missingLocation
        case .unknownVolumeRole:
            .unknownVolumeRole
        case .conflictingVolumeRole:
            .conflictingVolumeRole
        case .missingMountTableEntry:
            .missingMountTableEntry
        case .mountTableReadFailed:
            .mountTableReadFailed
        case .duplicateMountTableEntry:
            .duplicateMountTableEntry
        case .unexpectedMountTableEntry:
            .unexpectedMountTableEntry
        case .incompleteMountTableEntry:
            .incompleteMountTableEntry
        case .mountAccessMismatch:
            .mountAccessMismatch
        case .sourceDeviceMismatch:
            .sourceDeviceMismatch
        case .mountPointMismatch:
            .mountPointMismatch
        case .nonCanonicalMountPoint:
            .nonCanonicalMountPoint
        case .symbolicLinkMountPoint:
            .symbolicLinkMountPoint
        }
    }
}
