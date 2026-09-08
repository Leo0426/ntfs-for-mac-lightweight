public struct SemanticVersion: Equatable, Hashable, Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        return lhs.patch < rhs.patch
    }
}

public enum RuntimeArchitecture: Equatable, Sendable {
    case appleSilicon
    case intel
    case unknown
}

public enum SetupAuthorizationStatus: Equatable, Sendable {
    case granted
    case denied
    case unknown
}

public struct SetupFacts: Equatable, Sendable {
    public let macOSVersion: SemanticVersion
    public let architecture: RuntimeArchitecture
    public let macFUSEVersion: SemanticVersion?
    public let ntfs3GVersion: SemanticVersion?
    public let fileSystemExtensionEnabled: Bool
    public let selectedBackend: ObservedMountBackend
    public let authorizationStatus: SetupAuthorizationStatus
    public let conflictScanComplete: Bool
    public let conflictingDrivers: [String]

    public init(
        macOSVersion: SemanticVersion,
        architecture: RuntimeArchitecture,
        macFUSEVersion: SemanticVersion?,
        ntfs3GVersion: SemanticVersion?,
        fileSystemExtensionEnabled: Bool,
        selectedBackend: ObservedMountBackend,
        authorizationStatus: SetupAuthorizationStatus,
        conflictScanComplete: Bool,
        conflictingDrivers: [String]
    ) {
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.macFUSEVersion = macFUSEVersion
        self.ntfs3GVersion = ntfs3GVersion
        self.fileSystemExtensionEnabled = fileSystemExtensionEnabled
        self.selectedBackend = selectedBackend
        self.authorizationStatus = authorizationStatus
        self.conflictScanComplete = conflictScanComplete
        self.conflictingDrivers = conflictingDrivers
    }
}

public enum SetupIssue: Equatable, Sendable {
    case unsupportedOperatingSystem(minimum: SemanticVersion, observed: SemanticVersion)
    case unsupportedArchitecture(RuntimeArchitecture)
    case macFUSEMissing
    case macFUSETooOld(minimum: SemanticVersion, observed: SemanticVersion)
    case fileSystemExtensionDisabled
    case ntfs3GMissing
    case ntfs3GTooOld(minimum: SemanticVersion, observed: SemanticVersion)
    case unsafeBackend(ObservedMountBackend)
    case requiredAuthorizationUnavailable(SetupAuthorizationStatus)
    case conflictScanIncomplete
    case conflictingDrivers([String])
}

public struct SetupAssessment: Equatable, Sendable {
    public let issues: [SetupIssue]

    public init(issues: [SetupIssue]) {
        self.issues = issues
    }

    public var isReady: Bool {
        issues.isEmpty
    }
}

public struct SetupFactsProvider: Sendable {
    private let loadFacts: @Sendable () async -> SetupFacts

    public init(_ loadFacts: @escaping @Sendable () async -> SetupFacts) {
        self.loadFacts = loadFacts
    }

    package func currentFacts() async -> SetupFacts {
        await loadFacts()
    }
}

public enum SetupChecker {
    public static let minimumMacOSVersion = SemanticVersion(major: 15, minor: 4, patch: 0)
    public static let minimumMacFUSEVersion = SemanticVersion(major: 5, minor: 3, patch: 3)
    public static let minimumNTFS3GVersion = SemanticVersion(major: 2026, minor: 7, patch: 7)

    public static func assess(_ facts: SetupFacts) -> SetupAssessment {
        var issues: [SetupIssue] = []
        if facts.macOSVersion < minimumMacOSVersion {
            issues.append(
                .unsupportedOperatingSystem(
                    minimum: minimumMacOSVersion,
                    observed: facts.macOSVersion
                )
            )
        }
        if facts.architecture != .appleSilicon {
            issues.append(.unsupportedArchitecture(facts.architecture))
        }

        if let macFUSEVersion = facts.macFUSEVersion {
            if macFUSEVersion < minimumMacFUSEVersion {
                issues.append(
                    .macFUSETooOld(
                        minimum: minimumMacFUSEVersion,
                        observed: macFUSEVersion
                    )
                )
            }
        } else {
            issues.append(.macFUSEMissing)
        }

        if !facts.fileSystemExtensionEnabled {
            issues.append(.fileSystemExtensionDisabled)
        }

        if let ntfs3GVersion = facts.ntfs3GVersion {
            if ntfs3GVersion < minimumNTFS3GVersion {
                issues.append(
                    .ntfs3GTooOld(
                        minimum: minimumNTFS3GVersion,
                        observed: ntfs3GVersion
                    )
                )
            }
        } else {
            issues.append(.ntfs3GMissing)
        }

        if facts.selectedBackend != .fsKit {
            issues.append(.unsafeBackend(facts.selectedBackend))
        }
        if facts.authorizationStatus != .granted {
            issues.append(.requiredAuthorizationUnavailable(facts.authorizationStatus))
        }
        if !facts.conflictScanComplete {
            issues.append(.conflictScanIncomplete)
        }
        if !facts.conflictingDrivers.isEmpty {
            issues.append(.conflictingDrivers(facts.conflictingDrivers.sorted()))
        }
        return SetupAssessment(issues: issues)
    }
}
