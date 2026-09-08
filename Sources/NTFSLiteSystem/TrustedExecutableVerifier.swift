import Darwin
import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

public struct TrustedExecutablePolicy: Equatable, Sendable {
    public let executablePath: String
    public let expectedBasename: String
    public let expectedOwnerUID: uid_t
    public let maximumBytes: Int
    public let allowedSHA256Digests: Set<String>

    public init(
        executablePath: String,
        expectedBasename: String,
        expectedOwnerUID: uid_t,
        maximumBytes: Int,
        allowedSHA256Digests: Set<String>
    ) {
        self.executablePath = executablePath
        self.expectedBasename = expectedBasename
        self.expectedOwnerUID = expectedOwnerUID
        self.maximumBytes = maximumBytes
        self.allowedSHA256Digests = allowedSHA256Digests
    }
}

public struct TrustedExecutableEvidence: Equatable, Sendable {
    public let sha256Digest: String
    public let byteCount: Int

    public init(sha256Digest: String, byteCount: Int) {
        self.sha256Digest = sha256Digest
        self.byteCount = byteCount
    }
}

public enum TrustedExecutableVerificationFailure: Equatable, Sendable {
    case invalidPolicy
    case invalidAbsolutePath
    case basenameMismatch
    case pathComponentUnavailable
    case pathComponentIsSymbolicLink
    case pathComponentIsNotDirectory
    case executableUnavailable
    case executableIsSymbolicLink
    case executableIsNotRegularFile
    case ownerMismatch
    case privilegeEscalationBitsPresent
    case unsafeWritePermissions
    case executablePermissionMissing
    case executableTooLarge
    case executableReadFailed
    case executableChangedDuringRead
    case executableGrewDuringRead
    case cryptographicHashUnavailable
    case digestNotAllowed
}

public enum TrustedExecutableVerificationResult: Equatable, Sendable {
    case trusted(TrustedExecutableEvidence)
    case failedClosed(TrustedExecutableVerificationFailure)
}

public enum TrustedExecutableVerifier {
    public static func verify(
        policy: TrustedExecutablePolicy
    ) -> TrustedExecutableVerificationResult {
        guard policy.expectedBasename == requiredBasename,
              policy.maximumBytes > 0,
              policy.maximumBytes <= maximumPermittedExecutableBytes,
              !policy.allowedSHA256Digests.isEmpty,
              policy.allowedSHA256Digests.allSatisfy(isCanonicalSHA256Digest)
        else {
            return .failedClosed(.invalidPolicy)
        }

        guard let pathComponents = absolutePathComponents(policy.executablePath),
              let observedBasename = pathComponents.last
        else {
            return .failedClosed(.invalidAbsolutePath)
        }
        guard observedBasename == policy.expectedBasename else {
            return .failedClosed(.basenameMismatch)
        }

        let rootDescriptor = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else {
            return .failedClosed(.pathComponentUnavailable)
        }
        defer { close(rootDescriptor) }

        var directoryDescriptor = rootDescriptor
        var ownedDirectoryDescriptor: Int32?
        defer {
            if let ownedDirectoryDescriptor {
                close(ownedDirectoryDescriptor)
            }
        }

        for component in pathComponents.dropLast() {
            let nextDescriptor = component.withCString { pointer in
                openat(
                    directoryDescriptor,
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard nextDescriptor >= 0 else {
                return .failedClosed(
                    directoryOpenFailure(
                        for: errno,
                        named: component,
                        relativeTo: directoryDescriptor
                    )
                )
            }

            if let previousDescriptor = ownedDirectoryDescriptor {
                close(previousDescriptor)
            }
            ownedDirectoryDescriptor = nextDescriptor
            directoryDescriptor = nextDescriptor
        }

        let executableDescriptor = observedBasename.withCString { pointer in
            openat(
                directoryDescriptor,
                pointer,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard executableDescriptor >= 0 else {
            return .failedClosed(
                executableOpenFailure(
                    for: errno,
                    named: observedBasename,
                    relativeTo: directoryDescriptor
                )
            )
        }
        defer { close(executableDescriptor) }

        var initialInformation = stat()
        guard fstat(executableDescriptor, &initialInformation) == 0 else {
            return .failedClosed(.executableReadFailed)
        }
        if let failure = initialMetadataFailure(
            initialInformation,
            expectedOwnerUID: policy.expectedOwnerUID,
            maximumBytes: policy.maximumBytes
        ) {
            return .failedClosed(failure)
        }

        guard let initialByteCount = Int(exactly: initialInformation.st_size) else {
            return .failedClosed(.executableTooLarge)
        }

#if canImport(CryptoKit)
        let hashResult = hash(
            descriptor: executableDescriptor,
            expectedByteCount: initialByteCount
        )
        let digest: String
        switch hashResult {
        case let .success(value):
            digest = value
        case let .failure(failure):
            return .failedClosed(failure)
        }
#else
        return .failedClosed(.cryptographicHashUnavailable)
#endif

        var finalInformation = stat()
        guard fstat(executableDescriptor, &finalInformation) == 0 else {
            return .failedClosed(.executableReadFailed)
        }
        guard metadataRemainedStable(
            from: initialInformation,
            to: finalInformation
        ) else {
            return .failedClosed(.executableChangedDuringRead)
        }
        guard policy.allowedSHA256Digests.contains(digest) else {
            return .failedClosed(.digestNotAllowed)
        }

        return .trusted(
            TrustedExecutableEvidence(
                sha256Digest: digest,
                byteCount: initialByteCount
            )
        )
    }

    private static let requiredBasename = "ntfs-3g"
    private static let maximumPermittedExecutableBytes = 1_073_741_824

    private static func absolutePathComponents(_ path: String) -> [String]? {
        guard path.utf8.count > 1,
              path.utf8.count <= Int(PATH_MAX),
              path.first == "/",
              path.last != "/",
              !path.utf8.contains(0)
        else {
            return nil
        }

        let rawComponents = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard rawComponents.first?.isEmpty == true else {
            return nil
        }

        let components = rawComponents.dropFirst().map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ component in
                  !component.isEmpty
                      && component != "."
                      && component != ".."
                      && !component.utf8.contains(0)
              })
        else {
            return nil
        }
        return components
    }

    private static func isCanonicalSHA256Digest(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private static func directoryOpenFailure(
        for error: Int32,
        named name: String,
        relativeTo descriptor: Int32
    ) -> TrustedExecutableVerificationFailure {
        if error == ELOOP || isSymbolicLink(named: name, relativeTo: descriptor) {
            return .pathComponentIsSymbolicLink
        }
        return error == ENOTDIR
            ? .pathComponentIsNotDirectory
            : .pathComponentUnavailable
    }

    private static func executableOpenFailure(
        for error: Int32,
        named name: String,
        relativeTo descriptor: Int32
    ) -> TrustedExecutableVerificationFailure {
        if error == ELOOP || isSymbolicLink(named: name, relativeTo: descriptor) {
            return .executableIsSymbolicLink
        }
        return .executableUnavailable
    }

    private static func isSymbolicLink(
        named name: String,
        relativeTo descriptor: Int32
    ) -> Bool {
        var information = stat()
        let status = name.withCString { pointer in
            fstatat(
                descriptor,
                pointer,
                &information,
                AT_SYMLINK_NOFOLLOW
            )
        }
        return status == 0 && information.st_mode & S_IFMT == S_IFLNK
    }

    private static func initialMetadataFailure(
        _ information: stat,
        expectedOwnerUID: uid_t,
        maximumBytes: Int
    ) -> TrustedExecutableVerificationFailure? {
        guard information.st_mode & S_IFMT == S_IFREG else {
            return .executableIsNotRegularFile
        }
        guard information.st_uid == expectedOwnerUID else {
            return .ownerMismatch
        }
        guard information.st_mode & (S_ISUID | S_ISGID) == 0 else {
            return .privilegeEscalationBitsPresent
        }
        guard information.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            return .unsafeWritePermissions
        }
        guard information.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0 else {
            return .executablePermissionMissing
        }
        guard information.st_size >= 0,
              UInt64(information.st_size) <= UInt64(maximumBytes)
        else {
            return .executableTooLarge
        }
        return nil
    }

    private static func metadataRemainedStable(
        from initial: stat,
        to final: stat
    ) -> Bool {
        initial.st_dev == final.st_dev
            && initial.st_ino == final.st_ino
            && initial.st_mode == final.st_mode
            && initial.st_uid == final.st_uid
            && initial.st_size == final.st_size
            && initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec
            && initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec
            && initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec
            && initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec
    }

#if canImport(CryptoKit)
    private enum HashResult {
        case success(String)
        case failure(TrustedExecutableVerificationFailure)
    }

    private static func hash(
        descriptor: Int32,
        expectedByteCount: Int
    ) -> HashResult {
        var hasher = SHA256()
        var totalBytesRead = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)

        while true {
            let remaining = expectedByteCount - totalBytesRead
            guard remaining >= 0 else {
                return .failure(.executableGrewDuringRead)
            }
            let requestedCount = min(buffer.count, remaining + 1)
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, requestedCount)
            }
            if bytesRead == 0 {
                guard totalBytesRead == expectedByteCount else {
                    return .failure(.executableChangedDuringRead)
                }
                let digest = hasher.finalize()
                return .success(lowercaseHex(digest))
            }
            if bytesRead < 0 {
                if errno == EINTR {
                    continue
                }
                return .failure(.executableReadFailed)
            }
            guard bytesRead <= remaining else {
                return .failure(.executableGrewDuringRead)
            }

            hasher.update(data: Data(buffer.prefix(bytesRead)))
            totalBytesRead += bytesRead
        }
    }

    private static func lowercaseHex(_ digest: SHA256.Digest) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var encoded = [UInt8]()
        encoded.reserveCapacity(SHA256.Digest.byteCount * 2)
        for byte in digest {
            encoded.append(alphabet[Int(byte >> 4)])
            encoded.append(alphabet[Int(byte & 0x0F)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }
#endif
}
