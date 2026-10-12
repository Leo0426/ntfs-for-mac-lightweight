import Darwin
import Foundation
import NTFSLiteCore

func expect(_ value: Bool, _ message: String) {
    guard value else { fatalError("CHECK FAILED: " + message) }
}

@main struct BundleVersionChecks {
    static func main() throws {
        let manager = FileManager.default
        let fixtureIndex = CommandLine.arguments.firstIndex(of: "--fixture-root")!
        let bundle = URL(fileURLWithPath: CommandLine.arguments[fixtureIndex + 1]).appendingPathComponent("bundle-" + UUID().uuidString)
        let contents = bundle.appendingPathComponent("Contents")
        let plist = contents.appendingPathComponent("Info.plist")
        try manager.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: bundle) }
        chmod(bundle.path, 0o700)
        chmod(contents.path, 0o700)
        let version = SemanticVersion(major: 5, minor: 4, patch: 0)
        let policy = TrustedBundleVersionPolicy(bundleRootPath: bundle.path, expectedBundleIdentifier: "io.test.trusted", expectedOwnerUID: geteuid(), approvedVersions: [version])
        func read() -> TrustedBundleVersionReadResult { TrustedBundleVersionReader.read(policy: policy) }
        func write(_ identifier: String = "io.test.trusted", _ text: String = "5.4.0") throws {
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": text], format: .xml, options: 0)
            try data.write(to: plist)
            chmod(plist.path, 0o600)
        }
        if CommandLine.arguments.contains("--fifo") {
            expect(mkfifo(plist.path, 0o600) == 0, "scratch FIFO created")
            expect(read() == .failedClosed(.infoPlistIsNotRegularFile), "FIFO promptly fails closed without opening a writer")
            print("PASS: FIFO Info.plist promptly rejected")
            return
        }
        try write()
        expect(read() == .trusted(version), "normal trusted metadata remains supported")
        chmod(plist.path, 0o620)
        expect(read() == .failedClosed(.unsafeWritePermissions), "changed writable metadata rejected")
        chmod(plist.path, 0o600)
        expect(read() == .trusted(version), "restored trusted metadata reread fresh")
        chmod(contents.path, 0o720)
        expect(read() == .failedClosed(.unsafeWritePermissions), "unsafe Contents permissions rejected")
        chmod(contents.path, 0o700)
        let wrongOwner = TrustedBundleVersionPolicy(bundleRootPath: bundle.path, expectedBundleIdentifier: "io.test.trusted", expectedOwnerUID: geteuid() + 1, approvedVersions: [version])
        expect(TrustedBundleVersionReader.read(policy: wrongOwner) == .failedClosed(.ownerMismatch), "owner policy enforced")
        try write("io.test.other")
        expect(read() == .failedClosed(.bundleIdentifierMismatch), "identifier policy enforced")
        try write("io.test.trusted", "5.4.1")
        expect(read() == .failedClosed(.versionNotApproved), "changed unapproved version refused")
        try write("io.test.trusted", "05.4.0")
        expect(read() == .failedClosed(.invalidSemanticVersion), "strict semantic version enforced")
        try Data(repeating: 65, count: 65537).write(to: plist)
        expect(read() == .failedClosed(.infoPlistTooLarge), "bounded plist size enforced")
        try manager.removeItem(at: plist)
        try manager.createDirectory(at: plist, withIntermediateDirectories: false)
        expect(read() == .failedClosed(.infoPlistIsNotRegularFile), "directory plist refused")
        try manager.removeItem(at: plist)
        try manager.createSymbolicLink(atPath: plist.path, withDestinationPath: "missing-target")
        expect(read() == .failedClosed(.infoPlistIsSymbolicLink), "symbolic link refused")
        try manager.removeItem(at: plist)
        expect(read() == .failedClosed(.infoPlistUnavailable), "missing plist refused")
        print("PASS: trusted bundle metadata, size, type and changed-policy boundaries")
    }
}
