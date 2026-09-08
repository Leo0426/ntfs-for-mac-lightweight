import Foundation
import NTFSLiteCore
import NTFSLiteReadOnlyProbing

public struct SetupEnvironmentEvidence: Equatable, Sendable {
    public let macOSVersion: SemanticVersion
    public let architecture: RuntimeArchitecture
    public let macFUSEVersionText: String?
    public let ntfs3GVersionText: String?
    public let fileSystemExtensionEnabled: Bool
    public let selectedBackend: ObservedMountBackend
    public let authorizationStatus: SetupAuthorizationStatus
    public let conflictScanComplete: Bool
    public let conflictingDriverIdentifiers: [String]

    public init(
        macOSVersion: SemanticVersion,
        architecture: RuntimeArchitecture,
        macFUSEVersionText: String?,
        ntfs3GVersionText: String?,
        fileSystemExtensionEnabled: Bool,
        selectedBackend: ObservedMountBackend,
        authorizationStatus: SetupAuthorizationStatus,
        conflictScanComplete: Bool,
        conflictingDriverIdentifiers: [String]
    ) {
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.macFUSEVersionText = macFUSEVersionText
        self.ntfs3GVersionText = ntfs3GVersionText
        self.fileSystemExtensionEnabled = fileSystemExtensionEnabled
        self.selectedBackend = selectedBackend
        self.authorizationStatus = authorizationStatus
        self.conflictScanComplete = conflictScanComplete
        self.conflictingDriverIdentifiers = conflictingDriverIdentifiers
    }
}

public enum SetupEnvironmentMapper {
    public static func map(_ evidence: SetupEnvironmentEvidence) -> SetupFacts {
        SetupFacts(
            macOSVersion: evidence.macOSVersion,
            architecture: evidence.architecture,
            macFUSEVersion: evidence.macFUSEVersionText.flatMap(
                SemanticVersionParser.parse
            ),
            ntfs3GVersion: evidence.ntfs3GVersionText.flatMap(
                SemanticVersionParser.parse
            ),
            fileSystemExtensionEnabled: evidence.fileSystemExtensionEnabled,
            selectedBackend: evidence.selectedBackend,
            authorizationStatus: evidence.authorizationStatus,
            conflictScanComplete: evidence.conflictScanComplete,
            conflictingDrivers: Array(Set(evidence.conflictingDriverIdentifiers)).sorted()
        )
    }
}

public enum MacFUSESetupEvidence: Equatable, Sendable {
    case notConfigured
    case trusted(SemanticVersion)
    case failedClosed(TrustedMacFUSEReadFailure)
}

public enum NTFS3GSetupEvidence: Equatable, Sendable {
    case notConfigured
    case trusted(SemanticVersion)
    case failedClosed(TrustedNTFS3GArtifactFailure)
}

public struct SetupAuthorizationStatusProvider: Sendable {
    private let loadStatus: @Sendable () async -> SetupAuthorizationStatus

    public init(
        _ loadStatus: @escaping @Sendable () async -> SetupAuthorizationStatus
    ) {
        self.loadStatus = loadStatus
    }

    public func currentStatus() async -> SetupAuthorizationStatus {
        await loadStatus()
    }
}

public struct SystemSetupReport: Equatable, Sendable {
    public let facts: SetupFacts
    public let macFUSEEvidence: MacFUSESetupEvidence
    public let ntfs3GEvidence: NTFS3GSetupEvidence
    public let authorizationStatus: SetupAuthorizationStatus
    public let probeResult: SetupProbeResult

    public init(
        facts: SetupFacts,
        macFUSEEvidence: MacFUSESetupEvidence,
        ntfs3GEvidence: NTFS3GSetupEvidence,
        authorizationStatus: SetupAuthorizationStatus,
        probeResult: SetupProbeResult
    ) {
        self.facts = facts
        self.macFUSEEvidence = macFUSEEvidence
        self.ntfs3GEvidence = ntfs3GEvidence
        self.authorizationStatus = authorizationStatus
        self.probeResult = probeResult
    }

    /// Reconciles duplicated system evidence conservatively. A report can be
    /// constructed outside the live loader, so agreement between its typed
    /// evidence and flattened facts is itself part of Setup readiness.
    public var reconciledFacts: SetupFacts {
        let trustedMacFUSEVersion = macFUSEEvidence.version
        let trustedNTFS3GVersion = ntfs3GEvidence.version
        let reportedDrivers = Set(facts.conflictingDrivers)
        let probedDrivers = Set(probeResult.conflictingDriverIdentifiers)
        let driversAgree = reportedDrivers == probedDrivers
        let extensionEnabled = facts.fileSystemExtensionEnabled
            && probeResult.fileSystemExtensionEnabled

        return SetupFacts(
            macOSVersion: facts.macOSVersion,
            architecture: facts.architecture,
            macFUSEVersion: trustedMacFUSEVersion == facts.macFUSEVersion
                ? trustedMacFUSEVersion
                : nil,
            ntfs3GVersion: trustedNTFS3GVersion == facts.ntfs3GVersion
                ? trustedNTFS3GVersion
                : nil,
            fileSystemExtensionEnabled: extensionEnabled,
            selectedBackend: extensionEnabled && facts.selectedBackend == .fsKit
                ? .fsKit
                : .unknown,
            authorizationStatus: authorizationStatus == facts.authorizationStatus
                ? authorizationStatus
                : .unknown,
            conflictScanComplete: facts.conflictScanComplete
                && probeResult.conflictScanComplete
                && driversAgree,
            conflictingDrivers: Array(reportedDrivers.union(probedDrivers)).sorted()
        )
    }
}

public struct SystemSetupFactsLoader: Sendable {
    private let authorizationProvider: SetupAuthorizationStatusProvider
    private let commandProvider: SetupReadOnlyCommandProvider
    private let probePolicy: SetupProbePolicy
    private let conflictFootprintProvider: ConflictFootprintProvider
    private let macFUSEPolicy: TrustedMacFUSEPolicy?
    private let macFUSECodeSignatureEvidenceProvider: TrustedCodeSignatureEvidenceProvider
    private let ntfs3GArtifactPolicy: TrustedNTFS3GArtifactPolicy?

    public init(
        authorizationStatus: SetupAuthorizationStatus = .unknown,
        authorizationProvider: SetupAuthorizationStatusProvider? = nil,
        commandProvider: SetupReadOnlyCommandProvider = .live,
        probePolicy: SetupProbePolicy = .current,
        conflictFootprintProvider: ConflictFootprintProvider = .live,
        macFUSEPolicy: TrustedMacFUSEPolicy? = nil,
        macFUSECodeSignatureEvidenceProvider: TrustedCodeSignatureEvidenceProvider = .live,
        ntfs3GArtifactPolicy: TrustedNTFS3GArtifactPolicy? = nil
    ) {
        self.authorizationProvider = authorizationProvider
            ?? SetupAuthorizationStatusProvider { authorizationStatus }
        self.commandProvider = commandProvider
        self.probePolicy = probePolicy
        self.conflictFootprintProvider = conflictFootprintProvider
        self.macFUSEPolicy = macFUSEPolicy
        self.macFUSECodeSignatureEvidenceProvider = macFUSECodeSignatureEvidenceProvider
        self.ntfs3GArtifactPolicy = ntfs3GArtifactPolicy
    }

    public func currentFacts() async -> SetupFacts {
        await currentReport().facts
    }

    public func currentReport() async -> SystemSetupReport {
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
        let macOSVersion = SemanticVersion(
            major: operatingSystem.majorVersion,
            minor: operatingSystem.minorVersion,
            patch: operatingSystem.patchVersion
        )
        let architecture = Self.runtimeArchitecture
        let conflictEnvironment = ConflictCatalogEnvironment(
            macOSVersion: macOSVersion,
            architecture: architecture
        )
        async let pendingProbeResult = currentProbeResult(
            environment: conflictEnvironment
        )
        async let pendingAuthorizationStatus = authorizationProvider.currentStatus()
        let macFUSEEvidence = currentMacFUSEEvidence()
        let ntfs3GEvidence = currentNTFS3GEvidence()
        let (probeResult, authorizationStatus) = await (
            pendingProbeResult,
            pendingAuthorizationStatus
        )
        let evidence = SetupEnvironmentEvidence(
            macOSVersion: macOSVersion,
            architecture: architecture,
            macFUSEVersionText: macFUSEEvidence.versionText,
            ntfs3GVersionText: ntfs3GEvidence.versionText,
            fileSystemExtensionEnabled: probeResult.fileSystemExtensionEnabled,
            selectedBackend: probeResult.fileSystemExtensionEnabled ? .fsKit : .unknown,
            authorizationStatus: authorizationStatus,
            conflictScanComplete: probeResult.conflictScanComplete,
            conflictingDriverIdentifiers: probeResult.conflictingDriverIdentifiers
        )
        return SystemSetupReport(
            facts: SetupEnvironmentMapper.map(evidence),
            macFUSEEvidence: macFUSEEvidence,
            ntfs3GEvidence: ntfs3GEvidence,
            authorizationStatus: authorizationStatus,
            probeResult: probeResult
        )
    }

    public func provider() -> SetupFactsProvider {
        SetupFactsProvider {
            await currentFacts()
        }
    }

    private static var runtimeArchitecture: RuntimeArchitecture {
#if arch(arm64)
        .appleSilicon
#elseif arch(x86_64)
        .intel
#else
        .unknown
#endif
    }

    private func currentProbeResult(
        environment: ConflictCatalogEnvironment
    ) async -> SetupProbeResult {
        async let plugInKitOutputs = currentPlugInKitOutputs()
        async let systemExtensionOutput = currentSystemExtensionOutput()
        async let loadedKextOutput = currentLoadedKextOutput()
        return await SetupProbeEvaluator.evaluate(
            plugInKitOutputs: plugInKitOutputs,
            systemExtensionOutput: systemExtensionOutput,
            loadedKextOutput: loadedKextOutput,
            policy: probePolicy,
            environment: environment,
            footprintProvider: conflictFootprintProvider
        )
    }

    private func currentPlugInKitOutputs() async -> [String: SetupCommandOutput] {
        await withTaskGroup(
            of: (String, SetupCommandOutput).self,
            returning: [String: SetupCommandOutput].self
        ) { group in
            for identifier in probePolicy.acceptedFSKitIdentifiers {
                group.addTask { [commandProvider] in
                    let output = await commandProvider.output(
                        for: .plugInKit(identifier: identifier)
                    )
                    return (identifier, output)
                }
            }
            var outputs: [String: SetupCommandOutput] = [:]
            for await (identifier, output) in group {
                outputs[identifier] = output
            }
            return outputs
        }
    }

    private func currentSystemExtensionOutput() async -> SetupCommandOutput? {
        guard !probePolicy.conflictingSystemExtensionIdentifiers.isEmpty else {
            return nil
        }
        return await commandProvider.output(for: .systemExtensions)
    }

    private func currentLoadedKextOutput() async -> SetupCommandOutput? {
        guard !probePolicy.conflictingKextIdentifiers.isEmpty else {
            return nil
        }
        return await commandProvider.output(for: .loadedKexts)
    }

    private func currentMacFUSEEvidence() -> MacFUSESetupEvidence {
        guard let macFUSEPolicy else {
            return .notConfigured
        }
        switch TrustedMacFUSEEvidenceReader.read(
            policy: macFUSEPolicy,
            evidenceProvider: macFUSECodeSignatureEvidenceProvider
        ) {
        case let .trusted(version):
            return .trusted(version)
        case let .failedClosed(failure):
            return .failedClosed(failure)
        }
    }

    private func currentNTFS3GEvidence() -> NTFS3GSetupEvidence {
        guard let ntfs3GArtifactPolicy else {
            return .notConfigured
        }
        switch TrustedNTFS3GArtifactResolver.resolve(policy: ntfs3GArtifactPolicy) {
        case let .trusted(evidence):
            return .trusted(evidence.version)
        case let .failedClosed(failure):
            return .failedClosed(failure)
        }
    }
}

private extension MacFUSESetupEvidence {
    var version: SemanticVersion? {
        guard case let .trusted(version) = self else {
            return nil
        }
        return version
    }

    var versionText: String? {
        version.map { "\($0.major).\($0.minor).\($0.patch)" }
    }
}

private extension NTFS3GSetupEvidence {
    var version: SemanticVersion? {
        guard case let .trusted(version) = self else {
            return nil
        }
        return version
    }

    var versionText: String? {
        version.map { "\($0.major).\($0.minor).\($0.patch)" }
    }
}
