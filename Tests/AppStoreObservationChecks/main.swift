import AppKit
import Combine
import Foundation
import NTFSLiteCore
import NTFSLiteDiagnostics
import NTFSLiteHelperProtocol
import NTFSLiteHelperExecution
import NTFSLiteWriteSession
import ServiceManagement
import NTFSLiteReadOnlyProbing
import NTFSLiteSystem
import NTFSLitePresentation

@main
struct AppStoreObservationChecks {
    @MainActor static var fixtureDirectories: [URL] = []
    @MainActor
    static func main() {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        Task { await runChecks() }
        app.run()
    }

    @MainActor
    static func runChecks() async {
        let delegateType: NSObject.Type = ReadOnlyAppDelegate.self
        let defaultDelegate = delegateType.init() as! ReadOnlyAppDelegate
        withExtendedLifetime(defaultDelegate) {}
        print("PASS: Objective-C default delegate initialization returns without starting disk observation")
        defer { for directory in fixtureDirectories { try? FileManager.default.removeItem(at: directory) } }
        await checkBusyDisappearanceAwaitsReleaseOutcome()
        await checkDockReopen()
        // The setup page observes this store, while helper state lives in its child.
        // Use the real controller's read-only refresh; never register or mutate a disk.
        guard !HelperReregistrationPolicy.mayProceed(state: .unreachable, systemReportsEnabled: true, hasBusyDisk: false) else { fatalError("CHECK FAILED: idle UI cannot substitute for fresh helper quiescence") }
        let store = ReadOnlyAppStore(diagnosticsArchive: fixtureArchive(), applicationIdentity: nil)
        let controller = store.writeController
        var pageInvalidations = 0
        var helperInvalidations = 0
        let pageSubscription = store.objectWillChange.sink { pageInvalidations += 1 }
        let helperSubscription = controller.objectWillChange.sink { helperInvalidations += 1 }

        controller.refreshHelperState()
        guard helperInvalidations > 0 else {
            fatalError("CHECK FAILED: helper refresh must publish its current result")
        }
        guard pageInvalidations > 0 else {
            fatalError("CHECK FAILED: the visible setup page must invalidate when helper refresh publishes, without navigation")
        }
        let firstRefreshInvalidations = pageInvalidations
        controller.refreshHelperState()
        guard pageInvalidations > firstRefreshInvalidations else {
            fatalError("CHECK FAILED: subsequent helper checks must still update the visible page")
        }
        withExtendedLifetime((pageSubscription, helperSubscription)) {}
        await checkAuthorizationWithdrawalDuringProbe()
        await checkDisplayedAuthorizationIsRevoked()
        let rejectedVolume = VolumeInstanceID(
            volumeID: VolumeID(uuid: "11111111-2222-3333-4444-555555555555", bsdName: "disk99s2"),
            diskInstanceID: DiskInstanceID(physicalDiskID: PhysicalDiskID(rawValue: "disk99"),
                                         mediaGeneration: MediaGeneration(rawValue: 1)))
        let accepted = controller.enableWriting(rejectedVolume, title: "test")
        guard !accepted, controller.lastMessage?.contains("未提交") == true,
              controller.recentNotices.first?.requiresAttention == true,
              controller.progressByDisk.isEmpty else {
            fatalError("CHECK FAILED: local write admission rejection must be visible and must not start an operation")
        }
        await checkLiveRefreshKeepsObservationEpoch()
        await checkControllerOperations()
        await checkReregistrationQuiescence()
        await checkDiagnosticClearAcrossRequests()
        await checkRuntimeResourcesHeldRejectsWithoutDiskRetry()
        print("PASS: helper refresh updates the observed app store without page navigation")
        for directory in fixtureDirectories { try? FileManager.default.removeItem(at: directory) }
        fixtureDirectories.removeAll()
        exit(EXIT_SUCCESS)
    }

    @MainActor
    private static func checkLiveRefreshKeepsObservationEpoch() async {
        let source = RefreshSourceCounter()
        let observer = ReadOnlyDiskObserver(eventProvider: DiskEventStreamProvider {
            source.makeSession()
        })
        let store = ReadOnlyAppStore(diskObserver: observer, setupReportProvider: { _ in fixtureSetupReport() }, diagnosticsArchive: fixtureArchive(), applicationIdentity: nil)
        store.start()
        for _ in 0..<1000 {
            if source.starts > 0 { break }
            await Task.yield()
        }
        guard source.starts == 1 else { fatalError("CHECK FAILED: live source must start exactly once") }
        let initialEpoch = store.selectionResetEpoch
        store.refresh()
        for _ in 0..<1000 {
            if source.starts == 2 { break }
            await Task.yield()
        }
        guard source.starts == 2, store.selectionResetEpoch != initialEpoch else {
            fatalError("CHECK FAILED: ordinary readonly refresh without a bound session must retain source-reset semantics")
        }
        let epoch = store.selectionResetEpoch
        store.recheckCurrentObservation()
        for _ in 0..<30 { await Task.yield() }
        guard store.selectionResetEpoch == epoch, source.starts == 2 else {
            fatalError("CHECK FAILED: ordinary refresh must recheck the live capture, not rotate connection generations")
        }
        print("PASS: ordinary refresh preserves the live observation epoch and subscription")
    }

    private static func checkAuthorizationWithdrawalDuringProbe() async {
        let permission = ProbePermissionWithdrawal()
        let loader = SystemSetupFactsLoader(
            authorizationProvider: SetupAuthorizationStatusProvider { await permission.currentStatus() },
            commandProvider: SetupReadOnlyCommandProvider { _ in
                await permission.revokeAfterInitialStatus()
                return SetupCommandOutput(standardOutput: "", standardError: "", terminationStatus: 0, wasTruncated: false)
            },
            probePolicy: .unconfigured(acceptedFSKitIdentifiers: ["io.macfuse.app.fsmodule.macfuse-local"])
        )
        let report = await SystemSetupReportFinalizer.currentReport(using: loader,
            authorizationProvider: SetupAuthorizationStatusProvider { await permission.currentStatus() },
            installationVerifier: { true })
        guard report.authorizationStatus == .denied, report.facts.authorizationStatus == .denied else {
            fatalError("CHECK FAILED: authorization revoked during a slow probe must replace the earlier grant before the report is published")
        }
        print("PASS: authorization is revalidated after the slow probe finishes")
    }

    @MainActor
    private static func checkDisplayedAuthorizationIsRevoked() async {
        let facts = SetupFacts(macOSVersion: SemanticVersion(major: 27, minor: 0, patch: 0), architecture: .appleSilicon, macFUSEVersion: nil, ntfs3GVersion: nil, fileSystemExtensionEnabled: false, selectedBackend: .unknown, authorizationStatus: .granted, conflictScanComplete: false, conflictingDrivers: [])
        let report = SystemSetupReport(facts: facts, macFUSEEvidence: .notConfigured, ntfs3GEvidence: .notConfigured, authorizationStatus: .granted, probeResult: SetupProbeResult(fileSystemExtensionEnabled: false, conflictScanComplete: false, conflictingDriverIdentifiers: [], fsKitModuleObservation: .presentActivationUnknown, conflictPolicyObservation: .notConfigured), protectedInstallationVerified: true)
        let store = ReadOnlyAppStore(setupReportProvider: { _ in report }, diagnosticsArchive: fixtureArchive(), applicationIdentity: nil)
        _ = store.writeController
        store.acceptHelperState(.enabled)
        store.refreshSetup()
        for _ in 0..<2_000 {
            if !store.dashboard.setup.isBusy { break }
            await Task.yield()
        }
        guard store.dashboard.setup.requirements.first(where: { $0.id == .authorization })?.state == .satisfied else {
            fatalError("CHECK FAILED: the page regression fixture must first show current granted authorization")
        }
        store.acceptHelperState(.unreachable)
        guard store.dashboard.setup.requirements.first(where: { $0.id == .authorization })?.state == .actionRequired else {
            fatalError("CHECK FAILED: a displayed authorization grant must be revoked immediately when the helper becomes unreachable")
        }
        store.acceptHelperState(.enabled)
        guard store.dashboard.setup.requirements.first(where: { $0.id == .authorization })?.state == .actionRequired else {
            fatalError("CHECK FAILED: a later enabled event must not revive cached authorization")
        }
        store.acceptHelperState(.checkingConnection)
        store.refreshSetup()
        for _ in 0..<2_000 {
            if !store.dashboard.setup.isBusy { break }
            await Task.yield()
        }
        guard !store.dashboard.setup.isBusy,
              store.dashboard.setup.requirements.first(where: { $0.id == .authorization })?.state == .actionRequired else {
            fatalError("CHECK FAILED: a late report carrying an earlier grant must not override the current unverified helper state")
        }
        print("PASS: displayed and in-flight setup grants are revoked without replaying cached approval")
    }

    @MainActor
    private static func checkDockReopen() async {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.regular)
        guard app.activationPolicy() == .regular else { fatalError("CHECK FAILED: WindowServer fixture must support a regular application") }
        app.activate()
        let source = RefreshSourceCounter()
        let store = ReadOnlyAppStore(diskObserver: ReadOnlyDiskObserver(eventProvider: DiskEventStreamProvider { source.makeSession() }), setupReportProvider: { _ in fixtureSetupReport() }, diagnosticsArchive: fixtureArchive(), applicationIdentity: nil)
        let delegate = ReadOnlyAppDelegate(store: store)
        delegate.installMainWindow()
        guard let window = app.windows.first(where: { $0.title == "NTFS 轻量助手" }) else {
            fatalError("CHECK FAILED: the application must create its main window")
        }
        defer { window.close() }
        let activation = NSWorkspace.OpenConfiguration()
        activation.activates = true
        activation.createsNewApplicationInstance = false
        activation.addsToRecentItems = false
        let running = try! await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: activation)
        guard running.processIdentifier == ProcessInfo.processInfo.processIdentifier else { fatalError("CHECK FAILED: GUI activation must reuse the fixture application") }
        app.activate()
        window.makeKeyAndOrderFront(nil)
        await waitForWindowState { app.isActive && window.isKeyWindow && window.isVisible }
        guard app.isActive, window.isKeyWindow else { fatalError("CHECK FAILED: initial LaunchServices activation must settle before the Dock fixture closes its window") }
        let retainedWindows = app.windows.count
        let lifecycleDelegate: any NSApplicationDelegate = delegate
        window.close()
        let handled = lifecycleDelegate.applicationShouldHandleReopen?(app, hasVisibleWindows: false)
        guard handled == false, window.isVisible else {
            fatalError("CHECK FAILED: Dock reopen must restore the closed main window and suppress default reopening")
        }
        app.activate(ignoringOtherApps: true)
        _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.makeKeyAndOrderFront(nil)
        await waitForWindowState { app.isActive && window.isKeyWindow && window.isVisible }
        guard app.isActive, window.isKeyWindow else { fatalError("CHECK FAILED: Dock fixture must activate its real WindowServer window before minimization: active=\(app.isActive), key=\(window.isKeyWindow)") }
        window.miniaturize(nil)
        await waitForWindowState { window.isMiniaturized }
        guard window.isMiniaturized else {
            fatalError("CHECK FAILED: the Dock regression fixture must be minimized")
        }
        _ = lifecycleDelegate.applicationShouldHandleReopen?(app, hasVisibleWindows: false)
        await waitForWindowState { !window.isMiniaturized }
        guard window.isVisible, !window.isMiniaturized else {
            fatalError("CHECK FAILED: Dock reopen must restore a minimized main window")
        }
        _ = lifecycleDelegate.applicationShouldHandleReopen?(app, hasVisibleWindows: true)
        guard window.isVisible, app.windows.count == retainedWindows else {
            fatalError("CHECK FAILED: Dock reopen must reuse the visible main window")
        }
        // Settings or another visible window must not suppress restoration of the main page.
        window.close()
        _ = lifecycleDelegate.applicationShouldHandleReopen?(app, hasVisibleWindows: true)
        guard window.isVisible, app.windows.count == retainedWindows else {
            fatalError("CHECK FAILED: Dock reopen must restore the main window when another window is visible")
        }
        window.close()
        _ = delegate.perform(NSSelectorFromString("openMainWindow"))
        guard window.isVisible, app.windows.count == retainedWindows else {
            fatalError("CHECK FAILED: the menu action must still reuse and restore the main window")
        }
        print("PASS: Dock reopen restores the single main window from closed and minimized states")
    }

    @MainActor
    private static func waitForWindowState(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor ProbePermissionWithdrawal {
    private var status: SetupAuthorizationStatus = .granted
    private var firstRead = false
    private var pendingRevoke: CheckedContinuation<Void, Never>?

    func currentStatus() -> SetupAuthorizationStatus {
        firstRead = true
        pendingRevoke?.resume()
        pendingRevoke = nil
        return status
    }

    func revokeAfterInitialStatus() async {
        if !firstRead {
            await withCheckedContinuation { pendingRevoke = $0 }
        }
        status = .denied
    }
}

private final class RefreshSourceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var starts: Int { lock.withLock { count } }
    func makeSession() -> DiskEventStreamSession {
        lock.withLock { count += 1 }
        let pair = AsyncStream<DiskEventStreamItem>.makeStream()
        return DiskEventStreamSession(items: pair.stream, stopAndDrain: { false },
                                      stopImmediately: { pair.continuation.finish() })
    }
}

func writeSessionObservation(_ volume: VolumeInstanceID, includeEFI: Bool = true) -> DiskInventoryObservation {
    let diskName = volume.diskInstanceID.physicalDiskID.rawValue
    let target = ReadOnlyVolumeMapper.map(
        ReadOnlyVolumeEvidence(
            bsdName: volume.volumeID.bsdName, volumeUUID: volume.volumeID.uuid,
            physicalDiskBSDName: diskName, displayName: "NTFSLAB",
            fileSystemName: "ntfs", isInternal: false, roleEvidence: .unknown,
            diskArbitrationMountPoint: "/Volumes/NTFSLAB",
            mediaUUID: "90200000-0000-0000-0000-000000000002",
            mediaContent: "Windows_NTFS",
            mediaContentHint: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7",
            mediaRegistryID: 902
        ),
        mount: ReadOnlyMountEvidence(
            sourceBSDName: volume.volumeID.bsdName,
            mountPoint: "/Volumes/NTFSLAB", access: .readOnly,
            backend: .unknown, isComplete: true, isCanonical: true,
            isSymlink: false
        ),
        mediaGeneration: volume.diskInstanceID.mediaGeneration
    )
    let efi = ReadOnlyVolumeMapper.map(
        ReadOnlyVolumeEvidence(
            bsdName: diskName + "s1", volumeUUID: nil,
            physicalDiskBSDName: diskName, displayName: "EFI",
            fileSystemName: "msdos", isInternal: false, roleEvidence: .unknown,
            diskArbitrationMountPoint: nil,
            mediaUUID: "90100000-0000-0000-0000-000000000001",
            mediaContent: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B",
            mediaContentHint: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B",
            mediaRegistryID: 901
        ),
        mount: nil,
        mediaGeneration: volume.diskInstanceID.mediaGeneration
    )
    return DiskInventoryObservation(
        physicalDisks: [ReadOnlyPhysicalDiskRecord(
            instanceID: volume.diskInstanceID,
            description: DiskArbitrationDescription(
                bsdName: diskName, physicalDiskBSDName: diskName,
                isWholeDisk: true, isInternal: false,
                isEjectable: true, isRemovable: true,
                mediaSize: 1_000_000, mediaUUID: nil,
                volumeUUID: nil, volumeName: nil,
                fileSystemName: nil, mountPoint: nil,
                mediaContent: "GUID_partition_scheme", mediaRegistryID: 900
            ),
            volumes: includeEFI ? [efi, target] : [target], issues: []
        )],
        issues: []
    )
}


@MainActor
private final class ServiceFixture {
    var status: SMAppService.Status = .enabled
    var reachable = true
    var proof = false
    var trust = true
    var prepareCount = 0
    var holdProof = false
    var pendingProof: CheckedContinuation<Void, Never>?
    var unregisterCount = 0
    var registerCount = 0
    var environment: HelperServiceEnvironment {
        HelperServiceEnvironment(status: { self.status }, trust: { self.trust }, protectedLaunch: { true },
            register: { self.registerCount += 1; self.status = .enabled },
            unregister: { self.unregisterCount += 1; self.status = .notRegistered },
            health: { self.reachable }, prepare: {
                self.prepareCount += 1
                if self.holdProof { await withCheckedContinuation { self.pendingProof = $0 } }
                return self.proof
            })
    }
}

private actor OperationFixture: HelperTransport {
    var responses: [HelperTransportResult]
    var actions: [HelperAction] = []
    init(_ responses: [HelperTransportResult]) { self.responses = responses }
    func send(_ data: Data) async -> HelperTransportResult {
        struct Wire: Decodable { let action: HelperAction }
        actions.append(try! JSONDecoder().decode(Wire.self, from: data).action)
        guard !responses.isEmpty else { fatalError("CHECK FAILED: unexpected duplicate disk request") }
        return responses.removeFirst()
    }
}

extension AppStoreObservationChecks {
    @MainActor
    static func settle(_ predicate: () -> Bool) async {
        for _ in 0..<10_000 { if predicate() { return }; await Task.yield() }
        fatalError("CHECK FAILED: controller did not reach expected state")
    }

    @MainActor
    static func checkReregistrationQuiescence() async {
        let service = ServiceFixture()
        service.reachable = false
        let controller = WriteController(service: service.environment, refreshObservation: {}, canRequestWriting: { _ in true }, canRequestEject: { _ in true })
        await settle { controller.helperState == .unreachable }
        controller.reregisterHelper()
        controller.reregisterHelper()
        await settle { !controller.isReregisteringHelper }
        guard service.prepareCount == 1, service.unregisterCount == 0,
              controller.helperMessage?.contains("未注销") == true else {
            fatalError("CHECK FAILED: refused fresh helper proof must never unregister or accept duplicate maintenance")
        }
        service.proof = true
        controller.reregisterHelper()
        await settle { !controller.isReregisteringHelper }
        guard service.unregisterCount == 1, service.registerCount == 1 else {
            fatalError("CHECK FAILED: fresh global quiescence permits exactly one unregister/register")
        }
        let heldService = ServiceFixture()
        heldService.reachable = false
        heldService.holdProof = true
        let raw = OperationFixture([])
        let held = WriteController(service: heldService.environment, transport: raw,
                                   refreshObservation: {}, canRequestWriting: { _ in true }, canRequestEject: { _ in true })
        await settle { held.helperState == .unreachable }
        held.reregisterHelper()
        await settle { heldService.pendingProof != nil }
        held.refreshHelperState()
        let volume = VolumeInstanceID(volumeID: VolumeID(uuid: "4e6d1fc6-d631-3bd7-ae52-e7fca880a904", bsdName: "disk6s2"), diskInstanceID: DiskInstanceID(physicalDiskID: PhysicalDiskID(rawValue: "disk6"), mediaGeneration: MediaGeneration(rawValue: 3)))
        held.reconcile(observation: writeSessionObservation(volume))
        guard held.helperState != .enabled, !held.enableWriting(volume, title: "test"),
              heldService.unregisterCount == 0 else { fatalError("CHECK FAILED: pending maintenance proof must keep all App entry points closed") }
        held.safeEject(volume.diskInstanceID, title: "test")
        guard await raw.actions.isEmpty else { fatalError("CHECK FAILED: no disk request may escape while proof is pending") }
        heldService.pendingProof?.resume()
        heldService.pendingProof = nil
        await settle { !held.isReregisteringHelper }
        guard heldService.unregisterCount == 0 else { fatalError("CHECK FAILED: refused held proof must not unregister") }
        print("PASS: re-registration requires fresh global quiescence and rejects duplicate clicks")
    }

    @MainActor
    static func checkControllerOperations() async {
        let volume = VolumeInstanceID(volumeID: VolumeID(uuid: "4e6d1fc6-d631-3bd7-ae52-e7fca880a904", bsdName: "disk6s2"), diskInstanceID: DiskInstanceID(physicalDiskID: PhysicalDiskID(rawValue: "disk6"), mediaGeneration: MediaGeneration(rawValue: 3)))
        let observation = writeSessionObservation(volume)
        func reply(_ code: HelperResultCode, _ status: Int32 = 0) -> HelperTransportResult {
            .reply(try! JSONEncoder().encode(HelperResponseEnvelope(resultCode: code, exitStatus: status)))
        }
        for (first, expected, certainty) in [
            (reply(.succeeded), WriteOutcome.writingEnabled, DiagnosticResultCertainty.verified),
            (reply(.stateChangedQuiescent, WritableMountFailure.healthNotClean.rawValue), .changedAndStopped(.mount(.healthNotClean)), .changedQuiescent),
            (reply(.stateChangedQuiescent, WritableMountFailure.nativeUnmountFailed.rawValue), .changedAndStopped(.mount(.nativeUnmountFailed)), .changedQuiescent),
            (HelperTransportResult.unavailable, .refused(.helperUnavailable), .unchanged),
            (HelperTransportResult.timedOut, .needsRefresh(.helperTimedOut), .unknown),
            (HelperTransportResult.reply(Data("not JSON".utf8)), .needsRefresh(.invalidResponse), .unknown),
            (reply(.executionFailed, 99), .needsRefresh(.unknownStage(99)), .unknown),
            (reply(.executionFailed, WritableMountFailure.factsUnavailable.rawValue), .refused(.mount(.factsUnavailable)), .unchanged)
        ] {
            let directory = fixtureRoot().appendingPathComponent("operation-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let diagnostics = Diagnostics()
            let archive = DiagnosticSnapshotArchive(policy: try! DiagnosticSnapshotArchivePolicy(directoryURL: directory))
            let service = ServiceFixture()
            let raw = OperationFixture([first, reply(.succeeded), reply(.succeeded)])
            let counter = RefreshSourceCounter()
            let store = ReadOnlyAppStore(diskObserver: ReadOnlyDiskObserver(eventProvider: DiskEventStreamProvider { counter.makeSession() }), setupReportProvider: { _ in fixtureSetupReport() }, helperService: service.environment, helperTransport: raw, diagnostics: diagnostics, diagnosticsArchive: archive, applicationIdentity: nil)
            store.start()
            await settle { counter.starts == 1 }
            let epoch = store.selectionResetEpoch
            let controller = WriteController(service: service.environment,
                transport: DiagnosticHelperTransport(transport: raw, diagnostics: diagnostics),
                operationCompleted: { await store.publishDiagnosticsSnapshot() }, refreshObservation: { store.recheckCurrentObservation() },
                canRequestWriting: { WriteSession.diskIdentity($0.diskInstanceID, target: $0, in: observation) != nil }, canRequestEject: { _ in false })
            await settle { controller.helperState == .enabled }
            controller.reconcile(observation: observation)
            guard controller.enableWriting(volume, title: "PRIVATE-TARGET") else { fatalError("CHECK FAILED: confirmed eligible write must be accepted") }
            guard !controller.enableWriting(volume, title: "PRIVATE-TARGET") else { fatalError("CHECK FAILED: duplicate write must be rejected while busy") }
            await settle { !controller.isBusy(volume.diskInstanceID) }
            guard controller.lastOutcomeByDisk[volume.diskInstanceID] == expected,
                  counter.starts == 1, store.selectionResetEpoch == epoch else {
                fatalError("CHECK FAILED: real controller outcome and refresh must preserve live subscription")
            }
            if case .writingEnabled = expected {
                guard controller.isWritable(volume), controller.hasBoundDiskSession else { fatalError("CHECK FAILED: successful write must bind session") }
            }
            if case .changedAndStopped = expected {
                guard !controller.isWritable(volume), controller.releasePendingVolumes.count == 1,
                      !controller.isUnresolved(volume.diskInstanceID) else { fatalError("CHECK FAILED: quiescent failed write must retain releasable binding") }
            }
            if case .needsRefresh = expected {
                guard controller.isUnresolved(volume.diskInstanceID), controller.hasBoundDiskSession,
                      !controller.enableWriting(volume, title: "PRIVATE-TARGET") else { fatalError("CHECK FAILED: unknown result must freeze duplicate write") }
                service.reachable = false
                controller.refreshHelperState()
                await settle { controller.helperState == .unreachable }
                controller.reregisterHelper()
                guard service.prepareCount == 0, service.unregisterCount == 0 else { fatalError("CHECK FAILED: unresolved session must block helper maintenance") }
            }
            if controller.sessionVolumes.count == 1 {
                await settle { controller.helperState == .enabled }
                guard !controller.enableWriting(volume, title: "PRIVATE-TARGET") else { fatalError("CHECK FAILED: bound writable/release-pending session must reject another write even with stale ready presentation") }
                service.reachable = false
                controller.refreshHelperState()
                await settle { controller.helperState == .unreachable }
                controller.reregisterHelper()
                guard service.prepareCount == 0, service.unregisterCount == 0 else { fatalError("CHECK FAILED: writable or release-pending binding must block helper maintenance") }
                service.reachable = true
                controller.refreshHelperState()
                await settle { controller.helperState == .enabled }
                controller.reconcile(observation: observation)
                controller.safeEject(volume.diskInstanceID, title: "PRIVATE-TARGET")
                controller.safeEject(volume.diskInstanceID, title: "PRIVATE-TARGET")
                await settle { !controller.isBusy(volume.diskInstanceID) }
                guard controller.lastOutcomeByDisk[volume.diskInstanceID] == .ejected,
                      !controller.hasBoundDiskSession else { fatalError("CHECK FAILED: bound writable/quiescent session must use standard release and clear binding") }
                guard await raw.actions == [.mountReadWrite, .unmountDisk, .ejectDisk] else { fatalError("CHECK FAILED: release must submit fixed unmount/eject exactly once") }
            } else {
                guard await raw.actions == [.mountReadWrite] else { fatalError("CHECK FAILED: failed write must submit once") }
            }
            let loaded = await archive.load()
            guard case let .loaded(snapshot) = loaded else { fatalError("CHECK FAILED: real diagnostic archive must load submitted operations: \(loaded)") }
            let operations = snapshot.entries.compactMap { entry -> DiagnosticOperationEvent? in
                if case let .operation(event) = entry.event { return event }; return nil
            }
            let expectedStage: DiagnosticOperationStage
            switch expected {
            case .writingEnabled: expectedStage = .inspectWriteMount
            case .changedAndStopped(.mount(.nativeUnmountFailed)): expectedStage = .unmountReadOnly
            case .refused(.helperUnavailable), .needsRefresh: expectedStage = .reconcile
            default: expectedStage = .inspectSafety
            }
            guard operations.first?.certainty == certainty, operations.first?.traceID != nil,
                  operations.first?.stage == expectedStage else { fatalError("CHECK FAILED: archive must retain real action and outcome certainty") }
            let text = String(data: try! snapshot.encodedJSON(), encoding: .utf8)!
            guard !text.contains("PRIVATE-TARGET"), !text.contains(volume.volumeID.uuid),
                  !text.contains("disk6"), !text.contains("/Volumes") else { fatalError("CHECK FAILED: archive must exclude target text, UUID and path") }
        }
        print("PASS: real controller covers accepted write, duplicate, success, quiescent release, uncertainty and anonymous archive")
    }
}

private func fixtureSetupReport() -> SystemSetupReport {
    let facts = SetupFacts(macOSVersion: SemanticVersion(major: 27, minor: 0, patch: 0), architecture: .appleSilicon, macFUSEVersion: nil, ntfs3GVersion: nil, fileSystemExtensionEnabled: false, selectedBackend: .unknown, authorizationStatus: .granted, conflictScanComplete: false, conflictingDrivers: [])
    return SystemSetupReport(facts: facts, macFUSEEvidence: .notConfigured, ntfs3GEvidence: .notConfigured, authorizationStatus: .granted, probeResult: SetupProbeResult(fileSystemExtensionEnabled: false, conflictScanComplete: false, conflictingDriverIdentifiers: [], fsKitModuleObservation: .presentActivationUnknown, conflictPolicyObservation: .notConfigured), protectedInstallationVerified: true)
}

@MainActor
private func fixtureArchive() -> DiagnosticSnapshotArchive {
    let directory = fixtureRoot().appendingPathComponent("fixture-" + UUID().uuidString)
    AppStoreObservationChecks.fixtureDirectories.append(directory)
    return DiagnosticSnapshotArchive(policy: try! DiagnosticSnapshotArchivePolicy(directoryURL: directory))
}

private func fixtureRoot() -> URL {
    guard let path = ProcessInfo.processInfo.environment["NTFSLITE_APP_CHECKS_ROOT"],
          path.hasPrefix("/private/tmp/ntfslite-app-observation-") else {
        fatalError("CHECK FAILED: fixture must have its own canonical temporary archive root")
    }
    let root = URL(fileURLWithPath: path, isDirectory: true)
    guard path == "/private/tmp/" + root.lastPathComponent,
          !root.lastPathComponent.contains("..") else { fatalError("CHECK FAILED: fixture root must be canonical") }
    return root
}

private actor HeldDiagnosticOperation: HelperTransport {
    private var hold = false
    private var pending: CheckedContinuation<HelperTransportResult, Never>?
    private(set) var submissions = 0
    var isWaiting: Bool { pending != nil }
    private var response: HelperTransportResult {
        .reply(try! JSONEncoder().encode(HelperResponseEnvelope(resultCode: .executionFailed, exitStatus: WritableMountFailure.factsUnavailable.rawValue)))
    }
    func holdNext() { hold = true }
    func release() {
        hold = false
        pending?.resume(returning: response)
        pending = nil
    }
    func send(_ data: Data) async -> HelperTransportResult {
        submissions += 1
        if hold { return await withCheckedContinuation { pending = $0 } }
        return response
    }
}

extension AppStoreObservationChecks {
    @MainActor
    static func checkDiagnosticClearAcrossRequests() async {
        let diagnostics = Diagnostics()
        let archive = fixtureArchive()
        let service = ServiceFixture()
        let raw = HeldDiagnosticOperation()
        let store = ReadOnlyAppStore(helperService: service.environment, helperTransport: raw,
                                    diagnostics: diagnostics, diagnosticsArchive: archive, applicationIdentity: nil)
        let controller = WriteController(service: service.environment,
            transport: DiagnosticHelperTransport(transport: raw, diagnostics: diagnostics),
            operationCompleted: { await store.publishDiagnosticsSnapshot() }, refreshObservation: {},
            canRequestWriting: { _ in true }, canRequestEject: { _ in false })
        let volume = VolumeInstanceID(volumeID: VolumeID(uuid: "4e6d1fc6-d631-3bd7-ae52-e7fca880a904", bsdName: "disk6s2"), diskInstanceID: DiskInstanceID(physicalDiskID: PhysicalDiskID(rawValue: "disk6"), mediaGeneration: MediaGeneration(rawValue: 3)))
        controller.reconcile(observation: writeSessionObservation(volume))
        func submit() async {
            await settle { controller.helperState == .enabled }
            guard controller.enableWriting(volume, title: "PRIVATE-TARGET") else { fatalError("CHECK FAILED: clear regression must submit the actual controller request") }
        }
        func read(_ expectedCount: Int) async -> DiagnosticSnapshot {
            await settle { !controller.isBusy(volume.diskInstanceID) }
            guard case let .loaded(snapshot) = await archive.load() else { fatalError("CHECK FAILED: post-clear controller result must be persisted in the real archive") }
            let operations = snapshot.entries.filter { if case .operation = $0.event { return true }; return false }
            guard operations.count == expectedCount, operations.allSatisfy({ entry in
                guard case let .operation(event) = entry.event else { return false }
                return event.target.runID == snapshot.runID && event.traceID != nil
                    && event.certainty == .unchanged && event.helperStageCode == WritableMountFailure.factsUnavailable.rawValue
            }) else { fatalError("CHECK FAILED: every post-clear actual result must use current anonymous target generation") }
            return snapshot
        }
        await submit()
        let first = await read(1)
        guard await store.clearDiagnostics() else { fatalError("CHECK FAILED: clear fixture must clear its own archive") }
        await submit()
        let second = await read(1)
        guard second.runID != first.runID else { fatalError("CHECK FAILED: clear must rotate target generation") }
        await raw.holdNext()
        await submit()
        for _ in 0..<10_000 { if await raw.isWaiting { break }; await Task.yield() }
        guard await raw.isWaiting, controller.isBusy(volume.diskInstanceID) else { fatalError("CHECK FAILED: transport fixture must suspend an actual delivered request") }
        guard await store.clearDiagnostics() else { fatalError("CHECK FAILED: clear during send must clear its own archive") }
        await raw.release()
        let third = await read(1)
        guard third.runID != second.runID else { fatalError("CHECK FAILED: send-await clear must rotate target generation") }
        await submit()
        let fourth = await read(2)
        let targets = fourth.entries.compactMap { entry -> DiagnosticTarget? in if case let .operation(event) = entry.event { return event.target }; return nil }
        guard Set(targets).count == 1, await raw.submissions == 4 else { fatalError("CHECK FAILED: a fresh target must be reused once per generation without retrying disk requests") }
        print("PASS: clearing diagnostics before and during actual requests preserves anonymous current-generation archive results")
    }
}

private actor HeldReleaseOperation: HelperTransport {
    let holdAction: HelperAction
    let final: HelperTransportResult
    private var pending: CheckedContinuation<HelperTransportResult, Never>?
    var isWaiting: Bool { pending != nil }
    init(holdAction: HelperAction, final: HelperTransportResult) { self.holdAction = holdAction; self.final = final }
    func send(_ data: Data) async -> HelperTransportResult {
        struct Wire: Decodable { let action: HelperAction }
        let action = try! JSONDecoder().decode(Wire.self, from: data).action
        if action == holdAction { return await withCheckedContinuation { pending = $0 } }
        if action == .ejectDisk { return final }
        return .reply(try! JSONEncoder().encode(HelperResponseEnvelope(resultCode: .succeeded, exitStatus: 0)))
    }
    func release() {
        let response: HelperTransportResult = holdAction == .ejectDisk ? final
            : .reply(try! JSONEncoder().encode(HelperResponseEnvelope(resultCode: .succeeded, exitStatus: 0)))
        pending?.resume(returning: response)
        pending = nil
    }
}

extension AppStoreObservationChecks {
    @MainActor
    static func checkBusyDisappearanceAwaitsReleaseOutcome() async {
        let volume = VolumeInstanceID(volumeID: VolumeID(uuid: "4e6d1fc6-d631-3bd7-ae52-e7fca880a904", bsdName: "disk6s2"), diskInstanceID: DiskInstanceID(physicalDiskID: PhysicalDiskID(rawValue: "disk6"), mediaGeneration: MediaGeneration(rawValue: 3)))
        let observation = writeSessionObservation(volume)
        let absent = DiskInventoryObservation(physicalDisks: [], issues: [])
        func reply(_ code: HelperResultCode, _ status: Int32 = 0) -> HelperTransportResult { .reply(try! JSONEncoder().encode(HelperResponseEnvelope(resultCode: code, exitStatus: status))) }
        for (action, final, expected) in [
            (HelperAction.unmountDisk, reply(.succeeded), WriteOutcome.ejected),
            (.ejectDisk, reply(.succeeded), .ejected),
            (.ejectDisk, HelperTransportResult.timedOut, .needsRefresh(.helperTimedOut)),
            (.ejectDisk, reply(.stateChangedQuiescent, DiskReleaseFailure.ejectRefused.rawValue), .changedAndStopped(.release(.ejectRefused)))
        ] {
            let diagnostics = Diagnostics()
            let archive = fixtureArchive()
            let service = ServiceFixture()
            let raw = HeldReleaseOperation(holdAction: action, final: final)
            let store = ReadOnlyAppStore(helperService: service.environment, helperTransport: raw, diagnostics: diagnostics, diagnosticsArchive: archive, applicationIdentity: nil)
            let controller = WriteController(service: service.environment, transport: DiagnosticHelperTransport(transport: raw, diagnostics: diagnostics), operationCompleted: { await store.publishDiagnosticsSnapshot() }, refreshObservation: {}, canRequestWriting: { _ in true }, canRequestEject: { _ in false })
            await settle { controller.helperState == .enabled }
            controller.reconcile(observation: observation)
            guard controller.enableWriting(volume, title: "PRIVATE-TARGET") else { fatalError("CHECK FAILED: release disappearance fixture must accept initial write") }
            await settle { !controller.isBusy(volume.diskInstanceID) && controller.helperState == .enabled }
            let pendingIdentity = nativeIdentityPendingObservation(volume, original: observation)
            controller.reconcile(observation: pendingIdentity)
            let pendingDashboard = ReadOnlyDashboardPresenter.presentation(for: pendingIdentity, setupAssessment: SetupAssessment(issues: []), isSetupRefreshing: false)
            let explanation = controller.overviewExplanation(for: pendingDashboard)
            guard controller.canEjectSessionVolume(volume), explanation.title == "本次会话已启用写入",
                  explanation.detail.contains("原生分区身份待确认"), explanation.detail.contains("会话安全推出"),
                  explanation.detail.contains("不代表当前已验证可写"), !pendingDashboard.writeControlsAvailable else {
                fatalError("CHECK FAILED: fresh releasable retained session must explain missing native identity without promoting current writable or candidate authority")
            }
            guard explanation.detail.contains(pendingDashboard.detail), explanation.detail.contains("其他 FUSE 挂载") else { fatalError("CHECK FAILED: generic macFUSE cannot be treated as unrelated NTFS and must retain the original global warning") }
            guard explanation.detail.contains("无卷信息的磁盘"), explanation.detail.contains(pendingDashboard.detail) else { fatalError("CHECK FAILED: another unknown empty whole disk must preserve the original global warning alongside current session context") }
            let emptyTarget = ReadOnlyPhysicalDiskRecord(instanceID: volume.diskInstanceID, description: pendingIdentity.physicalDisks[0].description, volumes: [], issues: [])
            let emptyTargetObservation = DiskInventoryObservation(physicalDisks: [emptyTarget] + Array(pendingIdentity.physicalDisks.dropFirst()), issues: [])
            controller.reconcile(observation: emptyTargetObservation)
            let emptyTargetDashboard = ReadOnlyDashboardPresenter.presentation(for: emptyTargetObservation, setupAssessment: SetupAssessment(issues: []), isSetupRefreshing: false)
            let emptyTargetExplanation = controller.overviewExplanation(for: emptyTargetDashboard)
            guard emptyTargetExplanation.title == emptyTargetDashboard.title, emptyTargetExplanation.detail == emptyTargetDashboard.detail else { fatalError("CHECK FAILED: empty current session target must never produce the success context header") }

            let internalContainer = backgroundAPFSContainer("disk21", internalLocation: true, fileSystem: nil)
            let internalNTFS = ReadOnlyVolumeMapper.map(ReadOnlyVolumeEvidence(bsdName: "disk21s1", volumeUUID: nil, physicalDiskBSDName: "disk21", displayName: "Internal NTFS", fileSystemName: "ntfs", isInternal: true, roleEvidence: .protected, diskArbitrationMountPoint: nil, mediaUUID: "40100000-0000-0000-0000-000000000004", mediaContent: "Windows_NTFS", mediaContentHint: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", mediaRegistryID: 2000), mount: nil, mediaGeneration: internalContainer.instanceID.mediaGeneration)
            let internalFailure = ReadOnlyPhysicalDiskRecord(instanceID: internalContainer.instanceID, description: internalContainer.description, volumes: [internalNTFS], issues: [])
            let internalObservation = DiskInventoryObservation(physicalDisks: pendingIdentity.physicalDisks + [internalFailure], issues: [])
            controller.reconcile(observation: internalObservation)
            let internalDashboard = ReadOnlyDashboardPresenter.presentation(for: internalObservation, setupAssessment: SetupAssessment(issues: []), isSetupRefreshing: false)
            guard controller.overviewExplanation(for: internalDashboard).title == internalDashboard.title else { fatalError("CHECK FAILED: explicit internal NTFS failure must preserve the original explanation") }
            let otherVolume = VolumeInstanceID(volumeID: VolumeID(uuid: "60100000-0000-0000-0000-000000000003", bsdName: "disk20s2"), diskInstanceID: DiskInstanceID(physicalDiskID: PhysicalDiskID(rawValue: "disk20"), mediaGeneration: MediaGeneration(rawValue: 51)))
            let otherDisk = nativeIdentityPendingObservation(otherVolume, original: writeSessionObservation(otherVolume)).physicalDisks[0]
            let otherUnknownNTFS = DiskInventoryObservation(physicalDisks: pendingIdentity.physicalDisks + [otherDisk], issues: [])
            controller.reconcile(observation: otherUnknownNTFS)
            let otherDashboard = ReadOnlyDashboardPresenter.presentation(for: otherUnknownNTFS, setupAssessment: SetupAssessment(issues: []), isSetupRefreshing: false)
            guard controller.overviewExplanation(for: otherDashboard).title == otherDashboard.title else { fatalError("CHECK FAILED: another unbound external NTFS identity failure must retain the original explanation") }
            let uncertain = DiskInventoryObservation(physicalDisks: pendingIdentity.physicalDisks, issues: [.enumerationCoverageUnverified])
            controller.reconcile(observation: uncertain)
            let unknownDashboard = ReadOnlyDashboardPresenter.presentation(for: uncertain, setupAssessment: SetupAssessment(issues: []), isSetupRefreshing: false)
            let unknownExplanation = controller.overviewExplanation(for: unknownDashboard)
            guard unknownExplanation.title == unknownDashboard.title, unknownExplanation.detail == unknownDashboard.detail else { fatalError("CHECK FAILED: root observation failure must preserve its original explanation") }
            controller.reconcile(observation: observation)
            controller.safeEject(volume.diskInstanceID, title: "PRIVATE-TARGET")
            for _ in 0..<10_000 { if await raw.isWaiting { break }; await Task.yield() }
            guard await raw.isWaiting, controller.isBusy(volume.diskInstanceID) else { fatalError("CHECK FAILED: real standard release must be held at the requested action") }
            controller.reconcile(observation: pendingIdentity)
            let busyDashboard = ReadOnlyDashboardPresenter.presentation(for: pendingIdentity, setupAssessment: SetupAssessment(issues: []), isSetupRefreshing: false)
            guard controller.overviewExplanation(for: busyDashboard).title == busyDashboard.title else { fatalError("CHECK FAILED: busy sessions cannot override unknown native identity text") }
            controller.reconcile(observation: absent)
            guard !controller.isWritable(volume), !controller.canEjectSessionVolume(volume),
                  !controller.recentNotices.contains(where: { $0.text.contains("若已直接拔出") || $0.text.contains("无法确认曾安全推出") }) else {
                fatalError("CHECK FAILED: verified absence during busy standard release must revoke live actions without blaming an unsafe disconnect")
            }
            guard controller.lastOutcomeByDisk[volume.diskInstanceID] == nil else { fatalError("CHECK FAILED: disappearance alone must not invent an eject outcome") }
            await raw.release()
            await settle { !controller.isBusy(volume.diskInstanceID) }
            guard controller.lastOutcomeByDisk[volume.diskInstanceID] == expected,
                  !controller.recentNotices.contains(where: { $0.text.contains("若已直接拔出") || $0.text.contains("无法确认曾安全推出") }) else { fatalError("CHECK FAILED: completed release must explain its real helper outcome without retaining a false warning") }
            if case .ejected = expected {
                guard controller.lastMessage?.contains("可以拔出") == true else { fatalError("CHECK FAILED: successful release must show verified safe removal") }
            } else {
                await settle { controller.helperState == .enabled }
                controller.reconcile(observation: pendingIdentity)
                guard controller.overviewExplanation(for: pendingDashboard).title == pendingDashboard.title else { fatalError("CHECK FAILED: quiet or unresolved outcomes must not restore the successful session header") }
                guard !controller.enableWriting(volume, title: "PRIVATE-TARGET"), !controller.isWritable(volume) else { fatalError("CHECK FAILED: quiet/unknown release outcomes plus absence must never reopen write admission") }
            }
            guard case let .loaded(snapshot) = await archive.load(), snapshot.entries.filter({ if case .operation = $0.event { return true }; return false }).count == 3 else { fatalError("CHECK FAILED: busy disappearance flow must archive the actual write, unmount and eject") }
        }
        let diagnostics = Diagnostics()
        let archive = fixtureArchive()
        let service = ServiceFixture()
        let raw = OperationFixture([reply(.succeeded)])
        let store = ReadOnlyAppStore(helperService: service.environment, helperTransport: raw, diagnostics: diagnostics, diagnosticsArchive: archive, applicationIdentity: nil)
        let controller = WriteController(service: service.environment, transport: DiagnosticHelperTransport(transport: raw, diagnostics: diagnostics), operationCompleted: { await store.publishDiagnosticsSnapshot() }, refreshObservation: {}, canRequestWriting: { _ in true }, canRequestEject: { _ in false })
        await settle { controller.helperState == .enabled }
        controller.reconcile(observation: observation)
        _ = controller.enableWriting(volume, title: "PRIVATE-TARGET")
        await settle { !controller.isBusy(volume.diskInstanceID) }
        controller.reconcile(observation: absent)
        guard !controller.isWritable(volume), controller.recentNotices.contains(where: { $0.requiresAttention && $0.text.contains("若已直接拔出") }) else { fatalError("CHECK FAILED: a nonbusy real disconnect must retain the attention warning") }
        let absentDashboard = ReadOnlyDashboardPresenter.presentation(for: absent, setupAssessment: SetupAssessment(issues: []), isSetupRefreshing: false)
        guard controller.overviewExplanation(for: absentDashboard).title == absentDashboard.title else { fatalError("CHECK FAILED: absent target without a fresh bound session must not produce the success context header") }

        print("PASS: busy verified disappearance awaits helper outcome while nonbusy removal retains its warning")
    }
}

private func nativeIdentityPendingObservation(_ volume: VolumeInstanceID, original: DiskInventoryObservation) -> DiskInventoryObservation {
    let disk = original.physicalDisks[0]
    let target = ReadOnlyVolumeMapper.map(ReadOnlyVolumeEvidence(
        bsdName: volume.volumeID.bsdName, volumeUUID: nil, physicalDiskBSDName: volume.diskInstanceID.physicalDiskID.rawValue,
        displayName: "PRIVATE-TARGET", fileSystemName: "ntfs", isInternal: false, roleEvidence: .unknown,
        diskArbitrationMountPoint: nil, mediaUUID: "90200000-0000-0000-0000-000000000002",
        mediaContent: "Windows_NTFS", mediaContentHint: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", mediaRegistryID: 902
    ), mount: nil, mediaGeneration: volume.diskInstanceID.mediaGeneration)
    let targetDisk = ReadOnlyPhysicalDiskRecord(instanceID: disk.instanceID, description: disk.description, volumes: [disk.volumes[0], target], issues: [])
    return DiskInventoryObservation(physicalDisks: [targetDisk,
        backgroundAPFSContainer("disk0", internalLocation: true, fileSystem: nil),
        backgroundAPFSContainer("disk4", internalLocation: nil, fileSystem: nil),
        backgroundAPFSContainer("disk5", internalLocation: nil, fileSystem: "apfs"),
        backgroundAPFSContainer("disk10", internalLocation: nil, fileSystem: "macfuse"),
        backgroundUnconfirmedEmptyDisk("disk9")], issues: [])
}

private func backgroundAPFSContainer(_ name: String, internalLocation: Bool?, fileSystem: String?) -> ReadOnlyPhysicalDiskRecord {
    let generation = MediaGeneration(rawValue: 44)
    let disk = DiskInstanceID(physicalDiskID: PhysicalDiskID(rawValue: name), mediaGeneration: generation)
    let row = ReadOnlyVolumeMapper.map(ReadOnlyVolumeEvidence(
        bsdName: name + "s1", volumeUUID: fileSystem == "apfs" ? "40100000-0000-0000-0000-000000000001" : nil,
        physicalDiskBSDName: name, displayName: fileSystem == "apfs" ? "Simulator" : nil,
        fileSystemName: fileSystem, isInternal: internalLocation, roleEvidence: .unknown,
        diskArbitrationMountPoint: nil, mediaUUID: "40100000-0000-0000-0000-000000000002",
        mediaContent: fileSystem == "macfuse" ? nil : "7C3457EF-0000-11AA-AA11-00306543ECAC",
        mediaContentHint: nil, mediaRegistryID: 400
    ), mount: nil, mediaGeneration: generation)
    return ReadOnlyPhysicalDiskRecord(instanceID: disk,
        description: DiskArbitrationDescription(bsdName: name, physicalDiskBSDName: name, isWholeDisk: true,
            isInternal: internalLocation, isEjectable: false, isRemovable: false, mediaSize: 100_000,
            mediaUUID: nil, volumeUUID: nil, volumeName: nil, fileSystemName: nil, mountPoint: nil,
            mediaContent: "GUID_partition_scheme", mediaRegistryID: 399), volumes: [row],
        issues: internalLocation == nil ? [.missingPhysicalLocation(bsdName: name)] : [])
}

private func backgroundUnconfirmedEmptyDisk(_ name: String) -> ReadOnlyPhysicalDiskRecord {
    let instance = DiskInstanceID(physicalDiskID: PhysicalDiskID(rawValue: name), mediaGeneration: MediaGeneration(rawValue: 99))
    return ReadOnlyPhysicalDiskRecord(instanceID: instance, description: DiskArbitrationDescription(
        bsdName: name, physicalDiskBSDName: name, isWholeDisk: true, isInternal: nil, isEjectable: false,
        isRemovable: false, mediaSize: 4096, mediaUUID: nil, volumeUUID: nil, volumeName: nil,
        fileSystemName: nil, mountPoint: nil, mediaContent: nil, mediaRegistryID: 990
    ), volumes: [], issues: [.missingPhysicalLocation(bsdName: name)])
}

extension AppStoreObservationChecks {
    @MainActor
    static func checkRuntimeResourcesHeldRejectsWithoutDiskRetry() async {
        let held = HelperTransportResult.reply(Data("{\"schemaVersion\":1,\"resultCode\":23,\"exitStatus\":1}".utf8))
        let success = HelperTransportResult.reply(try! JSONEncoder().encode(HelperResponseEnvelope(resultCode: .succeeded, exitStatus: 0)))
        let volume = VolumeInstanceID(volumeID: VolumeID(uuid: "4e6d1fc6-d631-3bd7-ae52-e7fca880a904", bsdName: "disk6s2"), diskInstanceID: DiskInstanceID(physicalDiskID: PhysicalDiskID(rawValue: "disk6"), mediaGeneration: MediaGeneration(rawValue: 3)))
        let observation = writeSessionObservation(volume)
        for (mountFirst, heldAtEject) in [(false, false), (true, false), (true, true)] {
            let diagnostics = Diagnostics()
            let archive = fixtureArchive()
            let service = ServiceFixture()
            let raw = OperationFixture(heldAtEject ? [success, success, held] : (mountFirst ? [success, held] : [held]))
            let store = ReadOnlyAppStore(helperService: service.environment, helperTransport: raw, diagnostics: diagnostics, diagnosticsArchive: archive, applicationIdentity: nil)
            let controller = WriteController(service: service.environment, transport: DiagnosticHelperTransport(transport: raw, diagnostics: diagnostics), operationCompleted: { await store.publishDiagnosticsSnapshot() }, refreshObservation: {}, canRequestWriting: { _ in true }, canRequestEject: { _ in false })
            await settle { controller.helperState == .enabled }
            controller.reconcile(observation: observation)
            guard controller.enableWriting(volume, title: "PRIVATE-TARGET") else { fatalError("CHECK FAILED: runtime rejection fixture must submit through the real controller") }
            await settle { !controller.isBusy(volume.diskInstanceID) && controller.helperState == .enabled }
            if mountFirst {
                guard controller.isWritable(volume) else { fatalError("CHECK FAILED: runtime release fixture must first retain a successful write binding") }
                controller.reconcile(observation: observation)
                controller.safeEject(volume.diskInstanceID, title: "PRIVATE-TARGET")
                await settle { !controller.isBusy(volume.diskInstanceID) }
            }
            let expected: WriteOutcome = heldAtEject ? .changedAndStopped(.runtimeResourcesHeld) : .refused(.runtimeResourcesHeld)
            guard controller.lastOutcomeByDisk[volume.diskInstanceID] == expected,
                  controller.lastMessage?.contains("后端运行检查的收尾尚未确认") == true,
                  !controller.isUnresolved(volume.diskInstanceID) else { fatalError("CHECK FAILED: held runtime resources must reject before target mutation with its own explanation rather than ordinary disk busy") }
            if heldAtEject {
                guard !controller.isWritable(volume), controller.releasePendingVolumes.count == 1, controller.sessionVolumes.count == 1 else { fatalError("CHECK FAILED: runtime rejection after completed unmount must retain the releasable binding") }
            } else if mountFirst {
                guard controller.isWritable(volume), controller.sessionVolumes.count == 1 else { fatalError("CHECK FAILED: runtime rejection before unmount must preserve the exact existing session binding") }
            } else {
                guard !controller.isWritable(volume), controller.sessionVolumes.isEmpty else { fatalError("CHECK FAILED: rejected write must not create a new binding") }
            }
            for _ in 0..<30 { await Task.yield() }
            guard await raw.actions == (heldAtEject ? [.mountReadWrite, .unmountDisk, .ejectDisk] : (mountFirst ? [.mountReadWrite, .unmountDisk] : [.mountReadWrite])) else { fatalError("CHECK FAILED: runtime rejection must not loop or continue to eject") }
            guard case let .loaded(snapshot) = await archive.load() else { fatalError("CHECK FAILED: actual runtime rejection must be archived") }
            let operations = snapshot.entries.compactMap { entry -> DiagnosticOperationEvent? in if case let .operation(event) = entry.event { return event }; return nil }
            guard let event = operations.last, event.result == .engineFailed,
                  event.certainty == .unchanged, event.stage == .inspectSafety,
                  event.helperStageCode == 1, event.traceID != nil else { fatalError("CHECK FAILED: runtime resource gate rejection must archive engineFailed/unchanged/inspectSafety") }
        }
        print("PASS: actual runtime-resource rejection preserves target binding, rejects write/release once and archives a distinct safety result")
    }
}
