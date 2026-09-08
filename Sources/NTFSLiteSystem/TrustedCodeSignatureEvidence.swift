import Foundation
import NTFSLiteCore
import Security

public struct TrustedCodeSignaturePolicy: Equatable, Sendable {
    public let designatedRequirement: String
    public let expectedTeamIdentifier: String
    public let expectedCodeDirectoryHash: Data

    public init(
        designatedRequirement: String,
        expectedTeamIdentifier: String,
        expectedCodeDirectoryHash: Data
    ) {
        self.designatedRequirement = designatedRequirement
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.expectedCodeDirectoryHash = expectedCodeDirectoryHash
    }
}

public struct TrustedCodeSignatureEvidence: Equatable, Sendable {
    public let teamIdentifier: String
    public let codeDirectoryHash: Data
    public let securedBundleIdentifier: String
    public let securedBundleVersionText: String

    public init(
        teamIdentifier: String,
        codeDirectoryHash: Data,
        securedBundleIdentifier: String,
        securedBundleVersionText: String
    ) {
        self.teamIdentifier = teamIdentifier
        self.codeDirectoryHash = codeDirectoryHash
        self.securedBundleIdentifier = securedBundleIdentifier
        self.securedBundleVersionText = securedBundleVersionText
    }
}

public enum TrustedCodeSignatureReadFailure: Equatable, Sendable {
    case invalidPolicy
    case requirementInvalid
    case staticCodeUnavailable
    case signatureInvalid
    case signingInformationUnavailable
    case teamIdentifierMissing
    case codeDirectoryHashMissing
    case securedInfoPlistMissing
    case securedBundleIdentifierMissing
    case securedBundleVersionMissing
    case securedBundleVersionInvalid
    case teamIdentifierMismatch
    case codeDirectoryHashMismatch
    case securedBundleIdentifierMismatch
    case securedBundleVersionMismatch
}

public enum TrustedCodeSignatureReadResult: Equatable, Sendable {
    case observed(TrustedCodeSignatureEvidence)
    case failedClosed(TrustedCodeSignatureReadFailure)
}

public struct TrustedCodeSignatureEvidenceProvider: Sendable {
    private let loadEvidence: @Sendable (
        _ bundleRootPath: String,
        _ policy: TrustedCodeSignaturePolicy
    ) -> TrustedCodeSignatureReadResult

    public init(
        _ loadEvidence: @escaping @Sendable (
            _ bundleRootPath: String,
            _ policy: TrustedCodeSignaturePolicy
        ) -> TrustedCodeSignatureReadResult
    ) {
        self.loadEvidence = loadEvidence
    }

    public func evidence(
        for bundleRootPath: String,
        policy: TrustedCodeSignaturePolicy
    ) -> TrustedCodeSignatureReadResult {
        loadEvidence(bundleRootPath, policy)
    }

    public static let live = TrustedCodeSignatureEvidenceProvider {
        bundleRootPath,
        policy in
        readLiveEvidence(bundleRootPath: bundleRootPath, policy: policy)
    }
}

public struct TrustedMacFUSEPolicy: Equatable, Sendable {
    public let bundleVersionPolicy: TrustedBundleVersionPolicy
    public let codeSignaturePoliciesByVersion: [SemanticVersion: TrustedCodeSignaturePolicy]

    public init(
        bundleVersionPolicy: TrustedBundleVersionPolicy,
        codeSignaturePoliciesByVersion: [SemanticVersion: TrustedCodeSignaturePolicy]
    ) {
        self.bundleVersionPolicy = bundleVersionPolicy
        self.codeSignaturePoliciesByVersion = codeSignaturePoliciesByVersion
    }
}

public enum TrustedMacFUSEReadFailure: Equatable, Sendable {
    case bundle(TrustedBundleVersionReadFailure)
    case codeSignature(TrustedCodeSignatureReadFailure)
}

public enum TrustedMacFUSEReadResult: Equatable, Sendable {
    case trusted(SemanticVersion)
    case failedClosed(TrustedMacFUSEReadFailure)
}

public enum TrustedMacFUSEEvidenceReader {
    public static func read(
        policy: TrustedMacFUSEPolicy,
        evidenceProvider: TrustedCodeSignatureEvidenceProvider = .live
    ) -> TrustedMacFUSEReadResult {
        let version: SemanticVersion
        switch TrustedBundleVersionReader.read(policy: policy.bundleVersionPolicy) {
        case let .trusted(observedVersion):
            version = observedVersion
        case let .failedClosed(failure):
            return .failedClosed(.bundle(failure))
        }

        let signaturePolicies = policy.codeSignaturePoliciesByVersion
        guard !signaturePolicies.isEmpty,
              Set(signaturePolicies.keys) == policy.bundleVersionPolicy.approvedVersions,
              Set(signaturePolicies.values.map(\.expectedCodeDirectoryHash)).count
                == signaturePolicies.count,
              signaturePolicies.values.allSatisfy(isValid),
              let signaturePolicy = signaturePolicies[version]
        else {
            return .failedClosed(.codeSignature(.invalidPolicy))
        }
        guard signaturePolicies.values.allSatisfy({
            requirementCompiles($0.designatedRequirement)
        }) else {
            return .failedClosed(.codeSignature(.requirementInvalid))
        }

        switch evidenceProvider.evidence(
            for: policy.bundleVersionPolicy.bundleRootPath,
            policy: signaturePolicy
        ) {
        case let .observed(evidence):
            guard isValidTeamIdentifier(evidence.teamIdentifier) else {
                return .failedClosed(.codeSignature(.teamIdentifierMissing))
            }
            guard (20...64).contains(evidence.codeDirectoryHash.count) else {
                return .failedClosed(.codeSignature(.codeDirectoryHashMissing))
            }
            guard !evidence.securedBundleIdentifier.isEmpty else {
                return .failedClosed(.codeSignature(.securedBundleIdentifierMissing))
            }
            guard !evidence.securedBundleVersionText.isEmpty else {
                return .failedClosed(.codeSignature(.securedBundleVersionMissing))
            }
            guard let securedBundleVersion = TrustedBundleVersionReader.strictSemanticVersion(
                evidence.securedBundleVersionText
            ) else {
                return .failedClosed(.codeSignature(.securedBundleVersionInvalid))
            }
            guard evidence.securedBundleIdentifier
                    == policy.bundleVersionPolicy.expectedBundleIdentifier
            else {
                return .failedClosed(.codeSignature(.securedBundleIdentifierMismatch))
            }
            guard securedBundleVersion == version else {
                return .failedClosed(.codeSignature(.securedBundleVersionMismatch))
            }
            guard evidence.teamIdentifier == signaturePolicy.expectedTeamIdentifier else {
                return .failedClosed(.codeSignature(.teamIdentifierMismatch))
            }
            guard evidence.codeDirectoryHash
                    == signaturePolicy.expectedCodeDirectoryHash
            else {
                return .failedClosed(.codeSignature(.codeDirectoryHashMismatch))
            }
            return .trusted(version)
        case let .failedClosed(failure):
            return .failedClosed(.codeSignature(failure))
        }
    }

    private static func isValid(_ policy: TrustedCodeSignaturePolicy) -> Bool {
        let requirement = policy.designatedRequirement
        guard !requirement.isEmpty,
              requirement == requirement.trimmingCharacters(in: .whitespacesAndNewlines),
              requirement.utf8.count <= 4_096,
              !requirement.utf8.contains(0),
              isValidTeamIdentifier(policy.expectedTeamIdentifier),
              (20...64).contains(policy.expectedCodeDirectoryHash.count)
        else {
            return false
        }
        return true
    }

    private static func isValidTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90)
        }
    }

    private static func requirementCompiles(_ source: String) -> Bool {
        var requirement: SecRequirement?
        return SecRequirementCreateWithString(
            source as NSString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess && requirement != nil
    }

}

private func readLiveEvidence(
    bundleRootPath: String,
    policy: TrustedCodeSignaturePolicy
) -> TrustedCodeSignatureReadResult {
    let bundleURL = URL(fileURLWithPath: bundleRootPath, isDirectory: true)
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(
        bundleURL as NSURL,
        SecCSFlags(),
        &staticCode
    ) == errSecSuccess, let staticCode else {
        return .failedClosed(.staticCodeUnavailable)
    }

    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(
        policy.designatedRequirement as NSString,
        SecCSFlags(),
        &requirement
    ) == errSecSuccess, let requirement else {
        return .failedClosed(.requirementInvalid)
    }

    let validationFlags = SecCSFlags(
        rawValue: kSecCSCheckAllArchitectures
            | kSecCSCheckNestedCode
            | kSecCSStrictValidate
            | kSecCSRestrictSymlinks
    )
    guard SecStaticCodeCheckValidity(
        staticCode,
        validationFlags,
        requirement
    ) == errSecSuccess else {
        return .failedClosed(.signatureInvalid)
    }

    var information: CFDictionary?
    let informationFlags = SecCSFlags(
        rawValue: kSecCSSigningInformation | kSecCSRequirementInformation
    )
    guard SecCodeCopySigningInformation(
        staticCode,
        informationFlags,
        &information
    ) == errSecSuccess,
        let dictionary = information as? [String: Any]
    else {
        return .failedClosed(.signingInformationUnavailable)
    }
    guard let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
          !teamIdentifier.isEmpty
    else {
        return .failedClosed(.teamIdentifierMissing)
    }
    guard let codeDirectoryHash = dictionary[kSecCodeInfoUnique as String] as? Data,
          !codeDirectoryHash.isEmpty
    else {
        return .failedClosed(.codeDirectoryHashMissing)
    }
    guard let securedInfoPlist = dictionary[kSecCodeInfoPList as String] as? [String: Any]
    else {
        return .failedClosed(.securedInfoPlistMissing)
    }
    guard let securedBundleIdentifier = securedInfoPlist["CFBundleIdentifier"] as? String,
          !securedBundleIdentifier.isEmpty
    else {
        return .failedClosed(.securedBundleIdentifierMissing)
    }
    guard let securedBundleVersionText = securedInfoPlist["CFBundleShortVersionString"]
        as? String,
        !securedBundleVersionText.isEmpty
    else {
        return .failedClosed(.securedBundleVersionMissing)
    }
    return .observed(
        TrustedCodeSignatureEvidence(
            teamIdentifier: teamIdentifier,
            codeDirectoryHash: codeDirectoryHash,
            securedBundleIdentifier: securedBundleIdentifier,
            securedBundleVersionText: securedBundleVersionText
        )
    )
}
