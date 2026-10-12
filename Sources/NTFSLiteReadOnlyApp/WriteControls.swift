import AppKit
import Foundation
import NTFSLiteCore
import NTFSLiteDiagnostics
import NTFSLiteHelperProtocol
import NTFSLiteHelperExecution
import NTFSLitePresentation
import NTFSLiteProtectedInstall
import NTFSLiteSystem
import NTFSLiteWriteSession
import ServiceManagement
import SwiftUI

@MainActor
private func announceWriteStatus(_ text: String) {
    guard !text.isEmpty else { return }
    AccessibilityNotification.Announcement(text).post()
}

/// Read-only current product evidence. No registration, disk mutation, or cached
/// runtime image result enters this report.
enum AppSetupEvidenceReader {
    static func protectedInstallationIsTrusted() -> Bool {
        SecureHelperDeployment.verifyInstalled(
            appIdentifier: HelperServiceIdentity.appIdentifier,
            helperIdentifier: HelperServiceIdentity.helperIdentifier,
            driverIdentifier: SecureHelperDeployment.driverIdentifier,
            probeIdentifier: SecureHelperDeployment.probeIdentifier,
            teamIdentifier: HelperServiceIdentity.teamIdentifier
        )
    }

    static func currentReport(using loader: SystemSetupFactsLoader) async -> SystemSetupReport {
        await SystemSetupReportFinalizer.currentReport(
            using: loader,
            authorizationProvider: SetupAuthorizationStatusProvider { await currentAuthorizationStatus() },
            installationVerifier: { protectedInstallationIsTrusted() }
        )
    }

    static func currentAuthorizationStatus() async -> SetupAuthorizationStatus {
        let service = SMAppService.daemon(plistName: HelperServiceIdentity.daemonPlistName)
        guard protectedInstallationIsTrusted() else { return .unknown }
        switch service.status {
        case .requiresApproval, .notRegistered: return .denied
        case .enabled:
            let reachable = await HelperXPCTransport().healthCheck()
            guard reachable, protectedInstallationIsTrusted(), service.status == .enabled else { return .unknown }
            return .granted
        default: return .unknown
        }
    }
}

/// XPC transport to the privileged helper (ADR 0010/0011). A connection that cannot be
/// established means nothing was delivered; an interruption after sending is an unknown outcome.
struct HelperXPCTransport: HelperTransport {
    static let replyTimeout: TimeInterval = 180
    static let healthTimeout: TimeInterval = 10

    func healthCheck() async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: HelperServiceIdentity.machServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: NTFSLiteHelperXPC.self)
            connection.setCodeSigningRequirement(HelperServiceIdentity.helperRequirement)
            let once = ResumeOnce(continuation, connection: connection)
            var uuidBytes = UUID().uuid
            let challenge = withUnsafeBytes(of: &uuidBytes) { Data($0) }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(false) }
                as? NTFSLiteHelperXPC
            guard let proxy else { once.resume(false); return }
            proxy.healthCheck(challenge) { reply in
                once.resume(HelperHealthCheck.accepts(reply, for: challenge))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.healthTimeout) { once.resume(false) }
        }
    }

    func prepareForReregistration() async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: HelperServiceIdentity.machServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: NTFSLiteHelperXPC.self)
            connection.setCodeSigningRequirement(HelperServiceIdentity.helperRequirement)
            let once = ResumeOnce(continuation, connection: connection)
            var bytes = UUID().uuid
            let challenge = withUnsafeBytes(of: &bytes) { Data($0) }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(false) } as? NTFSLiteHelperXPC
            guard let proxy else { once.resume(false); return }
            proxy.prepareForReregistration(challenge) { reply in
                once.resume(HelperMaintenanceCheck.accepts(reply, for: challenge))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.healthTimeout) { once.resume(false) }
        }
    }

    func send(_ request: Data) async -> HelperTransportResult {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: HelperServiceIdentity.machServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: NTFSLiteHelperXPC.self)
            connection.setCodeSigningRequirement(HelperServiceIdentity.helperRequirement)
            let once = ResumeOnce(continuation, connection: connection)
            connection.resume()
            // Once submit is invoked, even an invalidated connection cannot prove
            // that the helper did not receive and execute the request.
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                once.resume(.timedOut)
            } as? NTFSLiteHelperXPC
            guard let proxy else {
                once.resume(.unavailable)
                return
            }
            proxy.submit(request) { reply in once.resume(.reply(reply)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.replyTimeout) { once.resume(.timedOut) }
        }
    }
}

private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private let connection: NSXPCConnection

    init(_ continuation: CheckedContinuation<Value, Never>, connection: NSXPCConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func resume(_ result: Value) {
        let pending = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            defer { continuation = nil }
            return continuation
        }
        guard let pending else { return }
        connection.invalidate()
        pending.resume(returning: result)
    }
}

/// Records each submitted fixed action before its outcome reaches the controller.
/// Target identity stays in memory; archives receive only Diagnostics numeric aliases.
actor DiagnosticHelperTransport: HelperTransport {
    private struct WireRequest: Decodable {
        let operationID: HelperOperationID
        let action: HelperAction
        let target: HelperTarget
    }
    private let transport: any HelperTransport
    private let diagnostics: Diagnostics
    private var targets: [String: DiagnosticTarget] = [:]

    init(transport: any HelperTransport, diagnostics: Diagnostics) {
        self.transport = transport
        self.diagnostics = diagnostics
    }

    private static func resultStage(action: HelperAction, response: HelperResponseEnvelope) -> DiagnosticOperationStage {
        if response.resultCode == .rejectedRuntimeResourcesHeld { return .inspectSafety }
        if response.resultCode == .succeeded {
            switch action {
            case .mountReadWrite: return .inspectWriteMount
            case .unmountVolume, .unmountDisk: return .inspectPhysicalDiskAfterUnmount
            case .ejectDisk: return .inspectPhysicalDiskAfterEject
            }
        }
        guard response.resultCode == .executionFailed || response.resultCode == .stateChangedQuiescent
            || response.resultCode == .postconditionFailed else { return .reconcile }
        if action == .mountReadWrite, let failure = WritableMountFailure(rawValue: response.exitStatus) {
            switch failure {
            case .nativeUnmountFailed: return .unmountReadOnly
            case .driverStartFailed: return .mountWrite
            case .mountNotObserved, .mountNotVerified: return .inspectWriteMount
            default: return .inspectSafety
            }
        }
        if let failure = DiskReleaseFailure(rawValue: response.exitStatus) {
            switch failure {
            case .driverNotExited: return .waitForProcessExit
            case .unmountRefused: return .unmountPhysicalDisk
            case .stillMounted, .mountPointNotRemoved: return .inspectPhysicalDiskAfterUnmount
            case .ejectRefused: return .ejectPhysicalDisk
            case .ejectNotConfirmed: return .inspectPhysicalDiskAfterEject
            default: return .inspectSafety
            }
        }
        return .reconcile
    }

    func send(_ data: Data) async -> HelperTransportResult {
        let started = ContinuousClock.now
        let result = await transport.send(data)
        guard let request = try? JSONDecoder().decode(WireRequest.self, from: data) else { return result }
        let disk: HelperDiskInstanceIdentity
        switch request.target {
        case let .disk(identity): disk = identity
        case let .volume(identity): disk = identity.disk
        }
        var stage: DiagnosticOperationStage
        switch request.action {
        case .mountReadWrite: stage = .mountWrite
        case .unmountDisk: stage = .unmountPhysicalDisk
        case .ejectDisk: stage = .ejectPhysicalDisk
        case .unmountVolume: stage = .unmountReadOnly
        }
        var code: Int32?
        let certainty: DiagnosticResultCertainty
        let diagnosticResult: DiagnosticResultCode
        switch result {
        case .unavailable: stage = .reconcile; certainty = .unchanged; diagnosticResult = .dependencyUnavailable
        case .timedOut: stage = .reconcile; certainty = .unknown; diagnosticResult = .timedOut
        case let .reply(reply):
            if case let .success(response) = HelperResponseDecoder().decode(reply) {
                code = response.exitStatus
                stage = Self.resultStage(action: request.action, response: response)
                let knownStage = request.action == .mountReadWrite
                    ? WritableMountFailure(rawValue: response.exitStatus) != nil
                    : DiskReleaseFailure(rawValue: response.exitStatus) != nil
                switch response.resultCode {
                case .succeeded: certainty = .verified; diagnosticResult = .succeeded
                case .stateChangedQuiescent:
                    certainty = knownStage ? .changedQuiescent : .unknown; diagnosticResult = .engineFailed
                case .executionFailed:
                    certainty = knownStage ? .unchanged : .unknown; diagnosticResult = .engineFailed
                case .postconditionFailed: certainty = .unknown; diagnosticResult = .inspectionUnavailable
                case .rejectedRuntimeResourcesHeld: certainty = .unchanged; diagnosticResult = .engineFailed
                default: certainty = .unchanged; diagnosticResult = .rejected
                }
            } else { stage = .reconcile; certainty = .unknown; diagnosticResult = .inspectionUnavailable }
        }
        do {
            let key = "\(disk.physicalDiskBSDName):\(disk.mediaGeneration):\(disk.registryEntryID)"
            let elapsed = started.duration(to: .now).components
            let milliseconds = UInt64(max(0, elapsed.seconds)) * 1_000 + UInt64(max(0, elapsed.attoseconds / 1_000_000_000_000_000))
            let kind: DiagnosticOperationKind = request.action == .mountReadWrite ? .enableWriting : .safeEject
            let traceID = UUID(uuidString: request.operationID.rawValue)
            targets[key] = try await diagnostics.recordDiskOperation(
                reusing: targets[key], mediaGeneration: disk.mediaGeneration
            ) { [stage, code] target in
                DiagnosticOperationEvent(
                    target: target, kind: kind, stage: stage, result: diagnosticResult,
                    exitStatus: nil, elapsedMilliseconds: milliseconds,
                    traceID: traceID, helperStageCode: code, certainty: certainty
                )
            }
        } catch {
            // Diagnostic failure cannot promote any disk result or authorize a retry.
        }
        return result
    }
}

/// Structured injectable service boundary; production actions retain SMAppService and signed XPC.
@MainActor
struct HelperServiceEnvironment {
    var status: () -> SMAppService.Status
    var trust: () -> Bool
    var protectedLaunch: () -> Bool
    var register: () throws -> Void
    var unregister: () async throws -> Void
    var health: () async -> Bool
    var prepare: () async -> Bool

    static var live: Self {
        let service = SMAppService.daemon(plistName: HelperServiceIdentity.daemonPlistName)
        return Self(status: { service.status }, trust: { AppSetupEvidenceReader.protectedInstallationIsTrusted() },
                    protectedLaunch: { HelperEnablementUI.shouldOfferRegistration(for: Bundle.main.bundleURL) },
                    register: { try service.register() }, unregister: { try await service.unregister() },
                    health: { await HelperXPCTransport().healthCheck() },
                    prepare: { await HelperXPCTransport().prepareForReregistration() })
    }
}

/// The overview keeps a session record visible while its helper or disk facts
/// change. This pure state decides whether that record still offers eject.
struct OverviewEjectAvailability: Equatable {
    let canEject: Bool
    let reason: String?

    init(
        helperState: HelperServiceState,
        isBusy: Bool,
        isUnresolved: Bool,
        sessionEjectable: Bool
    ) {
        if helperState != .enabled {
            canEject = false
            reason = helperState.text
        } else if isBusy {
            canEject = false
            reason = "正在处理这块磁盘，请等待操作结束。"
        } else if isUnresolved {
            canEject = false
            reason = "磁盘操作结果尚未确认，当前会话已暂停安全推出。"
        } else if !sessionEjectable {
            canEject = false
            reason = "当前无法核对这块磁盘的完整分区布局，请重新读取后查看卷详情。"
        } else {
            canEject = true
            reason = nil
        }
    }
}

struct WriteVolumeRecord: Equatable, Identifiable {
    let id: VolumeInstanceID
    let title: String
    let diskTitle: String
    let binding: HelperDiskInstanceIdentity

    var displayName: String { "\(diskTitle) · 卷「\(title)」" }
}

struct WriteNotice: Equatable, Identifiable {
    let id: UUID
    let text: String
    let requiresAttention: Bool
}

@MainActor
final class WriteController: ObservableObject {
    @Published private(set) var helperState: HelperServiceState = .notRegistered
    @Published private(set) var busyDisks: Set<PhysicalDiskID> = []
    @Published private(set) var progressByDisk: [PhysicalDiskID: String] = [:]
    @Published private(set) var writableVolumes: [WriteVolumeRecord] = []
    @Published private(set) var releasePendingVolumes: [WriteVolumeRecord] = []
    var sessionVolumes: [WriteVolumeRecord] { writableVolumes + releasePendingVolumes }
    @Published private(set) var sessionEjectableVolumes: Set<VolumeInstanceID> = []
    @Published private(set) var lastMessage: String?
    @Published private(set) var recentNotices: [WriteNotice] = []
    @Published private(set) var helperMessage: String?
    @Published private(set) var isReregisteringHelper = false
    @Published private(set) var lastOutcomeByDisk: [DiskInstanceID: WriteOutcome] = [:]

    private let session: WriteSession
    private let service: HelperServiceEnvironment
    private let operationCompleted: @MainActor () async -> Void
    private let refreshObservation: @MainActor () -> Void
    private let canRequestWriting: @MainActor (VolumeInstanceID) -> Bool
    private let canRequestEject: @MainActor (DiskInstanceID) -> Bool
    private var ledger = WriteInteractionLedger()
    private var observedDisks: Set<DiskInstanceID> = []
    private var observationCoverageVerified = false
    private var latestObservation: DiskInventoryObservation?
    private var sessionDiskLabels: [DiskInstanceID: String] = [:]
    private var nextSessionDiskNumber = 1
    private var helperCheckToken = UUID()

    private func protectedInstallationIsTrusted() -> Bool { service.trust() }

    init(
        service: HelperServiceEnvironment = .live,
        transport: any HelperTransport = HelperXPCTransport(),
        operationCompleted: @escaping @MainActor () async -> Void = {},
        refreshObservation: @escaping @MainActor () -> Void,
        canRequestWriting: @escaping @MainActor (VolumeInstanceID) -> Bool,
        canRequestEject: @escaping @MainActor (DiskInstanceID) -> Bool
    ) {
        self.service = service
        self.session = WriteSession(transport: transport)
        self.operationCompleted = operationCompleted
        self.refreshObservation = refreshObservation
        self.canRequestWriting = canRequestWriting
        self.canRequestEject = canRequestEject
        refreshHelperState()
    }

    func refreshHelperState() {
        guard !isReregisteringHelper else { return }
        helperCheckToken = UUID()
        let token = helperCheckToken
        guard service.protectedLaunch() else {
            helperState = .requiresProtectedInstallation
            helperMessage = nil
            return
        }
        guard protectedInstallationIsTrusted() else {
            helperState = .unavailable
            helperMessage = "受保护安装件的属主、权限、文件清单或签名无法核验；请重新安装后检查。"
            return
        }
        switch service.status() {
        case .enabled:
            helperState = .checkingConnection
            Task {
                let reachable = await service.health()
                guard helperCheckToken == token else { return }
                guard protectedInstallationIsTrusted() else {
                    helperState = .unavailable
                    helperMessage = "受保护安装件已无法核验；当前不开放磁盘操作。"
                    return
                }
                switch service.status() {
                case .enabled:
                    helperState = reachable ? .enabled : .unreachable
                    if reachable { helperMessage = nil }
                case .requiresApproval:
                    helperState = .requiresApproval
                case .notRegistered:
                    helperState = .notRegistered
                case .notFound:
                    helperState = .notFound
                default:
                    helperState = .unavailable
                }
            }
        case .requiresApproval:
            helperState = .requiresApproval
        case .notRegistered:
            helperState = .notRegistered
        case .notFound:
            helperState = .notFound
        default:
            helperState = .unavailable
        }
    }

    func installHelper() {
        guard service.protectedLaunch() else {
            helperState = .requiresProtectedInstallation
            return
        }
        guard protectedInstallationIsTrusted() else {
            helperState = .unavailable
            helperMessage = "受保护安装件的属主、权限、文件清单或签名无法核验；不能注册帮助程序。"
            return
        }
        guard helperState.canAttemptRegistration else { return }
        guard service.status() == .notRegistered || service.status() == .notFound else {
            refreshHelperState()
            return
        }
        helperMessage = nil
        do {
            try service.register()
        } catch {
            let failure = error as NSError
            let diagnostic = HelperRegistrationDiagnostic.suffix(
                domain: failure.domain, code: failure.code
            )
            if failure.domain == SMAppServiceErrorDomain,
               failure.code == Int(kSMErrorInvalidSignature) {
                helperMessage = "系统拒绝了应用签名。当前安装件不能启用帮助程序；请核对签名与公证条件。\(diagnostic)"
            } else if failure.domain == SMAppServiceErrorDomain,
                      failure.code == Int(kSMErrorLaunchDeniedByUser) {
                helperMessage = "帮助程序尚未获得管理员批准。请到系统设置中允许后重新检查。\(diagnostic)"
            } else {
                helperMessage = "帮助程序注册未完成。请重新检查状态、受保护安装与系统批准。\(diagnostic)"
            }
        }
        refreshHelperState()
        if helperState == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// Unregisters the enabled-but-unreachable service, waits for the system to finish, and
    /// registers it again so Background Task Management rebuilds its records for this bundle.
    func reregisterHelper() {
        guard service.protectedLaunch() else {
            helperState = .requiresProtectedInstallation
            return
        }
        guard protectedInstallationIsTrusted() else {
            helperState = .unavailable
            helperMessage = "受保护安装件的属主、权限、文件清单或签名无法核验；不能重新注册帮助程序。"
            return
        }
        guard !isReregisteringHelper, helperState.canAttemptReregistration,
              service.status() == .enabled, !hasBoundDiskSession else {
            helperMessage = "当前存在绑定磁盘会话或状态无法确认，不能注销帮助程序。"
            return
        }
        isReregisteringHelper = true
        helperCheckToken = UUID()
        helperState = .unavailable
        helperMessage = "正在取得帮助程序的新鲜全局静止证明，请稍候。"
        Task { @MainActor in
            defer { isReregisteringHelper = false }
            let proof = await service.prepare()
            guard proof, service.protectedLaunch(), protectedInstallationIsTrusted(),
                  HelperReregistrationPolicy.mayProceed(
                    state: .unreachable, systemReportsEnabled: service.status() == .enabled,
                    hasBusyDisk: !busyDisks.isEmpty, hasBoundDiskSession: hasBoundDiskSession,
                    hasFreshQuiescenceProof: proof
                  ) else {
                helperState = .unreachable
                helperMessage = "未取得有效的全局静止证明或当前条件已变化；未注销帮助程序。"
                return
            }
            do {
                try await service.unregister()
            } catch {
                let failure = error as NSError
                helperMessage = "帮助程序注销未完成，未重新注册。请重新检查状态。"
                    + HelperRegistrationDiagnostic.suffix(domain: failure.domain, code: failure.code)
                refreshHelperState()
                return
            }
            guard protectedInstallationIsTrusted() else {
                helperState = .unavailable
                helperMessage = "帮助程序已注销，但受保护安装件已无法核验；未重新注册。"
                return
            }
            guard service.status() == .notRegistered || service.status() == .notFound else {
                helperMessage = "帮助程序注销后系统状态无法确认，未重新注册。请重新检查。"
                refreshHelperState()
                return
            }
            helperMessage = nil
            do {
                try service.register()
            } catch {
                let failure = error as NSError
                helperMessage = "帮助程序已注销，但重新注册未完成。请重新检查状态与系统批准。"
                    + HelperRegistrationDiagnostic.suffix(domain: failure.domain, code: failure.code)
            }
            isReregisteringHelper = false
            refreshHelperState()
            if helperState == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }

    func openHelperApprovalSettings() {
        guard helperState == .requiresApproval else { return }
        SMAppService.openSystemSettingsLoginItems()
    }

    func openMountedVolumesInFinder(for volume: VolumeInstanceID) {
        guard canOpenSessionFinder(volume),
              !isBusy(volume.diskInstanceID),
              !isUnresolved(volume.diskInstanceID) else { return }
        let volumesDirectory = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard NSWorkspace.shared.open(volumesDirectory) else {
            let target = writableVolumes.first { $0.id == volume }?.displayName ?? "所选卷"
            lastMessage = "\(target)：无法打开已挂载磁盘列表。请手动在访达“位置”中查看并核对目标卷。"
            if let lastMessage { recordNotice(lastMessage, requiresAttention: false) }
            return
        }
    }

    var hasBoundDiskSession: Bool {
        !sessionVolumes.isEmpty || !busyDisks.isEmpty || !ledger.unresolvedDisks.isEmpty
    }

    func isBusy(_ disk: DiskInstanceID) -> Bool { busyDisks.contains(disk.physicalDiskID) }

    func isWritable(_ volume: VolumeInstanceID) -> Bool { writableVolumes.contains { $0.id == volume } }

    func isUnresolved(_ disk: DiskInstanceID) -> Bool { !ledger.canStartOperation(on: disk) }

    func sessionDiskLabel(for disk: DiskInstanceID) -> String? { sessionDiskLabels[disk] }

    func canEjectSessionVolume(_ volume: VolumeInstanceID) -> Bool {
        sessionVolumes.contains { $0.id == volume } && sessionEjectableVolumes.contains(volume)
    }

    func overviewExplanation(for dashboard: ReadOnlyDashboardPresentation) -> (title: String, detail: String) {
        let original = (title: dashboard.title, detail: dashboard.detail)
        guard dashboard.phase == .limited, helperState == .enabled, !isReregisteringHelper,
              let observation = latestObservation, observation.issues.isEmpty else { return original }
        var hasPendingNativeIdentity = false
        var hasUnclassifiedFUSESource = false
        var hasOtherUnconfirmedDisk = false
        for disk in observation.physicalDisks {
            // This explanation concerns retained external NTFS sessions. Typed APFS
            // container omissions are separate from NTFS identity failures; generic
            // FUSE sources retain the original warning. No capability is changed.
            if disk.volumes.isEmpty {
                guard !sessionVolumes.contains(where: { $0.id.diskInstanceID == disk.instanceID }) else { return original }
                // No rows means unknown, not non-NTFS. Keep the full original
                // warning alongside the independently verified session context.
                hasOtherUnconfirmedDisk = true
                continue
            }
            for volume in disk.volumes {
                if volume.isRecognizedUnMountedEFIPartition(on: disk) { continue }
                let fileSystem = volume.evidence.fileSystemName?.lowercased()
                let content = volume.evidence.mediaContent?.lowercased()
                let looksNTFS = fileSystem == "ntfs" || content == "windows_ntfs"
                    || content == "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7"
                    || volume.evidence.mediaContentHint?.lowercased() == "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7"
                if !looksNTFS {
                    if fileSystem == "macfuse" {
                        // macFUSE is a generic platform, not proof that this row
                        // is unrelated to NTFS. Keep the original global warning.
                        hasUnclassifiedFUSESource = true
                        continue
                    }
                    let apfsContainer = content == "7c3457ef-0000-11aa-aa11-00306543ecac"
                        || content == "41504653-0000-11aa-aa11-00306543ecac"
                    let builtInContainer = disk.description.isInternal == true && (
                        content == "69646961-6700-11aa-aa11-00306543ecac"
                        || content == "52637672-7900-11aa-aa11-00306543ecac"
                    )
                    guard fileSystem == "apfs" || apfsContainer || builtInContainer else { return original }
                    // Only the omissions observed on the system's APFS/container
                    // records are presentation-neutral; conflicts remain visible.
                    guard disk.issues.allSatisfy({ issue in
                        if case let .missingPhysicalLocation(name) = issue {
                            return name == disk.description.bsdName && disk.description.isInternal == nil
                        }
                        return false
                    }), volume.issues.allSatisfy({ issue in
                        switch issue {
                        case .missingVolumeUUID, .missingDisplayName, .missingFileSystemName,
                             .missingLocation, .unknownVolumeRole: return true
                        default: return false
                        }
                    }) else { return original }
                    continue
                }
                guard disk.issues.isEmpty, disk.description.isInternal == false,
                      volume.issues.allSatisfy({ issue in
                          issue == .unknownVolumeRole || issue == .missingDisplayName || issue == .missingVolumeUUID
                      }) else { return original }
                guard volume.issues.contains(.missingVolumeUUID) else { continue }
                guard volume.evidence.volumeUUID == nil, volume.snapshot == nil, volume.candidate == nil,
                      fileSystem == "ntfs",
                      let record = writableVolumes.first(where: {
                          $0.id.diskInstanceID == disk.instanceID && $0.id.volumeID.bsdName == volume.evidence.bsdName
                      }), !isBusy(disk.instanceID), !isUnresolved(disk.instanceID),
                      canEjectSessionVolume(record.id) else { return original }
                hasPendingNativeIdentity = true
            }
        }
        guard hasPendingNativeIdentity else { return original }
        var detail = "原生分区身份待确认，请用下方会话安全推出。操作记录不代表当前已验证可写；帮助程序仍会核对当前整盘事实。"
        if hasUnclassifiedFUSESource {
            detail += " 其他 FUSE 挂载的身份与物理信息仍待确认。"
        }
        if hasOtherUnconfirmedDisk {
            detail += " 另有无卷信息的磁盘，身份与物理信息仍待确认。"
        }
        if hasUnclassifiedFUSESource || hasOtherUnconfirmedDisk { detail += original.detail }
        return ("本次会话已启用写入", detail)
    }

    func canOpenSessionFinder(_ volume: VolumeInstanceID) -> Bool {
        isWritable(volume) && observationCoverageVerified && observedDisks.contains(volume.diskInstanceID)
    }

    func message(for disk: DiskInstanceID) -> String? {
        guard let outcome = lastOutcomeByDisk[disk] else { return nil }
        let explanation = WriteOutcomeText.text(outcome)
        return isUnresolved(disk)
            ? explanation + " 本次会话已暂停对此磁盘的其他操作。"
            : explanation
    }

    func reconcile(observation: DiskInventoryObservation) {
        latestObservation = observation
        let coverageVerified = observation.issues.isEmpty
        let disks = Set(observation.physicalDisks.map(\.instanceID))
        let previousRecords = sessionVolumes
        ledger.reconcileObservedDisks(disks, coverageVerified: coverageVerified)
        if coverageVerified {
            observedDisks = disks
        }
        observationCoverageVerified = coverageVerified
        writableVolumes.removeAll { !ledger.writableVolumes.contains($0.id) }
        releasePendingVolumes.removeAll { !ledger.releasePendingVolumes.contains($0.id) }
        sessionEjectableVolumes = Set(sessionVolumes.filter { record in
            WriteSession.canOfferSessionEject(
                record.id.diskInstanceID,
                binding: record.binding,
                in: observation
            )
        }.map(\.id))
        // Fresh absence immediately revokes session actions. While a helper operation
        // is pending, its terminal result owns the explanation; absence is not a
        // reason to blame a user disconnect or infer successful eject.
        let disconnected = previousRecords.filter {
            !ledger.writableVolumes.contains($0.id) && !ledger.releasePendingVolumes.contains($0.id)
                && !isBusy($0.id.diskInstanceID)
        }
        if !disconnected.isEmpty {
            let targets = disconnected.map(\.displayName).joined(separator: "、")
            lastMessage = "\(targets)已断开，本次会话记录已清除；无法确认曾安全推出。若已直接拔出，请检查磁盘状态。"
            for record in disconnected { lastOutcomeByDisk.removeValue(forKey: record.id.diskInstanceID) }
            if let lastMessage { recordNotice(lastMessage, requiresAttention: true) }
        }
    }

    @discardableResult
    func enableWriting(_ volume: VolumeInstanceID, title: String) -> Bool {
        func refuse(_ reason: String) -> Bool {
            let message = "\(title)：本次写入请求未提交。" + reason
            lastMessage = message
            recordNotice(message, requiresAttention: true)
            return false
        }
        guard !isReregisteringHelper, helperState == .enabled else {
            return refuse(helperState == .checkingConnection
                ? "正在验证后台连接，请等待检查完成后再次确认。"
                : helperState.text + " 请在运行环境中检查帮助程序。")
        }
        guard !isBusy(volume.diskInstanceID) else {
            return refuse("这块磁盘正在处理另一项请求，请等待结果。")
        }
        guard !sessionVolumes.contains(where: { $0.id.diskInstanceID.physicalDiskID == volume.diskInstanceID.physicalDiskID }) else {
            return refuse("本次连接已有写入或待释放会话，请先完成安全推出。")
        }
        guard !isUnresolved(volume.diskInstanceID) else {
            return refuse("上次操作结果尚未确认，不能再次提交。")
        }
        guard let observation = latestObservation else {
            return refuse("尚未取得当前磁盘信息，请重新读取。")
        }
        guard canRequestWriting(volume) else {
            return refuse("当前操作条件正在复核或已变化。请等待检查完成；若仍无法提交，请重新读取并选择目标卷。")
        }
        guard let binding = WriteSession.diskIdentity(
            volume.diskInstanceID, target: volume, in: observation
        ) else {
            return refuse("当前卷身份或分区信息未通过核对，请重新读取并选择目标卷。")
        }
        let diskTitle = labelForOperation(on: volume.diskInstanceID)
        run(volume.diskInstanceID, displayName: "\(diskTitle) · 卷「\(title)」") { session in
            await session.enableWriting(volume, in: observation, confirmedAsDataVolume: true)
        } after: { outcome in
            self.ledger.recordEnable(outcome, for: volume)
            if self.ledger.writableVolumes.contains(volume), !self.isWritable(volume) {
                self.writableVolumes.append(WriteVolumeRecord(
                    id: volume, title: title, diskTitle: diskTitle,
                    binding: binding
                ))
            }
            self.releasePendingVolumes.removeAll { !self.ledger.releasePendingVolumes.contains($0.id) }
            if self.ledger.releasePendingVolumes.contains(volume), !self.releasePendingVolumes.contains(where: { $0.id == volume }) {
                self.releasePendingVolumes.append(WriteVolumeRecord(id: volume, title: title, diskTitle: diskTitle, binding: binding))
            }
        }
        return true
    }

    func safeEject(_ disk: DiskInstanceID, title: String) {
        let sessionEject = sessionVolumes.contains {
            $0.id.diskInstanceID == disk && canEjectSessionVolume($0.id)
        }
        guard !isReregisteringHelper, helperState == .enabled, canRequestEject(disk) || sessionEject,
              let observation = latestObservation else { return }
        let displayName = "\(labelForOperation(on: disk)) · 卷「\(title)」"
        run(disk, displayName: displayName) { session in
            await session.safeEject(disk, in: observation)
        } after: { outcome in
            self.ledger.recordEject(outcome, for: disk)
            let previous = self.sessionVolumes
            self.writableVolumes.removeAll { !self.ledger.writableVolumes.contains($0.id) }
            self.releasePendingVolumes = previous.filter { self.ledger.releasePendingVolumes.contains($0.id) }
        }
    }

    private func labelForOperation(on disk: DiskInstanceID) -> String {
        if let existing = sessionDiskLabels[disk] { return existing }
        let label = "本次会话磁盘 \(nextSessionDiskNumber)"
        nextSessionDiskNumber += 1
        sessionDiskLabels[disk] = label
        return label
    }

    func dismissNotice(_ id: UUID) {
        recentNotices.removeAll { $0.id == id }
    }

    private func recordNotice(_ message: String, requiresAttention: Bool) {
        recentNotices.removeAll { $0.text == message }
        recentNotices.insert(WriteNotice(
            id: UUID(), text: message, requiresAttention: requiresAttention
        ), at: 0)
        var ordinaryCount = 0
        recentNotices = recentNotices.filter { notice in
            if notice.requiresAttention { return true }
            ordinaryCount += 1
            return ordinaryCount <= 5
        }
        announceWriteStatus(message)
    }

    private func run(
        _ disk: DiskInstanceID,
        displayName: String,
        _ operation: @escaping @MainActor (WriteSession) async -> WriteOutcome,
        after: @escaping @MainActor (WriteOutcome) -> Void
    ) {
        guard ledger.canStartOperation(on: disk),
              busyDisks.insert(disk.physicalDiskID).inserted else { return }
        lastOutcomeByDisk.removeValue(forKey: disk)
        lastMessage = "\(displayName)：正在核对并处理，请稍候。"
        progressByDisk[disk.physicalDiskID] = lastMessage
        if let lastMessage { announceWriteStatus(lastMessage) }
        Task { @MainActor in
            let outcome = await operation(session)
            after(outcome)
            await operationCompleted()
            busyDisks.remove(disk.physicalDiskID)
            progressByDisk.removeValue(forKey: disk.physicalDiskID)
            lastOutcomeByDisk[disk] = outcome
            lastMessage = message(for: disk).map { "\(displayName)：\($0)" }
            if let lastMessage {
                let requiresAttention: Bool = switch outcome {
                case .writingEnabled, .ejected: false
                case .refused, .needsRefresh, .changedAndStopped: true
                }
                recordNotice(lastMessage, requiresAttention: requiresAttention)
            }
            refreshHelperState()
            refreshObservation()
        }
    }
}

/// The visible actions consume the presentation policy; the helper repeats all safety checks.
struct VolumeWriteActions: View {
    @ObservedObject var controller: WriteController
    let volume: ReadOnlyVolumePresentation
    let physicalDisk: ReadOnlyPhysicalDiskPresentation
    let openEnvironment: () -> Void
    @State private var isConfirmingWrite = false
    @State private var declarationAccepted = false
    @State private var isConfirmingEject = false
    @State private var writeSubmissionMessage: String?

    private var canOfferEject: Bool {
        volume.actions.canSafeEject || controller.canEjectSessionVolume(volume.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("下一步", systemImage: "hand.tap")
                .font(.headline)

            if controller.isBusy(volume.id.diskInstanceID) {
                ProgressView("正在核对并处理磁盘，请勿断开连接")
                    .fixedSize(horizontal: false, vertical: true)
                Text("操作完成后会重新读取系统状态。请勿在此期间直接拔出磁盘。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if controller.isUnresolved(volume.id.diskInstanceID) {
                Label("结果尚未确认，请勿直接拔出。此会话已暂停对这块磁盘的其他操作。",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !volume.actions.canEnableWriting && !canOfferEject {
                Text(volume.actions.writeReason)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if volume.actions.ejectReason != volume.actions.writeReason {
                    Text(volume.actions.ejectReason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if controller.helperState != .enabled {
                Text(controller.helperState.text)
                    .fixedSize(horizontal: false, vertical: true)
                Button("查看运行环境", action: openEnvironment)
                    .buttonStyle(.borderedProminent)
            } else {
                if controller.isWritable(volume.id) {
                    Text("\(controller.sessionDiskLabel(for: volume.id.diskInstanceID) ?? "本次会话目标")的写入请求曾成功。当前挂载状态可能已变化；请在访达的已挂载磁盘列表核对目标，卷名也可能变化。完成后安全推出整块磁盘。")
                        .fixedSize(horizontal: false, vertical: true)
                } else if volume.actions.canEnableWriting {
                    Text("可以提交一次写入请求。帮助程序会在卸载前确认 FSKit 运行能力与磁盘安全条件，并在挂载后核对结果。")
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(volume.actions.writeReason)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { operationButtons }
                    VStack(alignment: .leading, spacing: 10) { operationButtons }
                }

                if !canOfferEject {
                    Text(volume.actions.ejectReason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let message = controller.message(for: volume.id.diskInstanceID) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(controller.isUnresolved(volume.id.diskInstanceID) ? Color.orange : Color.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let helperMessage = controller.helperMessage {
                Text(helperMessage)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 15))
        .sheet(isPresented: $isConfirmingWrite) {
            writeConfirmation
        }
        .confirmationDialog("安全推出整块物理磁盘？", isPresented: $isConfirmingEject) {
            Button("卸载并推出整块磁盘") {
                controller.safeEject(volume.id.diskInstanceID, title: volume.title)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将卸载并推出\(physicalDisk.title)，包含 \(physicalDisk.volumes.count) 个当前显示的 NTFS 卷及同盘其他分区。请先保存文件并关闭占用它们的应用。")
        }
        .onAppear { controller.refreshHelperState() }
    }

    @ViewBuilder
    private var operationButtons: some View {
        if controller.isWritable(volume.id) {
            Button("查看已挂载磁盘") { controller.openMountedVolumesInFinder(for: volume.id) }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.canOpenSessionFinder(volume.id))
        } else if volume.actions.canEnableWriting {
            Button("启用写入") {
                declarationAccepted = false
                writeSubmissionMessage = nil
                isConfirmingWrite = true
            }
            .buttonStyle(.borderedProminent)
        }
        if canOfferEject {
            Button("安全推出整块磁盘") { isConfirmingEject = true }
                .buttonStyle(.bordered)
        }
    }

    private var writeConfirmation: some View {
        VStack(alignment: .leading, spacing: 17) {
            Label("启用写入", systemImage: "externaldrive.badge.plus")
                .font(.title2.weight(.semibold))
            Text("目标：\(volume.title) · \(physicalDisk.title)")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text("帮助程序会在卸载前确认 FSKit 运行能力、卷身份与健康状态；通过后才卸载系统只读挂载，并核对新的挂载结果。")
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $declarationAccepted) {
                Text("我确认所选卷是普通数据卷，不是 Windows 启动卷或系统卷。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("这项能力仅完成有限的实物验证，尚未完成 Windows 端复核。请先备份重要数据；用完后安全推出。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("请保持应用打开直到安全推出；当前版本在应用重启后可能无法恢复这块磁盘的推出入口。")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if let writeSubmissionMessage {
                Text(writeSubmissionMessage)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(writeSubmissionMessage)
            }
            HStack {
                Spacer()
                Button("取消") { isConfirmingWrite = false }
                    .keyboardShortcut(.cancelAction)
                Button("确认并启用写入") {
                    if controller.enableWriting(volume.id, title: volume.title) {
                        writeSubmissionMessage = nil
                        isConfirmingWrite = false
                    } else {
                        writeSubmissionMessage = controller.lastMessage
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!declarationAccepted || !volume.actions.canEnableWriting
                          || controller.isBusy(volume.id.diskInstanceID)
                          || controller.isUnresolved(volume.id.diskInstanceID))
            }
        }
        .padding(24)
        .frame(width: 480)
        .onDisappear { declarationAccepted = false }
    }
}

/// Volumes made writable in this session, shown independently of the read-only observation.
struct WritableVolumesSummary: View {
    @ObservedObject var controller: WriteController
    let openEnvironment: () -> Void
    @State private var pendingEject: WriteVolumeRecord?

    var body: some View {
        if !controller.sessionVolumes.isEmpty || !controller.progressByDisk.isEmpty
            || !controller.recentNotices.isEmpty {
            GroupBox("本次会话的操作") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("会话编号在本次运行期间保持不变，用于区分当前列表可能重新排序的磁盘。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(controller.sessionVolumes) { record in
                        let ejectAvailability = availability(for: record)
                        VStack(alignment: .leading, spacing: 8) {
                            Label(record.displayName, systemImage: "externaldrive.fill")
                                .fontWeight(.semibold)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            if !controller.isWritable(record.id) {
                                Text("本次操作未完成，已确认停止。请核验当前挂载状态后安全推出。")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) {
                                    recordActions(record, ejectAvailability: ejectAvailability)
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    recordActions(record, ejectAvailability: ejectAvailability)
                                }
                            }
                            if let reason = ejectAvailability.reason {
                                Text(reason)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if controller.helperState != .enabled {
                                    Button("查看运行环境", action: openEnvironment)
                                        .buttonStyle(.link)
                                }
                            }
                        }
                    }
                    ForEach(controller.progressByDisk.values.sorted(), id: \.self) { message in
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(controller.recentNotices) { notice in
                        HStack(alignment: .top, spacing: 8) {
                            Text(notice.text)
                                .font(.callout)
                                .foregroundStyle(notice.requiresAttention ? Color.orange : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if notice.requiresAttention {
                                Button("关闭提示") { controller.dismissNotice(notice.id) }
                                    .buttonStyle(.link)
                                    .accessibilityLabel("关闭提示：\(notice.text)")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .confirmationDialog("安全推出整块物理磁盘？", isPresented: Binding(
                get: { pendingEject != nil },
                set: { if !$0 { pendingEject = nil } }
            )) {
                if let pendingEject, availability(for: pendingEject).canEject {
                    Button("卸载并推出整块磁盘") {
                        controller.safeEject(pendingEject.id.diskInstanceID, title: pendingEject.title)
                        self.pendingEject = nil
                    }
                }
                Button("取消", role: .cancel) { pendingEject = nil }
            } message: {
                if let pendingEject {
                    Text("目标：\(pendingEject.displayName)。这会卸载整块物理磁盘及同盘其他分区。请先保存文件并关闭占用它们的应用。")
                }
            }
            .onChange(of: controller.helperState) { _, newState in
                if newState != .enabled { pendingEject = nil }
            }
            .onChange(of: controller.sessionEjectableVolumes) { _, _ in
                if let pendingEject, !availability(for: pendingEject).canEject {
                    self.pendingEject = nil
                }
            }
            .onAppear { controller.refreshHelperState() }
        }
    }

    private func availability(for record: WriteVolumeRecord) -> OverviewEjectAvailability {
        OverviewEjectAvailability(
            helperState: controller.helperState,
            isBusy: controller.isBusy(record.id.diskInstanceID),
            isUnresolved: controller.isUnresolved(record.id.diskInstanceID),
            sessionEjectable: controller.canEjectSessionVolume(record.id)
        )
    }

    @ViewBuilder
    private func recordActions(
        _ record: WriteVolumeRecord,
        ejectAvailability: OverviewEjectAvailability
    ) -> some View {
        Button("查看已挂载磁盘") { controller.openMountedVolumesInFinder(for: record.id) }
            .buttonStyle(.borderedProminent)
            .disabled(!controller.canOpenSessionFinder(record.id)
                      || controller.isBusy(record.id.diskInstanceID)
                      || controller.isUnresolved(record.id.diskInstanceID))
        Button("安全推出") { pendingEject = record }
            .buttonStyle(.bordered)
            .disabled(!ejectAvailability.canEject)
    }
}
