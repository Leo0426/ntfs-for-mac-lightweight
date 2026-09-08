import Foundation
import NTFSLiteCore

public struct SetupProbePolicy: Equatable, Sendable {
    public let acceptedFSKitIdentifiers: Set<String>
    public let candidateScope: ConflictCatalogScope?
    public let activeScope: ConflictCatalogScope?
    public let environmentBaselineSatisfied: Bool

    public init(
        acceptedFSKitIdentifiers: Set<String>,
        candidateScope: ConflictCatalogScope?,
        activeScope: ConflictCatalogScope?,
        environmentBaselineSatisfied: Bool
    ) {
        self.acceptedFSKitIdentifiers = acceptedFSKitIdentifiers
        self.candidateScope = candidateScope
        self.activeScope = activeScope
        self.environmentBaselineSatisfied = environmentBaselineSatisfied
    }

    public var conflictingSystemExtensionIdentifiers: Set<String> {
        candidateScope?.loadedSystemExtensionIdentifiers ?? []
    }

    public var conflictingKextIdentifiers: Set<String> {
        candidateScope?.loadedKextIdentifiers ?? []
    }

    public static func unconfigured(
        acceptedFSKitIdentifiers: Set<String> = []
    ) -> SetupProbePolicy {
        SetupProbePolicy(
            acceptedFSKitIdentifiers: acceptedFSKitIdentifiers,
            candidateScope: nil,
            activeScope: nil,
            environmentBaselineSatisfied: false
        )
    }

    /// The dated catalog is useful for early conflict detection, but it is not
    /// an approved production scope and has no Gate 2 environment baseline.
    public static let current = SetupProbePolicy(
        acceptedFSKitIdentifiers: [
            "io.macfuse.app.fsmodule.macfuse-local",
        ],
        candidateScope: .gate2Candidate20260831,
        activeScope: nil,
        environmentBaselineSatisfied: false
    )
}

public struct SetupProbeResult: Equatable, Sendable {
    public let fileSystemExtensionEnabled: Bool
    public let conflictScanComplete: Bool
    public let conflictingDriverIdentifiers: [String]
    public let installedConflictCount: Int

    public init(
        fileSystemExtensionEnabled: Bool,
        conflictScanComplete: Bool,
        conflictingDriverIdentifiers: [String],
        installedConflictCount: Int = 0
    ) {
        self.fileSystemExtensionEnabled = fileSystemExtensionEnabled
        self.conflictScanComplete = conflictScanComplete
        self.conflictingDriverIdentifiers = conflictingDriverIdentifiers
        self.installedConflictCount = installedConflictCount
    }
}

public enum SetupProbeEvaluator {
    public static func evaluate(
        plugInKitOutputs: [String: SetupCommandOutput],
        systemExtensionOutput: SetupCommandOutput?,
        loadedKextOutput: SetupCommandOutput?,
        policy: SetupProbePolicy,
        environment: ConflictCatalogEnvironment = .unknown,
        footprintProvider: ConflictFootprintProvider = .live
    ) -> SetupProbeResult {
        let fileSystemExtensionEnabled = selectedFSKitModuleExists(
            outputs: plugInKitOutputs,
            acceptedIdentifiers: policy.acceptedFSKitIdentifiers
        )

        guard let candidateScope = policy.candidateScope,
              candidateScope.isValid
        else {
            return SetupProbeResult(
                fileSystemExtensionEnabled: fileSystemExtensionEnabled,
                conflictScanComplete: false,
                conflictingDriverIdentifiers: [],
                installedConflictCount: 0
            )
        }

        let systemExtensionScan = conflictSystemExtensions(
            output: systemExtensionOutput,
            identifiers: candidateScope.loadedSystemExtensionIdentifiers
        )
        let kextScan = conflictKexts(
            output: loadedKextOutput,
            identifiers: candidateScope.loadedKextIdentifiers
        )
        let footprintScan = conflictFootprints(
            scope: candidateScope,
            provider: footprintProvider
        )
        let loadedIdentifiers = Set(
            systemExtensionScan.identifiers + kextScan.identifiers
        )
        let conflictingArtifactIndexes = Set(
            candidateScope.artifacts.indices.filter { index in
                let artifact = candidateScope.artifacts[index]
                return !loadedIdentifiers.isDisjoint(
                    with: artifact.loadedSystemExtensionIdentifiers
                ) || !loadedIdentifiers.isDisjoint(
                    with: artifact.loadedKextIdentifiers
                ) || footprintScan.conflictingArtifactIndexes.contains(index)
            }
        )
        let opaqueConflictIdentifiers = conflictingArtifactIndexes.sorted().map {
            "known-conflict-\($0 + 1)"
        }
        let activeScopeMatches = policy.activeScope == candidateScope
            && policy.activeScope?.isValid == true

        return SetupProbeResult(
            fileSystemExtensionEnabled: fileSystemExtensionEnabled,
            conflictScanComplete: activeScopeMatches
                && environment.matches(candidateScope.target)
                && policy.environmentBaselineSatisfied
                && systemExtensionScan.isComplete
                && kextScan.isComplete
                && footprintScan.isComplete,
            conflictingDriverIdentifiers: opaqueConflictIdentifiers,
            installedConflictCount: footprintScan.conflictingArtifactIndexes.count
        )
    }

    private static func selectedFSKitModuleExists(
        outputs: [String: SetupCommandOutput],
        acceptedIdentifiers: Set<String>
    ) -> Bool {
        guard !acceptedIdentifiers.isEmpty,
              Set(outputs.keys) == acceptedIdentifiers
        else {
            return false
        }

        var foundSelectedModule = false
        for identifier in acceptedIdentifiers {
            guard let output = outputs[identifier] else {
                return false
            }
            switch PlugInKitListingParser.parse(
                output,
                allowedIdentifiers: [identifier]
            ) {
            case let .parsed(records):
                if records.contains(where: { $0.election == .use }) {
                    foundSelectedModule = true
                }
            case .failedClosed:
                return false
            }
        }
        return foundSelectedModule
    }

    private static func conflictSystemExtensions(
        output: SetupCommandOutput?,
        identifiers: Set<String>
    ) -> ConflictScanPart {
        guard !identifiers.isEmpty else {
            return ConflictScanPart(isComplete: true, identifiers: [])
        }
        guard let output else {
            return ConflictScanPart(isComplete: false, identifiers: [])
        }
        switch SystemExtensionListingParser.parse(
            output,
            allowedIdentifiers: identifiers
        ) {
        case let .parsed(records):
            return ConflictScanPart(
                isComplete: true,
                identifiers: records.map(\.identifier)
            )
        case .failedClosed:
            return ConflictScanPart(isComplete: false, identifiers: [])
        }
    }

    private static func conflictKexts(
        output: SetupCommandOutput?,
        identifiers: Set<String>
    ) -> ConflictScanPart {
        guard !identifiers.isEmpty else {
            return ConflictScanPart(isComplete: true, identifiers: [])
        }
        guard let output else {
            return ConflictScanPart(isComplete: false, identifiers: [])
        }
        switch LoadedKextParser.parse(output, allowedIdentifiers: identifiers) {
        case let .parsed(records):
            return ConflictScanPart(
                isComplete: true,
                identifiers: records.map(\.identifier)
            )
        case .failedClosed:
            return ConflictScanPart(isComplete: false, identifiers: [])
        }
    }

    private static func conflictFootprints(
        scope: ConflictCatalogScope,
        provider: ConflictFootprintProvider
    ) -> FootprintScanPart {
        var isComplete = true
        var conflictingArtifactIndexes: Set<Int> = []

        for (artifactIndex, artifact) in scope.artifacts.enumerated() {
            for footprint in artifact.installedFootprints {
                switch provider.observe(footprint) {
                case .absent:
                    break
                case .presentConflict:
                    conflictingArtifactIndexes.insert(artifactIndex)
                case .incomplete:
                    isComplete = false
                }
            }
        }
        return FootprintScanPart(
            isComplete: isComplete,
            conflictingArtifactIndexes: conflictingArtifactIndexes
        )
    }
}

public enum SetupProbeCommand: Equatable, Hashable, Sendable {
    case plugInKit(identifier: String)
    case systemExtensions
    case loadedKexts
}

public struct SetupReadOnlyCommandProvider: Sendable {
    private let loadOutput: @Sendable (SetupProbeCommand) async -> SetupCommandOutput

    public init(
        _ loadOutput: @escaping @Sendable (SetupProbeCommand) async -> SetupCommandOutput
    ) {
        self.loadOutput = loadOutput
    }

    public func output(for command: SetupProbeCommand) async -> SetupCommandOutput {
        await loadOutput(command)
    }

    public static let live = SetupReadOnlyCommandProvider { command in
        let invocation = SetupProbeInvocation(command: command)
        let result = await BoundedReadOnlyCommandRunner().run(invocation: invocation)
        return SetupCommandOutput(result)
    }
}

private struct ConflictScanPart {
    let isComplete: Bool
    let identifiers: [String]
}

private struct FootprintScanPart {
    let isComplete: Bool
    let conflictingArtifactIndexes: Set<Int>
}

private extension ConflictCatalogScope {
    static let gate2Candidate20260831 = ConflictCatalogScope(
        scopeID: "gate2-macos15.4-arm64-commercial-conflicts-2026-08-31",
        target: ConflictCatalogTarget(
            macOSVersion: SemanticVersion(major: 15, minor: 4, patch: 0),
            architecture: .appleSilicon
        ),
        evidenceDate: ConflictCatalogEvidenceDate(year: 2026, month: 8, day: 31),
        artifacts: [
            ConflictCatalogArtifact(
                artifactID: "candidate-1",
                version: SemanticVersion(major: 17, minor: 0, patch: 488),
                sha256: catalogDigest(
                    "2934127f75fb79b7be7c1b890320d7a67bfa34d56e58cf3460c15b086a75dc16"
                ),
                loadedSystemExtensionIdentifiers: [],
                loadedKextIdentifiers: [
                    "com.paragon-software.filesystems.ntfs",
                ],
                installedFootprints: [
                    InstalledConflictFootprint(
                        absolutePath: "/Library/Extensions/ufsd_NTFS.kext",
                        expectedBundleIdentifier: "com.paragon-software.filesystems.ntfs"
                    ),
                    InstalledConflictFootprint(
                        absolutePath: "/Library/Filesystems/ufsd_NTFS.fs",
                        expectedBundleIdentifier: "com.paragon-software.filesystems.ntfs.fsbundle"
                    ),
                ]
            ),
            ConflictCatalogArtifact(
                artifactID: "candidate-2",
                version: SemanticVersion(major: 2026, minor: 2, patch: 0),
                sha256: catalogDigest(
                    "3da0a23ca7e297f5ff9be8ea772dfb15977b3b7b1f6072620466a5dfd174c61a"
                ),
                loadedSystemExtensionIdentifiers: [],
                loadedKextIdentifiers: [
                    "com.tuxera.filesystems.tuxera_ntfs",
                ],
                installedFootprints: [
                    InstalledConflictFootprint(
                        absolutePath: "/Library/Filesystems/tuxera_ntfs.fs/Contents/Resources/Support/10.9/tuxera_ntfs.kext",
                        expectedBundleIdentifier: "com.tuxera.filesystems.tuxera_ntfs"
                    ),
                    InstalledConflictFootprint(
                        absolutePath: "/Library/Filesystems/tuxera_ntfs.fs",
                        expectedBundleIdentifier: "com.tuxera.filesystems.util.tuxera_ntfs"
                    ),
                    InstalledConflictFootprint(
                        absolutePath: "/Library/Filesystems/fusefs_txantfs.fs",
                        expectedBundleIdentifier: nil
                    ),
                ]
            ),
            ConflictCatalogArtifact(
                artifactID: "candidate-3",
                version: SemanticVersion(major: 8, minor: 0, patch: 0),
                sha256: catalogDigest(
                    "f327aa8a023295377c75dbf695c3975236d74a4070e661bed4e08d2cfe38f2c9"
                ),
                loadedSystemExtensionIdentifiers: [],
                loadedKextIdentifiers: [
                    "com.iboysoft.filesystems.ms_ntfs",
                ],
                installedFootprints: [
                    InstalledConflictFootprint(
                        absolutePath: "/Library/Extensions/ms_ntfs.kext",
                        expectedBundleIdentifier: "com.iboysoft.filesystems.ms_ntfs"
                    ),
                    InstalledConflictFootprint(
                        absolutePath: "/Library/Filesystems/iboysoft_NTFS.fs",
                        expectedBundleIdentifier: "com.iboysoft.filesystems.util.ntfs"
                    ),
                ]
            ),
        ]
    )
}

private func catalogDigest(_ hexadecimal: String) -> Data {
    guard hexadecimal.utf8.count == 64 else {
        return Data()
    }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(32)
    var index = hexadecimal.startIndex
    while index < hexadecimal.endIndex {
        let next = hexadecimal.index(index, offsetBy: 2)
        guard let byte = UInt8(hexadecimal[index..<next], radix: 16) else {
            return Data()
        }
        bytes.append(byte)
        index = next
    }
    return Data(bytes)
}

package struct SetupProbeInvocation {
    package let executableURL: URL
    package let arguments: [String]
    package let timeout: Duration
    package let maximumOutputBytes: Int

    init(command: SetupProbeCommand) {
        switch command {
        case let .plugInKit(identifier):
            executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            arguments = [
                "-m",
                "-Dvv",
                "-p",
                "com.apple.fskit.fsmodule",
                "-i",
                identifier,
            ]
            timeout = .seconds(3)
        case .systemExtensions:
            executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
            arguments = ["list"]
            timeout = .seconds(3)
        case .loadedKexts:
            executableURL = URL(fileURLWithPath: "/usr/bin/kmutil")
            arguments = ["showloaded", "--list-only"]
            timeout = .seconds(5)
        }
        maximumOutputBytes = 1_048_576
    }

    package init(
        executableURL: URL,
        arguments: [String],
        timeout: Duration,
        maximumOutputBytes: Int
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
    }
}

private extension SetupCommandOutput {
    init(_ result: ReadOnlyCommandResult) {
        let terminationStatus: Int32
        let wasTruncated: Bool
        switch result.completion {
        case let .exited(status):
            terminationStatus = status
            wasTruncated = false
        case .outputLimitExceeded:
            terminationStatus = -1
            wasTruncated = true
        case .timedOut, .outputUnreadable, .terminationUnconfirmed, .launchFailed:
            terminationStatus = -1
            wasTruncated = false
        }
        self.init(
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            terminationStatus: terminationStatus,
            wasTruncated: wasTruncated
        )
    }
}
