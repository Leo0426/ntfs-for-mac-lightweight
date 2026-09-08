import Foundation

public struct DiagnosticApplicationIdentity: Equatable, Sendable {
    public let version: DiagnosticVersion
    public let build: UInt32

    public init(version: DiagnosticVersion, build: UInt32) {
        self.version = version
        self.build = build
    }
}

public enum DiagnosticApplicationIdentityFailure: Error, Equatable, Sendable {
    case missingVersion
    case invalidVersion
    case missingBuild
    case invalidBuild
}

public enum DiagnosticApplicationIdentityParser {
    public static func parse(
        shortVersion: String?,
        buildVersion: String?
    ) -> Result<DiagnosticApplicationIdentity, DiagnosticApplicationIdentityFailure> {
        guard let shortVersion else {
            return .failure(.missingVersion)
        }
        let components = shortVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = strictUInt32(components[0]),
              let minor = strictUInt32(components[1]),
              let patch = strictUInt32(components[2])
        else {
            return .failure(.invalidVersion)
        }
        guard let buildVersion else {
            return .failure(.missingBuild)
        }
        guard let build = strictUInt32(Substring(buildVersion)) else {
            return .failure(.invalidBuild)
        }
        return .success(
            DiagnosticApplicationIdentity(
                version: DiagnosticVersion(major: major, minor: minor, patch: patch),
                build: build
            )
        )
    }

    private static func strictUInt32(_ text: Substring) -> UInt32? {
        guard !text.isEmpty,
              text.allSatisfy({ $0.isASCII && $0.isNumber }),
              text.count == 1 || text.first != "0"
        else {
            return nil
        }
        return UInt32(text)
    }
}
