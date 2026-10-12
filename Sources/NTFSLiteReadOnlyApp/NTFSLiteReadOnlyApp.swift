import AppKit
import Combine
import NTFSLiteCore
import NTFSLiteDiagnostics
import NTFSLitePresentation
import NTFSLiteSystem
import NTFSLiteWriteSession
import SwiftUI

@main
@MainActor
struct NTFSLiteReadOnlyApp: App {
    @NSApplicationDelegateAdaptor(ReadOnlyAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            AppInformationSettings()
        }
    }
}

private struct AppInformationSettings: View {
    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return "版本 \(version ?? "未知")（\(build ?? "未知")）"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("NTFS 轻量助手", systemImage: "externaldrive.fill")
                .font(.title2.weight(.semibold))
            Text(versionText)
                .foregroundStyle(.secondary)
            Divider()
            Text("使用方式")
                .font(.headline)
            Text("连接外置 NTFS 磁盘，在主窗口选择卷。启用写入前确认它是普通数据卷；结束文件操作后安全推出整块磁盘。")
                .fixedSize(horizontal: false, vertical: true)
            Text("运行环境检查和脱敏诊断位于主窗口。此版本没有需要配置的应用偏好。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("写入能力来自有限的实物验证；Windows 端复核和长期兼容性验证尚未完成。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 420)
    }
}

@MainActor
final class ReadOnlyAppStore: ObservableObject {
    @Published private(set) var dashboard: ReadOnlyDashboardPresentation
    @Published private(set) var selectionResetEpoch: ReadOnlySelectionResetEpoch
    @Published private(set) var diagnosticsText = "尚无诊断记录。"
    private(set) lazy var writeController: WriteController = {
        let controller = WriteController(
            service: helperService,
            transport: DiagnosticHelperTransport(transport: helperTransport, diagnostics: diagnostics),
            operationCompleted: { [weak self] in await self?.publishDiagnosticsSnapshot() },
            refreshObservation: { [weak self] in self?.recheckCurrentObservation() },
            canRequestWriting: { [weak self] id in
                self?.dashboard.volumes.first(where: { $0.id == id })?.actions.canEnableWriting == true
            },
            canRequestEject: { [weak self] id in
                self?.dashboard.physicalDisks.first(where: { $0.id == id })?
                    .volumes.contains(where: { $0.actions.canSafeEject }) == true
            }
        )
        // Setup observes this store. Forward child changes so async helper results
        // redraw that page immediately, without requiring a dashboard refresh or navigation.
        writeControllerObservation = controller.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        setupHelperStateObservation = controller.$helperState.removeDuplicates().sink { [weak self] state in
            self?.acceptHelperState(state)
        }
        return controller
    }()

    private let helperService: HelperServiceEnvironment
    private let helperTransport: any HelperTransport
    private let diskObserver: ReadOnlyDiskObserver
    private let setupLoader: SystemSetupFactsLoader
    private let setupReportProvider: @Sendable (SystemSetupFactsLoader) async -> SystemSetupReport
    private var currentSetupHelperState: HelperServiceState = .notRegistered
    private var setupHelperStateObservation: AnyCancellable?
    private var setupRefreshToken = UUID()
    private let diagnostics: Diagnostics
    private let diagnosticsArchive: DiagnosticSnapshotArchive?
    private let applicationIdentity: DiagnosticApplicationIdentity?
    private var observationSession: ReadOnlyObservationSession
    private var setupAssessment = SetupAssessment(issues: [])
    private var setupReport: SystemSetupReport?
    private var isSetupRefreshing = true
    private var observationTask: Task<Void, Never>?
    private var observationCapture: ReadOnlyDiskObservationCapture?
    private var setupTask: Task<Void, Never>?
    private var diagnosticsDisplayRevision = UUID()
    private var hasStarted = false
    private var writeControllerObservation: AnyCancellable?

    init(
        diskObserver: ReadOnlyDiskObserver = ReadOnlyDiskObserver(),
        setupLoader: SystemSetupFactsLoader = SystemSetupFactsLoader(
            authorizationProvider: SetupAuthorizationStatusProvider {
                await AppSetupEvidenceReader.currentAuthorizationStatus()
            },
            macFUSEPolicy: LocalMacFUSESetupPolicy.current
        ),
        setupReportProvider: @escaping @Sendable (SystemSetupFactsLoader) async -> SystemSetupReport = {
            await AppSetupEvidenceReader.currentReport(using: $0)
        },
        helperService: HelperServiceEnvironment = .live,
        helperTransport: any HelperTransport = HelperXPCTransport(),
        diagnostics: Diagnostics = Diagnostics(),
        diagnosticsArchive: DiagnosticSnapshotArchive? = nil,
        applicationIdentity: DiagnosticApplicationIdentity? = ReadOnlyAppStore
            .currentApplicationIdentity()
    ) {
        let observationSession = ReadOnlyObservationSession()
        self.helperService = helperService
        self.helperTransport = helperTransport
        self.diskObserver = diskObserver
        self.setupLoader = setupLoader
        self.setupReportProvider = setupReportProvider
        self.diagnostics = diagnostics
        self.diagnosticsArchive = diagnosticsArchive ?? Self.currentDiagnosticsArchive()
        self.applicationIdentity = applicationIdentity
        self.observationSession = observationSession
        selectionResetEpoch = observationSession.selectionResetEpoch
        dashboard = ReadOnlyDashboardPresenter.presentation(
            for: observationSession.observation,
            setupAssessment: setupAssessment,
            isSetupRefreshing: true
        )
    }

    deinit {
        observationCapture?.stopImmediately()
        observationTask?.cancel()
        setupTask?.cancel()
    }

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        loadPersistedDiagnostics()
        refresh()
    }

    /// Refresh only the diagnostic report; helper state notifications never call
    /// this method, so revocation cannot start a recursive chain of XPC checks.
    func refreshSetup() {
        setupTask?.cancel()
        setupRefreshToken = UUID()
        let token = setupRefreshToken
        isSetupRefreshing = true
        setupReport = nil
        render()
        setupTask = Task { [weak self, setupLoader, setupReportProvider] in
            let report = await setupReportProvider(setupLoader)
            guard !Task.isCancelled, let self, self.setupRefreshToken == token else { return }
            let finalReport = self.reportMatchingCurrentHelperState(report)
            self.setupReport = finalReport
            self.setupAssessment = SetupChecker.assess(finalReport.reconciledFacts)
            self.isSetupRefreshing = false
            self.render()
            await self.recordSetupDiagnostics(report: finalReport)
        }
    }

    private func reportMatchingCurrentHelperState(_ report: SystemSetupReport) -> SystemSetupReport {
        guard currentSetupHelperState != .enabled else { return report }
        let authorization: SetupAuthorizationStatus = currentSetupHelperState == .requiresApproval
            || currentSetupHelperState == .notRegistered ? .denied : .unknown
        return report.recordingAuthorization(authorization)
    }

    /// Consumes the same typed helper state used by the visible controller.
    /// This only revokes diagnostic evidence; it cannot approve disk operations.
    func acceptHelperState(_ state: HelperServiceState) {
        currentSetupHelperState = state
        guard state != .enabled, let report = setupReport else { return }
        let revokedReport = reportMatchingCurrentHelperState(report)
        setupReport = revokedReport
        setupAssessment = SetupChecker.assess(revokedReport.reconciledFacts)
        render()
    }

    /// Revalidate post-operation facts without replacing this connection's identity scope.
    func recheckCurrentObservation() {
        writeController.refreshHelperState()
        refreshSetup()
        if observationCapture?.refresh() == true { return }
        // An ended source cannot prove absence or safely rebind an active operation.
        if !writeController.hasBoundDiskSession { refresh(restartObservation: true) }
    }

    func refresh(restartObservation: Bool = false) {
        if !restartObservation, writeController.hasBoundDiskSession {
            recheckCurrentObservation()
            return
        }
        writeController.refreshHelperState()
        refreshSetup()
        observationCapture?.stopImmediately()
        observationCapture = nil
        let revision = observationSession.beginRefresh()
        selectionResetEpoch = observationSession.selectionResetEpoch
        observationTask?.cancel()

        observationTask = Task { [weak self, diskObserver] in
            do {
                let capture = try diskObserver.capture()
                guard self?.observationSession.isCurrent(revision) == true else {
                    capture.stopImmediately()
                    return
                }
                self?.observationCapture = capture
                for await event in capture.events {
                    guard case let .observation(observation) = event else { continue }
                    guard !Task.isCancelled,
                          let self,
                          self.observationSession.isCurrent(revision)
                    else {
                        return
                    }
                    guard self.observationSession.accept(observation, for: revision) else {
                        return
                    }
                    self.render()
                    await self.recordInventoryDiagnostics(observation)
                }
                guard !Task.isCancelled,
                      let self,
                      self.observationSession.isCurrent(revision)
                else {
                    return
                }
                await self.publishEventSourceUnavailable(for: revision)
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.observationSession.isCurrent(revision)
                else {
                    return
                }
                await self.publishEventSourceUnavailable(for: revision)
            }
        }
    }

    var menuSummary: String {
        dashboard.title
    }

    func clearDiagnostics() async -> Bool {
        let revision = UUID()
        diagnosticsDisplayRevision = revision
        await diagnostics.clear()
        do {
            let snapshot = await diagnostics.snapshot()
            if diagnosticsDisplayRevision == revision {
                diagnosticsText = try snapshot.copyText()
            }
            guard let diagnosticsArchive else {
                return true
            }
            guard await diagnosticsArchive.clear() == .cleared else {
                if diagnosticsDisplayRevision == revision {
                    diagnosticsText += "\n本地旧诊断存档未清除。"
                }
                return false
            }
            return true
        } catch {
            if diagnosticsDisplayRevision == revision {
                diagnosticsText = "诊断摘要暂不可用。"
            }
            return false
        }
    }

    private func render() {
        dashboard = ReadOnlyDashboardPresenter.presentation(
            for: observationSession.observation,
            setupAssessment: setupAssessment,
            isSetupRefreshing: isSetupRefreshing,
            setupReport: setupReport
        )
        writeController.reconcile(observation: observationSession.observation)
    }

    private func recordSetupDiagnostics(report: SystemSetupReport) async {
        do {
            guard let applicationIdentity else {
                diagnosticsText = "诊断摘要暂不可用。"
                return
            }
            let input = try DiagnosticProjection.setup(
                facts: report.reconciledFacts,
                assessment: setupAssessment,
                applicationVersion: applicationIdentity.version,
                applicationBuild: applicationIdentity.build
            )
            try await diagnostics.record(input)
            await publishDiagnosticsSnapshot()
        } catch {
            diagnosticsText = "诊断摘要暂不可用。"
        }
    }

    private func recordInventoryDiagnostics(
        _ observation: DiskInventoryObservation
    ) async {
        do {
            try await diagnostics.record(DiagnosticProjection.inventory(observation))
            await publishDiagnosticsSnapshot()
        } catch {
            diagnosticsText = "诊断摘要暂不可用。"
        }
    }

    func publishDiagnosticsSnapshot() async {
        let revision = UUID()
        diagnosticsDisplayRevision = revision
        do {
            let archiveGeneration: DiagnosticSnapshotArchiveGeneration?
            if let diagnosticsArchive {
                archiveGeneration = await diagnosticsArchive.currentGeneration()
            } else {
                archiveGeneration = nil
            }
            let snapshot = await diagnostics.snapshot()
            guard diagnosticsDisplayRevision == revision else {
                return
            }
            diagnosticsText = try snapshot.copyText()
            guard let diagnosticsArchive, let archiveGeneration else {
                return
            }
            switch await diagnosticsArchive.save(
                snapshot,
                generation: archiveGeneration
            ) {
            case .saved:
                break
            case .superseded:
                return
            case .failedClosed:
                guard diagnosticsDisplayRevision == revision else {
                    return
                }
                diagnosticsText += "\n本地诊断存档未保存。"
            }
        } catch {
            if diagnosticsDisplayRevision == revision {
                diagnosticsText = "诊断摘要暂不可用。"
            }
        }
    }

    private func loadPersistedDiagnostics() {
        guard let diagnosticsArchive else {
            return
        }
        let revision = UUID()
        diagnosticsDisplayRevision = revision
        Task { [weak self, diagnosticsArchive] in
            let result = await diagnosticsArchive.load()
            guard !Task.isCancelled,
                  let self,
                  self.diagnosticsDisplayRevision == revision
            else {
                return
            }
            switch result {
            case let .loaded(snapshot):
                do {
                    self.diagnosticsText = try snapshot.copyText(source: .previousRun)
                } catch {
                    self.diagnosticsText = "上次诊断存档不可用。"
                }
            case .unavailable:
                break
            case .failedClosed:
                self.diagnosticsText = "上次诊断存档未通过完整性检查。"
            }
        }
    }

    private func publishEventSourceUnavailable(
        for revision: ReadOnlyObservationRefreshToken
    ) async {
        guard observationSession.sourceBecameUnavailable(for: revision) else {
            return
        }
        render()
        await recordInventoryDiagnostics(observationSession.observation)
    }

    private static func currentApplicationIdentity(
        bundle: Bundle = .main
    ) -> DiagnosticApplicationIdentity? {
        let result = DiagnosticApplicationIdentityParser.parse(
            shortVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            buildVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String
        )
        guard case let .success(identity) = result else {
            return nil
        }
        return identity
    }

    private static func currentDiagnosticsArchive() -> DiagnosticSnapshotArchive? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        do {
            let policy = try DiagnosticSnapshotArchivePolicy(
                directoryURL: applicationSupport.appendingPathComponent(
                    "NTFSLiteReadOnly",
                    isDirectory: true
                )
            )
            return DiagnosticSnapshotArchive(policy: policy)
        } catch {
            return nil
        }
    }
}

extension Notification.Name {
    static let ntfsLiteRefreshRequested = Notification.Name(
        "NTFSLite.ReadOnly.RefreshRequested"
    )
}

@MainActor
final class ReadOnlyAppDelegate: NSObject, NSApplicationDelegate {
    private let store: ReadOnlyAppStore

    override init() {
        self.store = ReadOnlyAppStore()
        super.init()
    }

    init(store: ReadOnlyAppStore) {
        self.store = store
        super.init()
    }
    private var statusItem: NSStatusItem?
    private var menuSummaryItem: NSMenuItem?
    private var mainWindowController: NSWindowController?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        installMainWindow()
        store.start()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(refreshAfterWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        store.writeController.refreshHelperState()
        store.refreshSetup()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        // SwiftUI only owns Settings; the main page is our retained AppKit window.
        // Handle Dock reopening explicitly, including when Settings remains visible.
        openMainWindow()
        return false
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(
            systemSymbolName: "externaldrive.fill",
            accessibilityDescription: "NTFS 轻量助手"
        ) {
            image.isTemplate = true
            item.button?.image = image
            item.button?.imagePosition = .imageOnly
        } else {
            item.button?.title = "NTFS"
        }
        item.button?.toolTip = "NTFS 轻量助手"

        let menu = NSMenu()
        let summaryItem = NSMenuItem(
            title: store.menuSummary,
            action: nil,
            keyEquivalent: ""
        )
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "打开主窗口",
                action: #selector(openMainWindow),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "重新读取",
                action: #selector(refresh),
                keyEquivalent: "r"
            )
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "退出",
                action: #selector(terminate),
                keyEquivalent: "q"
            )
        )
        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
        menuSummaryItem = summaryItem
        store.$dashboard
            .map(\.title)
            .removeDuplicates()
            .sink { [weak self] title in
                self?.menuSummaryItem?.title = title
            }
            .store(in: &cancellables)
    }

    func installMainWindow() {
        let rootView = ReadOnlyMainWindow(store: store)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NTFS 轻量助手"
        window.contentViewController = hostingController
        window.contentMinSize = NSSize(width: 320, height: 460)
        window.setContentSize(NSSize(width: 820, height: 620))
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        mainWindowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openMainWindow() {
        if mainWindowController?.window?.isMiniaturized == true {
            mainWindowController?.window?.deminiaturize(nil)
        }
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func refresh() {
        NotificationCenter.default.post(name: .ntfsLiteRefreshRequested, object: nil)
        openMainWindow()
    }

    @objc private func refreshAfterWake() {
        store.refresh(restartObservation: true)
    }

    @objc private func terminate() {
        NSApplication.shared.terminate(nil)
    }
}
