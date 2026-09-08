import NTFSLiteCore
import NTFSLiteSystem

public enum DiagnosticProjectionError: Error, Equatable, Sendable {
    case versionOutOfRange
    case countOutOfRange
}

public enum DiagnosticProjection {
    public static func setup(
        facts: SetupFacts,
        assessment: SetupAssessment,
        applicationVersion: DiagnosticVersion,
        applicationBuild: UInt32
    ) throws -> DiagnosticInput {
        .setup(
            DiagnosticSetupEvent(
                applicationVersion: applicationVersion,
                applicationBuild: applicationBuild,
                macOSVersion: try diagnosticVersion(facts.macOSVersion),
                architecture: diagnosticArchitecture(facts.architecture),
                macFUSEVersion: try facts.macFUSEVersion.map(diagnosticVersion),
                ntfs3GVersion: try facts.ntfs3GVersion.map(diagnosticVersion),
                fileSystemExtensionEnabled: facts.fileSystemExtensionEnabled,
                selectedBackend: diagnosticBackend(facts.selectedBackend),
                issueCodes: assessment.issues.map(setupIssueCode),
                conflictingDriverCount: try diagnosticCount(
                    facts.conflictingDrivers.count
                )
            )
        )
    }

    public static func inventory(
        _ observation: DiskInventoryObservation
    ) throws -> DiagnosticInput {
        let diskIssues = observation.physicalDisks.flatMap(\.issues)
        let volumeRecords = observation.physicalDisks.flatMap(\.volumes)
        let volumeIssues = volumeRecords.flatMap(\.issues)
        let issueCodes = observation.issues.map(inventoryIssueCode)
            + diskIssues.map(inventoryIssueCode)
            + volumeIssues.map(inventoryIssueCode)

        return .inventory(
            DiagnosticInventoryEvent(
                isComplete: observation.isComplete,
                physicalDiskCount: try diagnosticCount(
                    observation.physicalDisks.count
                ),
                volumeCount: try diagnosticCount(volumeRecords.count),
                issueCodes: issueCodes
            )
        )
    }

    private static func diagnosticVersion(
        _ version: SemanticVersion
    ) throws -> DiagnosticVersion {
        guard let major = UInt32(exactly: version.major),
              let minor = UInt32(exactly: version.minor),
              let patch = UInt32(exactly: version.patch)
        else {
            throw DiagnosticProjectionError.versionOutOfRange
        }
        return DiagnosticVersion(major: major, minor: minor, patch: patch)
    }

    private static func diagnosticCount(_ count: Int) throws -> UInt32 {
        guard let value = UInt32(exactly: count) else {
            throw DiagnosticProjectionError.countOutOfRange
        }
        return value
    }

    private static func diagnosticArchitecture(
        _ architecture: RuntimeArchitecture
    ) -> DiagnosticArchitecture {
        switch architecture {
        case .appleSilicon:
            .appleSilicon
        case .intel:
            .intel
        case .unknown:
            .unknown
        }
    }

    private static func diagnosticBackend(
        _ backend: ObservedMountBackend
    ) -> DiagnosticBackend {
        switch backend {
        case .fsKit:
            .fsKit
        case .kernelExtension:
            .kernelExtension
        case .unknown:
            .unknown
        }
    }

    private static func setupIssueCode(
        _ issue: SetupIssue
    ) -> DiagnosticSetupIssueCode {
        switch issue {
        case .unsupportedOperatingSystem:
            .unsupportedOperatingSystem
        case .unsupportedArchitecture:
            .unsupportedArchitecture
        case .macFUSEMissing:
            .macFUSEMissing
        case .macFUSETooOld:
            .macFUSETooOld
        case .fileSystemExtensionDisabled:
            .fileSystemExtensionDisabled
        case .ntfs3GMissing:
            .ntfs3GMissing
        case .ntfs3GTooOld:
            .ntfs3GTooOld
        case .unsafeBackend:
            .unsafeBackend
        case .requiredAuthorizationUnavailable:
            .requiredAuthorizationUnavailable
        case .conflictScanIncomplete:
            .conflictScanIncomplete
        case .conflictingDrivers:
            .conflictingDrivers
        }
    }

    private static func inventoryIssueCode(
        _ issue: DiskInventoryIssue
    ) -> DiagnosticInventoryIssueCode {
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

    private static func inventoryIssueCode(
        _ issue: ReadOnlyObservationIssue
    ) -> DiagnosticInventoryIssueCode {
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
