import Foundation
import NTFSLiteCore
import NTFSLiteSystem

/// A path, digest, byte count, and version tuple produced only after the
/// trusted executable verifier and pinned artifact catalog both succeed.
///
/// There is intentionally no public initializer. A caller cannot turn a
/// basename or arbitrary URL into this capability.
public struct TrustedNTFS3GArtifactCapability: Equatable, Sendable {
    public let executableURL: URL
    public let sha256Digest: String
    public let byteCount: Int
    public let version: SemanticVersion

    private let verificationPolicy: TrustedNTFS3GArtifactPolicy

    fileprivate init(
        executableURL: URL,
        evidence: TrustedNTFS3GArtifactEvidence,
        verificationPolicy: TrustedNTFS3GArtifactPolicy
    ) {
        self.executableURL = executableURL
        sha256Digest = evidence.executable.sha256Digest
        byteCount = evidence.executable.byteCount
        version = evidence.version
        self.verificationPolicy = verificationPolicy
    }

    fileprivate func isStillTrusted() -> Bool {
        switch TrustedNTFS3GArtifactResolver.resolve(policy: verificationPolicy) {
        case let .trusted(evidence):
            return executableURL.path
                    == verificationPolicy.executablePolicy.executablePath
                && evidence.version == version
                && evidence.executable.sha256Digest == sha256Digest
                && evidence.executable.byteCount == byteCount
        case .failedClosed:
            return false
        }
    }
}

public enum TrustedNTFS3GArtifactCapabilityResolutionError:
    Error,
    Equatable,
    Sendable
{
    case invalidExecutableURL
    case verificationFailed(TrustedNTFS3GArtifactFailure)
}

/// Creates the unforgeable compiler input only from fixed filesystem policy
/// and a digest-to-version catalog. It never executes the candidate tool.
public enum TrustedNTFS3GArtifactCapabilityResolver {
    public static func resolve(
        policy: TrustedNTFS3GArtifactPolicy
    ) -> Result<
        TrustedNTFS3GArtifactCapability,
        TrustedNTFS3GArtifactCapabilityResolutionError
    > {
        let path = policy.executablePolicy.executablePath
        let executableURL = URL(fileURLWithPath: path, isDirectory: false)
        guard executableURL.isFileURL,
              executableURL.path == path,
              !executableURL.hasDirectoryPath
        else {
            return .failure(.invalidExecutableURL)
        }

        switch TrustedNTFS3GArtifactResolver.resolve(policy: policy) {
        case let .trusted(evidence):
            return .success(
                TrustedNTFS3GArtifactCapability(
                    executableURL: executableURL,
                    evidence: evidence,
                    verificationPolicy: policy
                )
            )
        case let .failedClosed(failure):
            return .failure(.verificationFailed(failure))
        }
    }
}

/// The future executor must satisfy this gate immediately before process
/// creation. Rechecking a pathname cannot eliminate the final pathname race;
/// an execution adapter remains disallowed until it defines an FD-bound or
/// equivalently fail-closed launch boundary.
public struct SafeMountExecutionArtifactGate: Equatable, Sendable {
    public let executableURL: URL
    public let sha256Digest: String
    public let byteCount: Int
    public let version: SemanticVersion

    private let artifact: TrustedNTFS3GArtifactCapability

    fileprivate init(artifact: TrustedNTFS3GArtifactCapability) {
        self.artifact = artifact
        executableURL = artifact.executableURL
        sha256Digest = artifact.sha256Digest
        byteCount = artifact.byteCount
        version = artifact.version
    }

    /// Returns false for any changed, missing, ambiguous, or untrusted
    /// executable evidence. This method does not launch the executable.
    public func revalidateImmediatelyBeforeExecution() -> Bool {
        artifact.isStillTrusted()
    }
}

/// A fully compiled process invocation. Producing this value never starts a
/// process or touches a volume.
public struct SafeMountInvocation: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let targetDeviceURL: URL
    public let mountPointURL: URL
    public let executionArtifactGate: SafeMountExecutionArtifactGate

    fileprivate init(
        trustedArtifact: TrustedNTFS3GArtifactCapability,
        arguments: [String],
        targetDeviceURL: URL,
        mountPointURL: URL
    ) {
        executableURL = trustedArtifact.executableURL
        self.arguments = arguments
        self.targetDeviceURL = targetDeviceURL
        self.mountPointURL = mountPointURL
        executionArtifactGate = SafeMountExecutionArtifactGate(
            artifact: trustedArtifact
        )
    }
}

public enum SafeMountInvocationCompilationError: Error, Equatable, Sendable {
    case unsupportedMountPolicy
    case trustedArtifactChanged
    case invalidOperationID
    case invalidVolumeIdentity
    case invalidPhysicalDiskIdentity
    case invalidTargetDevice
    case targetDeviceDoesNotBelongToPhysicalDisk
    case invalidMountPoint
}

/// Compiles a `MountPlan` into the only writable mount command accepted by the
/// MVP policy. The compiler cannot add shell syntax or arbitrary mount options.
public struct SafeMountInvocationCompiler: Sendable {
    // NTFS-3G otherwise silently adds cross-user and nonempty-mount defaults.
    private static let fixedOptions = "rw,no_def_opts,backend=fskit,norecover"

    private let trustedArtifact: TrustedNTFS3GArtifactCapability

    public init(trustedArtifact: TrustedNTFS3GArtifactCapability) {
        self.trustedArtifact = trustedArtifact
    }

    public func compile(
        plan: MountPlan,
        mountPointURL: URL
    ) -> Result<SafeMountInvocation, SafeMountInvocationCompilationError> {
        guard trustedArtifact.isStillTrusted() else {
            return .failure(.trustedArtifactChanged)
        }

        switch plan.policy {
        case .fsKitCurrentUserNoRecovery:
            break
        @unknown default:
            return .failure(.unsupportedMountPolicy)
        }

        guard Self.isSafeIdentityComponent(plan.operationID.rawValue) else {
            return .failure(.invalidOperationID)
        }
        guard Self.isSafeIdentityComponent(plan.target.volumeID.uuid) else {
            return .failure(.invalidVolumeIdentity)
        }

        let physicalDiskBSDName = plan.target.diskInstanceID.physicalDiskID.rawValue
        guard Self.isWholeDiskBSDName(physicalDiskBSDName),
              plan.target.diskInstanceID.mediaGeneration.rawValue > 0
        else {
            return .failure(.invalidPhysicalDiskIdentity)
        }

        let targetBSDName = plan.target.volumeID.bsdName
        guard MountSourceParser.bsdName(from: "/dev/\(targetBSDName)") == targetBSDName else {
            return .failure(.invalidTargetDevice)
        }
        guard targetBSDName == physicalDiskBSDName
                || targetBSDName.hasPrefix("\(physicalDiskBSDName)s")
        else {
            return .failure(.targetDeviceDoesNotBelongToPhysicalDisk)
        }

        guard let canonicalMountPointURL = Self.canonicalMountPointURL(mountPointURL) else {
            return .failure(.invalidMountPoint)
        }

        let targetDeviceURL = URL(
            fileURLWithPath: "/dev/\(targetBSDName)",
            isDirectory: false
        )
        let arguments = [
            targetDeviceURL.path,
            canonicalMountPointURL.path,
            "-o",
            Self.fixedOptions,
        ]

        return .success(
            SafeMountInvocation(
                trustedArtifact: trustedArtifact,
                arguments: arguments,
                targetDeviceURL: targetDeviceURL,
                mountPointURL: canonicalMountPointURL
            )
        )
    }

    private static func canonicalMountPointURL(_ url: URL) -> URL? {
        guard isCanonicalLocalFileURL(url) else {
            return nil
        }

        let path = url.path
        let prefix = "/Volumes/"
        guard path.hasPrefix(prefix) else {
            return nil
        }

        let name = path.dropFirst(prefix.count)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !containsControlCharacter(String(name))
        else {
            return nil
        }

        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func isCanonicalLocalFileURL(_ url: URL) -> Bool {
        guard url.isFileURL,
              url.baseURL == nil,
              url.host == nil,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil
        else {
            return false
        }

        let path = url.path
        return path.hasPrefix("/")
            && path == URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func isWholeDiskBSDName(_ value: String) -> Bool {
        let prefix = "disk"
        guard value.hasPrefix(prefix) else {
            return false
        }
        let digits = value.dropFirst(prefix.count)
        return !digits.isEmpty && digits.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x30 && scalar.value <= 0x39
        }
    }

    private static func isSafeIdentityComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !containsControlCharacter(value)
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
    }
}
