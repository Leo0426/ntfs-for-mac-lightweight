import NTFSLiteCore

public struct TrustedNTFS3GArtifactPolicy: Equatable, Sendable {
    public let executablePolicy: TrustedExecutablePolicy
    public let versionsBySHA256Digest: [String: SemanticVersion]

    public init(
        executablePolicy: TrustedExecutablePolicy,
        versionsBySHA256Digest: [String: SemanticVersion]
    ) {
        self.executablePolicy = executablePolicy
        self.versionsBySHA256Digest = versionsBySHA256Digest
    }
}

public struct TrustedNTFS3GArtifactEvidence: Equatable, Sendable {
    public let version: SemanticVersion
    public let executable: TrustedExecutableEvidence

    package init(
        version: SemanticVersion,
        executable: TrustedExecutableEvidence
    ) {
        self.version = version
        self.executable = executable
    }
}

public enum TrustedNTFS3GArtifactFailure: Equatable, Sendable {
    case invalidVersionCatalog
    case executable(TrustedExecutableVerificationFailure)
}

public enum TrustedNTFS3GArtifactResult: Equatable, Sendable {
    case trusted(TrustedNTFS3GArtifactEvidence)
    case failedClosed(TrustedNTFS3GArtifactFailure)
}

/// Resolves a version from a pinned digest catalog without executing the tool.
public enum TrustedNTFS3GArtifactResolver {
    public static func resolve(
        policy: TrustedNTFS3GArtifactPolicy
    ) -> TrustedNTFS3GArtifactResult {
        guard !policy.versionsBySHA256Digest.isEmpty,
              Set(policy.versionsBySHA256Digest.keys)
                == policy.executablePolicy.allowedSHA256Digests,
              policy.versionsBySHA256Digest.values.allSatisfy({ version in
                  version.major >= 0 && version.minor >= 0 && version.patch >= 0
              })
        else {
            return .failedClosed(.invalidVersionCatalog)
        }

        switch TrustedExecutableVerifier.verify(policy: policy.executablePolicy) {
        case let .trusted(executableEvidence):
            guard let version = policy.versionsBySHA256Digest[
                executableEvidence.sha256Digest
            ] else {
                return .failedClosed(.invalidVersionCatalog)
            }
            return .trusted(
                TrustedNTFS3GArtifactEvidence(
                    version: version,
                    executable: executableEvidence
                )
            )
        case let .failedClosed(failure):
            return .failedClosed(.executable(failure))
        }
    }
}
