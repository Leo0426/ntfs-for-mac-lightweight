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

        print("PASS: helper deployment policy rejects replaceable paths and files")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
