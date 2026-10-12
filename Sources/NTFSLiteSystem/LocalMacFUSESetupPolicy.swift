import Foundation
import NTFSLiteCore

/// Exact local signature observed on 2026-10-09. This diagnostic policy is not
/// a Gate approval, a compatibility claim, or authorization to mutate a disk.
public enum LocalMacFUSESetupPolicy {
    public static let current: TrustedMacFUSEPolicy = {
        let version = SemanticVersion(major: 5, minor: 4, patch: 0)
        return TrustedMacFUSEPolicy(
            bundleVersionPolicy: TrustedBundleVersionPolicy(
                bundleRootPath: "/Library/Filesystems/macfuse.fs",
                expectedBundleIdentifier: "io.macfuse.filesystems.fs.macfuse",
                expectedOwnerUID: 0,
                approvedVersions: [version]
            ),
            codeSignaturePoliciesByVersion: [version: TrustedCodeSignaturePolicy(
                designatedRequirement: "anchor apple generic and identifier \"io.macfuse.filesystems.fs.macfuse\" and certificate leaf[subject.OU] = \"3T5GSNBU6W\"",
                expectedTeamIdentifier: "3T5GSNBU6W",
                expectedCodeDirectoryHash: Data([0x65, 0xc7, 0xc1, 0xfd, 0x6c, 0x8a, 0xe5, 0x07, 0xa8, 0xaf, 0xa1, 0x1c, 0xa9, 0x9c, 0xeb, 0xd5, 0x1b, 0x7b, 0x33, 0xb0])
            )]
        )
    }()
}
