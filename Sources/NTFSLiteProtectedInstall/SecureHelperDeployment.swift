import Darwin
import Foundation
import Security

/// A privileged helper may only execute bundled code from a deployment tree
/// that an ordinary user cannot replace. The local .build app is deliberately
/// excluded; installing a protected copy is a separate administrator step.
public enum SecureHelperDeployment {
    enum ComponentKind {
        case directory
        case executable
        case regularFile
    }

    struct ComponentMetadata {
        let ownerUID: uid_t
        let mode: mode_t
        let hasExtendedACL: Bool
    }

    public static let appRoot = "/Library/PrivilegedHelperTools/NTFSLite.app"
    public static let executablePath = appRoot + "/Contents/MacOS/NTFSLiteHelper"
    public static let driverIdentifier = "com.leolu.ntfslite.ntfs-3g"
    public static let probeIdentifier = "com.leolu.ntfslite.ntfs-3g.probe"
    private static let driverPath = appRoot + "/Contents/Helpers/ntfs-3g"
    private static let probePath = appRoot + "/Contents/Helpers/ntfs-3g.probe"
    private static let directoryPaths: Set<String> = [
        "", "Contents", "Contents/Helpers", "Contents/Library",
        "Contents/Library/LaunchDaemons", "Contents/MacOS",
        "Contents/Resources", "Contents/_CodeSignature",
    ]
    private static let executablePaths: Set<String> = [
        "Contents/MacOS/NTFSLiteReadOnlyApp", "Contents/MacOS/NTFSLiteHelper",
        "Contents/Helpers/ntfs-3g", "Contents/Helpers/ntfs-3g.probe",
    ]
    private static let regularFilePaths: Set<String> = [
        "Contents/Info.plist",
        "Contents/Library/LaunchDaemons/com.leolu.ntfslite.helper.v2.plist",
        "Contents/Resources/NTFSLite.icns", "Contents/_CodeSignature/CodeResources",
    ]

    public static func isExpectedExecutablePath(_ path: String) -> Bool {
        path == executablePath
    }

    /// Exact signed-app shape. Use lstat for every entry so an expected name
    /// cannot hide a symlink, and enumerate every expected directory so an
    /// unexpected nested item cannot escape the owner/permission checks.
    static func hasExactManifest(at appPath: String) -> Bool {
        let allPaths = directoryPaths.union(executablePaths).union(regularFilePaths)
        for relativePath in allPaths {
            let path = relativePath.isEmpty ? appPath : appPath + "/" + relativePath
            var details = stat()
            guard lstat(path, &details) == 0 else { return false }
            let kind = details.st_mode & mode_t(S_IFMT)
            if directoryPaths.contains(relativePath) {
                guard kind == mode_t(S_IFDIR) else { return false }
            } else {
                guard kind == mode_t(S_IFREG) else { return false }
            }
        }
        for directory in directoryPaths {
            let path = directory.isEmpty ? appPath : appPath + "/" + directory
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
                return false
            }
            let children = Set(names.map { directory.isEmpty ? $0 : directory + "/" + $0 })
            let expected = Set(allPaths.filter { relativePath in
                guard relativePath != directory, !relativePath.isEmpty else { return false }
                let parent = (relativePath as NSString).deletingLastPathComponent
                return parent == "." && directory.isEmpty || parent == directory
            })
            guard children == expected else { return false }
        }
        return true
    }

    /// Pure permission decision used for every path component. A symlink has
    /// a different file type and is always rejected. Rejecting every extended
    /// ACL is stricter than allowing selected ACLs and avoids ambiguous grants.
    static func accepts(_ metadata: ComponentMetadata, expectedKind: ComponentKind) -> Bool {
        guard metadata.ownerUID == 0,
              metadata.mode & mode_t(S_IWGRP | S_IWOTH) == 0,
              !metadata.hasExtendedACL
        else { return false }
        switch expectedKind {
        case .directory:
            return metadata.mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        case .executable:
            return metadata.mode & mode_t(S_IFMT) == mode_t(S_IFREG)
                && metadata.mode & mode_t(S_IXUSR) != 0
        case .regularFile:
            return metadata.mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        }
    }

    /// Verify on each admitted mutation and on every self-spawned user agent.
    /// Once each parent directory passes, ordinary users cannot replace its
    /// children between lstat, ACL inspection, signature check and execution.
    public static func verifyCurrent(
        requireRootProcess: Bool,
        appIdentifier: String,
        helperIdentifier: String,
        driverIdentifier: String,
        probeIdentifier: String,
        teamIdentifier: String
    ) -> Bool {
        if requireRootProcess && (getuid() != 0 || geteuid() != 0) { return false }
        guard let currentPath = currentExecutablePath(),
              isExpectedExecutablePath(currentPath)
        else { return false }

        return verifyInstalled(
            appIdentifier: appIdentifier,
            helperIdentifier: helperIdentifier,
            driverIdentifier: driverIdentifier,
            probeIdentifier: probeIdentifier,
            teamIdentifier: teamIdentifier
        )
    }

    /// Also used by the read-only post-install verifier. It does not require
    /// the caller itself to be privileged or to run from the installed bundle.
    public static func verifyInstalled(
        appIdentifier: String,
        helperIdentifier: String,
        driverIdentifier: String,
        probeIdentifier: String,
        teamIdentifier: String
    ) -> Bool {
        let ancestors = ["/", "/Library", "/Library/PrivilegedHelperTools"]
        guard ancestors.allSatisfy({ secureComponent(at: $0, kind: .directory) }),
              directoryPaths.allSatisfy({ relativePath in
                  let path = relativePath.isEmpty ? appRoot : appRoot + "/" + relativePath
                  return secureComponent(at: path, kind: .directory)
              }),
              executablePaths.allSatisfy({ secureComponent(at: appRoot + "/" + $0, kind: .executable) }),
              regularFilePaths.allSatisfy({ secureComponent(at: appRoot + "/" + $0, kind: .regularFile) }),
              hasExactManifest(at: appRoot)
        else { return false }

        return validSignature(at: appRoot, identifier: appIdentifier, team: teamIdentifier)
            && validSignature(at: executablePath, identifier: helperIdentifier, team: teamIdentifier)
            && validSignature(at: driverPath, identifier: driverIdentifier, team: teamIdentifier)
            && validSignature(at: probePath, identifier: probeIdentifier, team: teamIdentifier)
    }

    private static func currentExecutablePath() -> String? {
        var size = UInt32(MAXPATHLEN)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard bytes.count < buffer.count else { return nil }
        let path = String(decoding: bytes, as: UTF8.self)
        return Array(path.utf8) == bytes ? path : nil
    }

    static func secureComponent(at path: String, kind: ComponentKind) -> Bool {
        var details = stat()
        guard lstat(path, &details) == 0,
              let hasExtendedACL = extendedACLStatus(at: path),
              accepts(ComponentMetadata(
                  ownerUID: details.st_uid,
                  mode: details.st_mode,
                  hasExtendedACL: hasExtendedACL
              ), expectedKind: kind)
        else { return false }
        return true
    }

    /// On Darwin, ENOENT for an existing file means no extended ACL. The
    /// caller already lstat'ed the path, and its parent is protected. Any
    /// other failure cannot prove that the ACL is absent.
    private static func extendedACLStatus(at path: String) -> Bool? {
        errno = 0
        if let acl = acl_get_file(path, ACL_TYPE_EXTENDED) {
            acl_free(UnsafeMutableRawPointer(acl))
            return true
        }
        return errno == ENOENT ? false : nil
    }

    private static func validSignature(at path: String, identifier: String, team: String) -> Bool {
        let requirementText = "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[subject.OU] = \"\(team)\""
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { return false }
        return SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            requirement
        ) == errSecSuccess
    }
}
