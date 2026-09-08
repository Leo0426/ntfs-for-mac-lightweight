import Foundation

public struct DiagnosticTimestamp: Codable, Equatable, Comparable, Sendable {
    public let millisecondsSince1970: Int64

    public init(millisecondsSince1970: Int64) {
        self.millisecondsSince1970 = millisecondsSince1970
    }

    init(date: Date) {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        if !milliseconds.isFinite {
            self.millisecondsSince1970 = 0
        } else if milliseconds >= Double(Int64.max) {
            self.millisecondsSince1970 = Int64.max
        } else if milliseconds <= Double(Int64.min) {
            self.millisecondsSince1970 = Int64.min
        } else {
            self.millisecondsSince1970 = Int64(milliseconds.rounded(.towardZero))
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.millisecondsSince1970 = try container.decode(Int64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(millisecondsSince1970)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.millisecondsSince1970 < rhs.millisecondsSince1970
    }
}

public struct DiagnosticVersion: Codable, Equatable, Sendable {
    public let major: UInt32
    public let minor: UInt32
    public let patch: UInt32

    public init(major: UInt32, minor: UInt32, patch: UInt32) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
}

public enum DiagnosticArchitecture: String, Codable, Equatable, Sendable {
    case appleSilicon
    case intel
    case unknown
}

public enum DiagnosticBackend: String, Codable, Equatable, Sendable {
    case fsKit
    case kernelExtension
    case unknown
}

public enum DiagnosticFileSystem: String, Codable, Equatable, Sendable {
    case ntfs
    case other
    case unknown
}

public enum DiagnosticVolumeLocation: String, Codable, Equatable, Sendable {
    case external
    case `internal`
    case unknown
}

public enum DiagnosticVolumeRole: String, Codable, Equatable, Sendable {
    case data
    case protected
    case bootCamp
    case unknown
}

public enum DiagnosticVolumeHealth: String, Codable, Equatable, Sendable {
    case clean
    case dirty
    case hibernated
    case unknown
}

public enum DiagnosticMountAccess: String, Codable, Equatable, Sendable {
    case unmounted
    case readOnly
    case readWrite
    case unknown
}

public enum DiagnosticSetupIssueCode: String, Codable, CaseIterable, Hashable, Sendable {
    case unsupportedOperatingSystem
    case unsupportedArchitecture
    case macFUSEMissing
    case macFUSETooOld
    case fileSystemExtensionDisabled
    case ntfs3GMissing
    case ntfs3GTooOld
    case unsafeBackend
    case requiredAuthorizationUnavailable
    case conflictScanIncomplete
    case conflictingDrivers
}

public struct DiagnosticSetupEvent: Codable, Equatable, Sendable {
    public let applicationVersion: DiagnosticVersion
    public let applicationBuild: UInt32
    public let macOSVersion: DiagnosticVersion
    public let architecture: DiagnosticArchitecture
    public let macFUSEVersion: DiagnosticVersion?
    public let ntfs3GVersion: DiagnosticVersion?
    public let fileSystemExtensionEnabled: Bool
    public let selectedBackend: DiagnosticBackend
    public let issueCodes: [DiagnosticSetupIssueCode]
    public let conflictingDriverCount: UInt32

    public init(
        applicationVersion: DiagnosticVersion,
        applicationBuild: UInt32,
        macOSVersion: DiagnosticVersion,
        architecture: DiagnosticArchitecture,
        macFUSEVersion: DiagnosticVersion?,
        ntfs3GVersion: DiagnosticVersion?,
        fileSystemExtensionEnabled: Bool,
        selectedBackend: DiagnosticBackend,
        issueCodes: [DiagnosticSetupIssueCode],
        conflictingDriverCount: UInt32
    ) {
        self.applicationVersion = applicationVersion
        self.applicationBuild = applicationBuild
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.macFUSEVersion = macFUSEVersion
        self.ntfs3GVersion = ntfs3GVersion
        self.fileSystemExtensionEnabled = fileSystemExtensionEnabled
        self.selectedBackend = selectedBackend
        self.issueCodes = normalized(issueCodes)
        self.conflictingDriverCount = conflictingDriverCount
    }
}

public enum DiagnosticInventoryIssueCode: String, Codable, CaseIterable, Hashable, Sendable {
    case initialEnumerationPending
    case enumerationCoverageUnverified
    case eventSourceUnavailable
    case unidentifiedDiskEvent
    case mountTableReadFailed
    case missingPhysicalDiskDescription
    case unknownDiskKind
    case physicalParentMismatch
    case missingPhysicalLocation
    case missingEjectability
    case missingRemovability
    case contradictoryEjectability
    case childLocationMismatch
    case duplicateMountTableEntry
    case missingBSDName
    case invalidBSDName
    case missingVolumeUUID
    case invalidVolumeUUID
    case missingPhysicalDiskBSDName
    case invalidPhysicalDiskBSDName
    case invalidMediaGeneration
    case missingDisplayName
    case missingFileSystemName
    case missingLocation
    case unknownVolumeRole
    case conflictingVolumeRole
    case missingMountTableEntry
    case unexpectedMountTableEntry
    case incompleteMountTableEntry
    case mountAccessMismatch
    case sourceDeviceMismatch
    case mountPointMismatch
    case nonCanonicalMountPoint
    case symbolicLinkMountPoint
}

public struct DiagnosticInventoryEvent: Codable, Equatable, Sendable {
    public let isComplete: Bool
    public let physicalDiskCount: UInt32
    public let volumeCount: UInt32
    public let issueCodes: [DiagnosticInventoryIssueCode]

    public init(
        isComplete: Bool,
        physicalDiskCount: UInt32,
        volumeCount: UInt32,
        issueCodes: [DiagnosticInventoryIssueCode]
    ) {
        self.isComplete = isComplete
        self.physicalDiskCount = physicalDiskCount
        self.volumeCount = volumeCount
        self.issueCodes = normalized(issueCodes)
    }
}

public enum DiagnosticTargetKind: String, Codable, Equatable, Sendable {
    case disk
    case volume
}

public struct DiagnosticTarget: Codable, Equatable, Hashable, Sendable {
    public let runID: UUID
    public let kind: DiagnosticTargetKind
    public let diskOrdinal: UInt32
    public let volumeOrdinal: UInt32?
    public let mediaGeneration: UInt64

    init(
        runID: UUID,
        kind: DiagnosticTargetKind,
        diskOrdinal: UInt32,
        volumeOrdinal: UInt32?,
        mediaGeneration: UInt64
    ) {
        self.runID = runID
        self.kind = kind
        self.diskOrdinal = diskOrdinal
        self.volumeOrdinal = volumeOrdinal
        self.mediaGeneration = mediaGeneration
    }
}

public enum DiagnosticVolumeStateCode: String, Codable, Equatable, Sendable {
    case readOnlyReady
    case unmountedReady
    case existingWriteMountUnverified
    case unmountingForWrite
    case awaitingSafetySnapshot
    case mountingWrite
    case awaitingWriteVerification
    case writable
    case writeVerificationFailed
    case unmountingForEject
    case awaitingUnmountVerification
    case ejecting
    case awaitingRemovalVerification
    case safeToRemove
    case ejectFailed
    case ejectBlocked
    case writeBlocked
    case mediaInvalidated
    case mediaUnavailable
    case writeMutationQuiescencePending
    case awaitingWriteMutationReconciliation
    case ejectMutationQuiescencePending
    case awaitingEjectMutationReconciliation
    case writeOperationFailed
}

public enum DiagnosticReasonCode: String, Codable, Equatable, Sendable {
    case windowsHibernated
    case dirtyFileSystem
    case healthUnknown
    case internalVolume
    case bootCampVolume
    case protectedVolume
    case unsupportedFileSystem
    case internalDisk
    case bootCampDisk
    case protectedDisk
    case protectedSibling
    case wrongVolume
    case observationIncomplete
    case sourceDeviceMismatch
    case notReadWrite
    case unexpectedBackend
    case invalidMountPoint
    case untrustedMountPath
    case busy
    case volumesStillMounted
    case diskStillPresent
    case permissionDenied
    case dependencyUnavailable
    case engineFailed
    case inspectionUnavailable
    case timedOut
    case cancelled
    case mediaChanged
}

public struct DiagnosticVolumeEvent: Codable, Equatable, Sendable {
    public let target: DiagnosticTarget
    public let fileSystem: DiagnosticFileSystem
    public let location: DiagnosticVolumeLocation
    public let role: DiagnosticVolumeRole
    public let health: DiagnosticVolumeHealth
    public let mountAccess: DiagnosticMountAccess
    public let backend: DiagnosticBackend
    public let state: DiagnosticVolumeStateCode
    public let reason: DiagnosticReasonCode?
    public let observationComplete: Bool
    public let isCanonicalMountPoint: Bool
    public let isSymbolicLinkMountPoint: Bool

    public init(
        target: DiagnosticTarget,
        fileSystem: DiagnosticFileSystem,
        location: DiagnosticVolumeLocation,
        role: DiagnosticVolumeRole,
        health: DiagnosticVolumeHealth,
        mountAccess: DiagnosticMountAccess,
        backend: DiagnosticBackend,
        state: DiagnosticVolumeStateCode,
        reason: DiagnosticReasonCode?,
        observationComplete: Bool,
        isCanonicalMountPoint: Bool,
        isSymbolicLinkMountPoint: Bool
    ) {
        self.target = target
        self.fileSystem = fileSystem
        self.location = location
        self.role = role
        self.health = health
        self.mountAccess = mountAccess
        self.backend = backend
        self.state = state
        self.reason = reason
        self.observationComplete = observationComplete
        self.isCanonicalMountPoint = isCanonicalMountPoint
        self.isSymbolicLinkMountPoint = isSymbolicLinkMountPoint
    }
}

public enum DiagnosticOperationKind: String, Codable, Equatable, Sendable {
    case enableWriting
    case safeEject
}

public enum DiagnosticOperationStage: String, Codable, Equatable, Sendable {
    case unmountReadOnly
    case inspectSafety
    case mountWrite
    case inspectWriteMount
    case unmountPhysicalDisk
    case inspectPhysicalDiskAfterUnmount
    case ejectPhysicalDisk
    case inspectPhysicalDiskAfterEject
    case waitForProcessExit
    case reconcile
}

public enum DiagnosticResultCode: String, Codable, Equatable, Sendable {
    case succeeded
    case rejected
    case busy
    case permissionDenied
    case dependencyUnavailable
    case engineFailed
    case inspectionUnavailable
    case timedOut
    case cancelled
    case observationIncomplete
    case targetChanged
    case mediaUnavailable
    case unsafeState
    case stillMounted
    case stillPresent
}

public enum DiagnosticExitKind: String, Codable, Equatable, Sendable {
    case exited
    case signaled
    case launchFailed
}

public struct DiagnosticExitStatus: Codable, Equatable, Sendable {
    public let kind: DiagnosticExitKind
    public let code: Int32?

    private init(kind: DiagnosticExitKind, code: Int32?) {
        self.kind = kind
        self.code = code
    }

    public static func exited(code: Int32) -> Self {
        Self(kind: .exited, code: code)
    }

    public static func signaled(signal: Int32) -> Self {
        Self(kind: .signaled, code: signal)
    }

    public static let launchFailed = Self(kind: .launchFailed, code: nil)
}

public struct DiagnosticOperationEvent: Codable, Equatable, Sendable {
    public let target: DiagnosticTarget
    public let kind: DiagnosticOperationKind
    public let stage: DiagnosticOperationStage
    public let result: DiagnosticResultCode
    public let exitStatus: DiagnosticExitStatus?
    public let elapsedMilliseconds: UInt64

    public init(
        target: DiagnosticTarget,
        kind: DiagnosticOperationKind,
        stage: DiagnosticOperationStage,
        result: DiagnosticResultCode,
        exitStatus: DiagnosticExitStatus?,
        elapsedMilliseconds: UInt64
    ) {
        self.target = target
        self.kind = kind
        self.stage = stage
        self.result = result
        self.exitStatus = exitStatus
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public enum DiagnosticInput: Equatable, Sendable {
    case setup(DiagnosticSetupEvent)
    case inventory(DiagnosticInventoryEvent)
    case volume(DiagnosticVolumeEvent)
    case operation(DiagnosticOperationEvent)

    var target: DiagnosticTarget? {
        switch self {
        case .setup, .inventory:
            nil
        case let .volume(event):
            event.target
        case let .operation(event):
            event.target
        }
    }

    var requiresVolumeTarget: Bool {
        if case .volume = self {
            return true
        }
        return false
    }
}

extension DiagnosticInput: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    private enum Kind: String, Codable {
        case setup
        case inventory
        case volume
        case operation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .setup:
            self = .setup(try container.decode(DiagnosticSetupEvent.self, forKey: .payload))
        case .inventory:
            self = .inventory(
                try container.decode(DiagnosticInventoryEvent.self, forKey: .payload)
            )
        case .volume:
            self = .volume(try container.decode(DiagnosticVolumeEvent.self, forKey: .payload))
        case .operation:
            self = .operation(
                try container.decode(DiagnosticOperationEvent.self, forKey: .payload)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .setup(event):
            try container.encode(Kind.setup, forKey: .kind)
            try container.encode(event, forKey: .payload)
        case let .inventory(event):
            try container.encode(Kind.inventory, forKey: .kind)
            try container.encode(event, forKey: .payload)
        case let .volume(event):
            try container.encode(Kind.volume, forKey: .kind)
            try container.encode(event, forKey: .payload)
        case let .operation(event):
            try container.encode(Kind.operation, forKey: .kind)
            try container.encode(event, forKey: .payload)
        }
    }
}

public struct DiagnosticEntry: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let occurredAt: DiagnosticTimestamp
    public let event: DiagnosticInput

    init(sequence: UInt64, occurredAt: DiagnosticTimestamp, event: DiagnosticInput) {
        self.sequence = sequence
        self.occurredAt = occurredAt
        self.event = event
    }
}

public struct DiagnosticSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let runID: UUID
    public let generatedAt: DiagnosticTimestamp
    public let entries: [DiagnosticEntry]

    init(runID: UUID, generatedAt: DiagnosticTimestamp, entries: [DiagnosticEntry]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.runID = runID
        self.generatedAt = generatedAt
        self.entries = entries
    }

    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public func copyText() throws -> String {
        String(decoding: try encodedJSON(), as: UTF8.self)
    }
}

private func normalized<Code>(_ codes: [Code]) -> [Code]
where Code: Hashable & RawRepresentable, Code.RawValue == String {
    Array(Set(codes)).sorted { $0.rawValue < $1.rawValue }
}
