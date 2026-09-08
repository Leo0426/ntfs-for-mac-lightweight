import Darwin
import Foundation
import NTFSLiteCore

public struct TrustedBundleVersionPolicy: Equatable, Sendable {
    public let bundleRootPath: String
    public let expectedBundleIdentifier: String
    public let expectedOwnerUID: uid_t
    public let maximumInfoPlistBytes: Int
    public let approvedVersions: Set<SemanticVersion>

    public init(
        bundleRootPath: String,
        expectedBundleIdentifier: String,
        expectedOwnerUID: uid_t,
        maximumInfoPlistBytes: Int = 64 * 1_024,
        approvedVersions: Set<SemanticVersion>
    ) {
        self.bundleRootPath = bundleRootPath
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedOwnerUID = expectedOwnerUID
        self.maximumInfoPlistBytes = maximumInfoPlistBytes
        self.approvedVersions = approvedVersions
    }
}

public enum TrustedBundleVersionReadFailure: Equatable, Sendable {
    case invalidPolicy
    case invalidAbsoluteBundlePath
    case pathComponentUnavailable
    case pathComponentIsSymbolicLink
    case pathComponentIsNotDirectory
    case ownerMismatch
    case unsafeWritePermissions
    case infoPlistUnavailable
    case infoPlistIsSymbolicLink
    case infoPlistIsNotRegularFile
    case infoPlistTooLarge
    case infoPlistReadFailed
    case invalidPropertyList
    case bundleIdentifierMismatch
    case versionMissing
    case invalidSemanticVersion
    case versionNotApproved
}

public enum TrustedBundleVersionReadResult: Equatable, Sendable {
    case trusted(SemanticVersion)
    case failedClosed(TrustedBundleVersionReadFailure)
}

public enum TrustedBundleVersionReader {
    public static func read(
        policy: TrustedBundleVersionPolicy
    ) -> TrustedBundleVersionReadResult {
        guard policy.maximumInfoPlistBytes > 0,
              policy.maximumInfoPlistBytes <= maximumPermittedInfoPlistBytes,
              isValidBundleIdentifier(policy.expectedBundleIdentifier),
              !policy.approvedVersions.isEmpty,
              policy.approvedVersions.allSatisfy(isValidSemanticVersion)
        else {
            return .failedClosed(.invalidPolicy)
        }

        guard let bundleComponents = absolutePathComponents(
            policy.bundleRootPath
        ) else {
            return .failedClosed(.invalidAbsoluteBundlePath)
        }

        let rootDescriptor = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else {
            return .failedClosed(.pathComponentUnavailable)
        }
        defer { close(rootDescriptor) }

        var currentDescriptor = rootDescriptor
        var ownedDescriptor: Int32?
        defer {
            if let ownedDescriptor {
                close(ownedDescriptor)
            }
        }

        for (index, component) in bundleComponents.enumerated() {
            let nextDescriptor = component.withCString { pointer in
                openat(
                    currentDescriptor,
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard nextDescriptor >= 0 else {
                let openError = errno
                return .failedClosed(
                    directoryOpenFailure(
                        for: openError,
                        named: component,
                        relativeTo: currentDescriptor
                    )
                )
            }

            if let previousDescriptor = ownedDescriptor {
                close(previousDescriptor)
            }
            ownedDescriptor = nextDescriptor
            currentDescriptor = nextDescriptor

            if index == bundleComponents.indices.last {
                guard let failure = trustedMetadataFailure(
                    descriptor: currentDescriptor,
                    expectedOwnerUID: policy.expectedOwnerUID,
                    expectedKind: S_IFDIR
                ) else {
                    continue
                }
                return .failedClosed(failure)
            }
        }

        guard let contentsDescriptor = openDirectory(
            named: "Contents",
            relativeTo: currentDescriptor
        ) else {
            let openError = errno
            return .failedClosed(
                directoryOpenFailure(
                    for: openError,
                    named: "Contents",
                    relativeTo: currentDescriptor
                )
            )
        }
        defer { close(contentsDescriptor) }

        if let failure = trustedMetadataFailure(
            descriptor: contentsDescriptor,
            expectedOwnerUID: policy.expectedOwnerUID,
            expectedKind: S_IFDIR
        ) {
            return .failedClosed(failure)
        }

        let infoDescriptor = "Info.plist".withCString { pointer in
            openat(
                contentsDescriptor,
                pointer,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard infoDescriptor >= 0 else {
            return .failedClosed(infoPlistOpenFailure(for: errno))
        }
        defer { close(infoDescriptor) }

        var information = stat()
        guard fstat(infoDescriptor, &information) == 0 else {
            return .failedClosed(.infoPlistReadFailed)
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            return .failedClosed(.infoPlistIsNotRegularFile)
        }
        guard information.st_uid == policy.expectedOwnerUID else {
            return .failedClosed(.ownerMismatch)
        }
        guard information.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            return .failedClosed(.unsafeWritePermissions)
        }
        guard information.st_size >= 0,
              UInt64(information.st_size) <= UInt64(policy.maximumInfoPlistBytes)
        else {
            return .failedClosed(.infoPlistTooLarge)
        }

        guard let data = readBounded(
            descriptor: infoDescriptor,
            maximumBytes: policy.maximumInfoPlistBytes
        ) else {
            return .failedClosed(.infoPlistReadFailed)
        }

        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        } catch {
            return .failedClosed(.invalidPropertyList)
        }

        guard let dictionary = propertyList as? [String: Any],
              let observedIdentifier = dictionary["CFBundleIdentifier"] as? String,
              observedIdentifier == policy.expectedBundleIdentifier
        else {
            return .failedClosed(.bundleIdentifierMismatch)
        }
        guard let versionText = dictionary["CFBundleShortVersionString"] as? String else {
            return .failedClosed(.versionMissing)
        }
        guard let version = strictSemanticVersion(versionText) else {
            return .failedClosed(.invalidSemanticVersion)
        }
        guard policy.approvedVersions.contains(version) else {
            return .failedClosed(.versionNotApproved)
        }
        return .trusted(version)
    }

    private static let maximumPermittedInfoPlistBytes = 1_048_576

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
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0)
              })
        else {
            return nil
        }
        return components
    }

    private static func isValidBundleIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty,
              identifier.utf8.count <= 255,
              identifier.contains("."),
              !identifier.utf8.contains(0)
        else {
            return false
        }
        return identifier.split(
            separator: ".",
            omittingEmptySubsequences: false
        ).allSatisfy { component in
            !component.isEmpty && component.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57)
                    || (byte >= 65 && byte <= 90)
                    || (byte >= 97 && byte <= 122)
                    || byte == 45
            }
        }
    }

    private static func isValidSemanticVersion(_ version: SemanticVersion) -> Bool {
        version.major >= 0 && version.minor >= 0 && version.patch >= 0
    }

    private static func openDirectory(
        named name: String,
        relativeTo descriptor: Int32
    ) -> Int32? {
        let opened = name.withCString { pointer in
            openat(
                descriptor,
                pointer,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        return opened >= 0 ? opened : nil
    }

    private static func directoryOpenFailure(
        for error: Int32,
        named name: String,
        relativeTo descriptor: Int32
    ) -> TrustedBundleVersionReadFailure {
        if error == ELOOP || isSymbolicLink(named: name, relativeTo: descriptor) {
            return .pathComponentIsSymbolicLink
        }
        return error == ENOTDIR
            ? .pathComponentIsNotDirectory
            : .pathComponentUnavailable
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

    private static func infoPlistOpenFailure(
        for error: Int32
    ) -> TrustedBundleVersionReadFailure {
        switch error {
        case ELOOP:
            .infoPlistIsSymbolicLink
        default:
            .infoPlistUnavailable
        }
    }

    private static func trustedMetadataFailure(
        descriptor: Int32,
        expectedOwnerUID: uid_t,
        expectedKind: mode_t
    ) -> TrustedBundleVersionReadFailure? {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            return .pathComponentUnavailable
        }
        guard information.st_mode & S_IFMT == expectedKind else {
            return .pathComponentIsNotDirectory
        }
        guard information.st_uid == expectedOwnerUID else {
            return .ownerMismatch
        }
        guard information.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            return .unsafeWritePermissions
        }
        return nil
    }

    private static func readBounded(
        descriptor: Int32,
        maximumBytes: Int
    ) -> Data? {
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 16_384))
        var buffer = [UInt8](repeating: 0, count: 8_192)

        while true {
            let remaining = maximumBytes - data.count
            guard remaining >= 0 else {
                return nil
            }
            let requestedCount = min(buffer.count, remaining + 1)
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, requestedCount)
            }
            if bytesRead == 0 {
                return data
            }
            if bytesRead < 0 {
                if errno == EINTR {
                    continue
                }
                return nil
            }
            guard bytesRead <= remaining else {
                return nil
            }
            data.append(buffer, count: bytesRead)
        }
    }

    static func strictSemanticVersion(_ text: String) -> SemanticVersion? {
        guard text == text.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else {
            return nil
        }

        var values: [Int] = []
        values.reserveCapacity(3)
        for component in components {
            guard !component.isEmpty,
                  component.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  (component.count == 1 || component.first != "0"),
                  let value = Int(component)
            else {
                return nil
            }
            values.append(value)
        }
        return SemanticVersion(major: values[0], minor: values[1], patch: values[2])
    }
}
