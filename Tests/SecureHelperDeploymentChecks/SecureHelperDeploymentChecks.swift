import Darwin
import Foundation

@main
struct SecureHelperDeploymentChecks {
    static func main() {
        let protectedDirectory = SecureHelperDeployment.ComponentMetadata(
            ownerUID: 0,
            mode: mode_t(S_IFDIR | 0o755),
            hasExtendedACL: false
        )
        let protectedExecutable = SecureHelperDeployment.ComponentMetadata(
            ownerUID: 0,
            mode: mode_t(S_IFREG | 0o755),
            hasExtendedACL: false
        )

        expect(
            SecureHelperDeployment.accepts(protectedDirectory, expectedKind: .directory),
            "a root-owned 755 directory without ACL should pass"
        )
        expect(
            SecureHelperDeployment.accepts(protectedExecutable, expectedKind: .executable),
            "a root-owned 755 executable without ACL should pass"
        )
        expect(
            SecureHelperDeployment.accepts(.init(
                ownerUID: 0, mode: mode_t(S_IFREG | 0o644), hasExtendedACL: false
            ), expectedKind: .regularFile),
            "a root-owned non-writable package file should pass"
        )
        expect(
            !SecureHelperDeployment.accepts(.init(
                ownerUID: 0, mode: mode_t(S_IFLNK | 0o777), hasExtendedACL: false
            ), expectedKind: .regularFile),
            "a symlink must not pass as a package file"
        )
        expect(
            !SecureHelperDeployment.accepts(.init(
                ownerUID: 501, mode: mode_t(S_IFDIR | 0o755), hasExtendedACL: false
            ), expectedKind: .directory),
            "a user-owned ancestor must fail"
        )
        expect(
            !SecureHelperDeployment.accepts(.init(
                ownerUID: 0, mode: mode_t(S_IFDIR | 0o775), hasExtendedACL: false
            ), expectedKind: .directory),
            "a group-writable ancestor must fail"
        )
        expect(
            !SecureHelperDeployment.accepts(.init(
                ownerUID: 0, mode: mode_t(S_IFDIR | 0o757), hasExtendedACL: false
            ), expectedKind: .directory),
            "an other-writable ancestor must fail"
        )
        expect(
            !SecureHelperDeployment.accepts(.init(
                ownerUID: 0, mode: mode_t(S_IFLNK | 0o755), hasExtendedACL: false
            ), expectedKind: .directory),
            "a symlink in the deployment path must fail"
        )
        expect(
            !SecureHelperDeployment.accepts(.init(
                ownerUID: 0, mode: mode_t(S_IFDIR | 0o755), hasExtendedACL: true
            ), expectedKind: .directory),
            "an ACL-bearing ancestor must fail even when POSIX mode looks safe"
        )
        expect(
            !SecureHelperDeployment.accepts(.init(
                ownerUID: 0, mode: mode_t(S_IFREG | 0o644), hasExtendedACL: false
            ), expectedKind: .executable),
            "a non-executable driver must fail"
        )
        expect(
            !SecureHelperDeployment.isExpectedExecutablePath(
                "/Users/example/project/.build/NTFSLite.app/Contents/MacOS/NTFSLiteHelper"
            ),
            "a user-writable build bundle must never be a deployment path"
        )

        checkExactInstalledManifest()

        print("PASS: helper deployment policy rejects replaceable paths and files")
    }

    /// Catches an added file, directory or symlink that would otherwise be
    /// omitted from the fixed package's path and permission checks.
    private static func checkExactInstalledManifest() {
        let manager = FileManager.default
        let app = manager.temporaryDirectory
            .appendingPathComponent("ntfslite-install-manifest-\(UUID().uuidString).app")
        defer { try? manager.removeItem(at: app) }
        do {
            for path in [
                "Contents/Helpers", "Contents/Library/LaunchDaemons",
                "Contents/MacOS", "Contents/Resources", "Contents/_CodeSignature",
            ] {
                try manager.createDirectory(at: app.appendingPathComponent(path),
                                            withIntermediateDirectories: true)
            }
            for path in [
                "Contents/Helpers/ntfs-3g", "Contents/Helpers/ntfs-3g.probe",
                "Contents/Info.plist",
                "Contents/Library/LaunchDaemons/com.leolu.ntfslite.helper.v2.plist",
                "Contents/MacOS/NTFSLiteHelper", "Contents/MacOS/NTFSLiteReadOnlyApp",
                "Contents/Resources/NTFSLite.icns", "Contents/Resources/FSKitRuntimeProbe.ntfs.zlib",
                "Contents/_CodeSignature/CodeResources",
            ] {
                guard manager.createFile(atPath: app.appendingPathComponent(path).path,
                                         contents: Data()) else { throw CocoaError(.fileWriteUnknown) }
            }
            expect(SecureHelperDeployment.hasExactManifest(at: app.path),
                   "the complete fixed app manifest should pass")

            let seed = app.appendingPathComponent("Contents/Resources/FSKitRuntimeProbe.ntfs.zlib")
            try manager.removeItem(at: seed)
            expect(!SecureHelperDeployment.hasExactManifest(at: app.path),
                   "a missing runtime seed must fail")
            try manager.createSymbolicLink(at: seed, withDestinationURL: app.appendingPathComponent("Contents/Info.plist"))
            expect(!SecureHelperDeployment.hasExactManifest(at: app.path),
                   "a linked runtime seed must fail")
            try manager.removeItem(at: seed)
            guard manager.createFile(atPath: seed.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown)
            }

            let extraFile = app.appendingPathComponent("Contents/Resources/extra.bin")
            guard manager.createFile(atPath: extraFile.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown)
            }
            expect(!SecureHelperDeployment.hasExactManifest(at: app.path),
                   "an unexpected package file must fail")
            try manager.removeItem(at: extraFile)

            let extraDirectory = app.appendingPathComponent("Contents/Extras")
            try manager.createDirectory(at: extraDirectory, withIntermediateDirectories: false)
            expect(!SecureHelperDeployment.hasExactManifest(at: app.path),
                   "an unexpected package directory must fail")
            try manager.removeItem(at: extraDirectory)

            let icon = app.appendingPathComponent("Contents/Resources/NTFSLite.icns")
            try manager.removeItem(at: icon)
            try manager.createSymbolicLink(at: icon, withDestinationURL: app.appendingPathComponent("Contents/Info.plist"))
            expect(!SecureHelperDeployment.hasExactManifest(at: app.path),
                   "a symlink in place of a package file must fail")
        } catch {
            fputs("FAIL: manifest fixture setup failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
