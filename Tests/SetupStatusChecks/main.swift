import Foundation
import NTFSLiteCore
import NTFSLitePresentation
import NTFSLiteReadOnlyProbing
import NTFSLiteSystem

@main
struct SetupStatusChecks {
    static func main() {
        let identifier = "io.macfuse.app.fsmodule.macfuse-local"
        let compact = SetupCommandOutput(standardOutput: "     \(identifier)((null))\n", terminationStatus: 0, wasTruncated: false)
        precondition(PlugInKitListingParser.parse(compact, allowedIdentifiers: [identifier]) == .parsed([
            PlugInKitRecord(identifier: identifier, election: .defaultElection)
        ]), "Actual compact null-version record must preserve registration without claiming enablement")
        let compactProbe = SetupProbeEvaluator.evaluate(plugInKitOutputs: [identifier: compact], systemExtensionOutput: nil, loadedKextOutput: nil, policy: .unconfigured(acceptedFSKitIdentifiers: [identifier]))
        precondition(compactProbe.fsKitModuleObservation == .presentActivationUnknown && !compactProbe.fileSystemExtensionEnabled)
        for invalid in [
            SetupCommandOutput(standardOutput: compact.standardOutput, terminationStatus: 0, wasTruncated: true),
            SetupCommandOutput(standardOutput: compact.standardOutput, standardError: "query failed", terminationStatus: 0, wasTruncated: false),
            SetupCommandOutput(standardOutput: compact.standardOutput, terminationStatus: 1, wasTruncated: false),
            SetupCommandOutput(standardOutput: compact.standardOutput + compact.standardOutput, terminationStatus: 0, wasTruncated: false),
            SetupCommandOutput(standardOutput: compact.standardOutput + "\\tPath = /unexpected\\n", terminationStatus: 0, wasTruncated: false)
        ] {
            guard case .failedClosed = PlugInKitListingParser.parse(invalid, allowedIdentifiers: [identifier]) else {
                fatalError("Malformed, duplicate, failed or incomplete module records must remain rejected")
            }
        }
        let facts = SetupFacts(macOSVersion: SemanticVersion(major: 27, minor: 0, patch: 0), architecture: .appleSilicon, macFUSEVersion: nil, ntfs3GVersion: nil, fileSystemExtensionEnabled: false, selectedBackend: .unknown, authorizationStatus: .unknown, conflictScanComplete: false, conflictingDrivers: [])
        let probe = SetupProbeEvaluator.evaluate(plugInKitOutputs: ["io.macfuse.app.fsmodule.macfuse-local": SetupCommandOutput(standardOutput: "io.macfuse.app.fsmodule.macfuse-local (5.1.3)", standardError: "", terminationStatus: 0, wasTruncated: false)], systemExtensionOutput: nil, loadedKextOutput: nil, policy: .unconfigured(acceptedFSKitIdentifiers: ["io.macfuse.app.fsmodule.macfuse-local"]))
        let report = SystemSetupReport(facts: facts, macFUSEEvidence: .notConfigured, ntfs3GEvidence: .notConfigured, authorizationStatus: .unknown, probeResult: probe)
        let presentation = SetupPresenter.presentation(for: report, isRefreshing: false)
        let conflicts = presentation.requirements.first { $0.id == .conflictingDrivers }!
        precondition(conflicts.statusText == "未接入", "Unconfigured independent conflict scope must not ask the user to retry")
        let module = presentation.requirements.first { $0.id == .fileSystemExtension }!
        precondition(module.statusText == "已发现", "A default-election FSKit record must be distinguished from missing or disabled")
        precondition(!presentation.isReady, "Partial diagnostic evidence must never produce Setup readiness")
        let product = SetupPresenter.presentation(for: report.recordingProtectedInstallation(true), isRefreshing: false)
        let driver = product.requirements.first { $0.id == .ntfs3G }!
        precondition(driver.state == .satisfied && driver.statusText == "已核验")
        precondition(driver.detail.contains("独立摘要版本目录未配置") && !driver.detail.contains("2022."))
        let backend = product.requirements.first { $0.id == .backend }!
        precondition(backend.state == .informational && backend.statusText == "操作前验证")
        precondition(!product.isReady, "Signed installation and a module record must not create runtime or disk readiness")
        let invalidInstall = SetupPresenter.presentation(for: report.recordingProtectedInstallation(false), isRefreshing: false)
        precondition(invalidInstall.requirements.first { $0.id == .ntfs3G }!.state == .actionRequired)

        let failedProbe = SetupProbeEvaluator.evaluate(plugInKitOutputs: ["io.macfuse.app.fsmodule.macfuse-local": SetupCommandOutput(standardOutput: "", standardError: "", terminationStatus: -1, wasTruncated: false)], systemExtensionOutput: nil, loadedKextOutput: nil, policy: .unconfigured(acceptedFSKitIdentifiers: ["io.macfuse.app.fsmodule.macfuse-local"]))
        let failedReport = SystemSetupReport(facts: facts, macFUSEEvidence: .notConfigured, ntfs3GEvidence: .notConfigured, authorizationStatus: .unknown, probeResult: failedProbe)
        let failed = SetupPresenter.presentation(for: failedReport, isRefreshing: false)
        precondition(failed.requirements.first { $0.id == .fileSystemExtension }!.state == .actionRequired)
        precondition(!failedProbe.fileSystemExtensionEnabled && !failedProbe.conflictScanComplete)

        let conflictReport = SystemSetupReport(facts: facts, macFUSEEvidence: .notConfigured, ntfs3GEvidence: .notConfigured, authorizationStatus: .unknown, probeResult: SetupProbeResult(fileSystemExtensionEnabled: false, conflictScanComplete: false, conflictingDriverIdentifiers: ["known-conflict-1"], conflictPolicyObservation: .notConfigured))
        let conflict = SetupPresenter.presentation(for: conflictReport, isRefreshing: false)
        precondition(conflict.requirements.first { $0.id == .conflictingDrivers }!.state == .actionRequired)
        precondition(conflict.requirements.first { $0.id == .conflictingDrivers }!.observedConflictCount == 1)
        let failedTrust = SetupPresenter.presentation(for: SystemSetupReport(facts: facts, macFUSEEvidence: .notConfigured, ntfs3GEvidence: .failedClosed(.invalidVersionCatalog), authorizationStatus: .unknown, probeResult: probe, protectedInstallationVerified: true), isRefreshing: false)
        precondition(failedTrust.requirements.first { $0.id == .ntfs3G }!.state == .actionRequired, "A separate failed digest policy must not be overwritten by product installation evidence")
        let version = SemanticVersion(major: 5, minor: 4, patch: 0)
        let driverVersion = SetupChecker.minimumNTFS3GVersion
        let fullyObservedFacts = SetupFacts(macOSVersion: facts.macOSVersion, architecture: facts.architecture, macFUSEVersion: version, ntfs3GVersion: driverVersion, fileSystemExtensionEnabled: true, selectedBackend: .fsKit, authorizationStatus: .granted, conflictScanComplete: true, conflictingDrivers: [])
        let fullyObserved = SystemSetupReport(facts: fullyObservedFacts, macFUSEEvidence: .trusted(version), ntfs3GEvidence: .trusted(driverVersion), authorizationStatus: .granted, probeResult: SetupProbeResult(fileSystemExtensionEnabled: true, conflictScanComplete: true, conflictingDriverIdentifiers: []), protectedInstallationVerified: true)
        let replacedInstall = SetupPresenter.presentation(for: fullyObserved.recordingProtectedInstallation(false), isRefreshing: false)
        precondition(replacedInstall.requirements.first { $0.id == .authorization }!.state == .actionRequired, "A failed current installation verification must invalidate earlier authorization evidence")
        precondition(!SetupPresenter.presentation(for: fullyObserved, isRefreshing: false).isReady, "A product report must not turn static observations into runtime image readiness")
        let invalidScope = ConflictCatalogScope(scopeID: "", target: ConflictCatalogTarget(macOSVersion: facts.macOSVersion, architecture: facts.architecture), evidenceDate: ConflictCatalogEvidenceDate(year: 2026, month: 10, day: 9), artifacts: [])
        let invalidPolicy = SetupProbeEvaluator.evaluate(plugInKitOutputs: [:], systemExtensionOutput: nil, loadedKextOutput: nil, policy: SetupProbePolicy(acceptedFSKitIdentifiers: [], candidateScope: invalidScope, activeScope: nil, environmentBaselineSatisfied: false))
        precondition(invalidPolicy.conflictPolicyObservation == .incomplete, "An invalid configured catalog must remain a failure, not neutral unconfigured policy")
        print("PASS: sourced setup observations preserve unknown readiness and actionable failures")
    }
}
