import AppKit
import Combine
import NTFSLiteCore
import NTFSLiteDiagnostics
import NTFSLitePresentation
import NTFSLiteSystem
import SwiftUI

@main
@MainActor
struct NTFSLiteReadOnlyApp: App {
    @NSApplicationDelegateAdaptor(ReadOnlyAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class ReadOnlyAppStore: ObservableObject {
    @Published private(set) var dashboard: ReadOnlyDashboardPresentation
    @Published private(set) var selectionResetEpoch: ReadOnlySelectionResetEpoch
    @Published private(set) var diagnosticsText = "尚无诊断记录。"

    private let diskObserver: ReadOnlyDiskObserver
    private let setupLoader: SystemSetupFactsLoader
    private let diagnostics: Diagnostics
    private let diagnosticsArchive: DiagnosticSnapshotArchive?
    private let applicationIdentity: DiagnosticApplicationIdentity?
    private var observationSession: ReadOnlyObservationSession
    private var setupAssessment = SetupAssessment(issues: [])
    private var setupReport: SystemSetupReport?
    private var isSetupRefreshing = true
    private var observationTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var diagnosticsDisplayRevision = UUID()
    private var hasStarted = false

    init(
        diskObserver: ReadOnlyDiskObserver = ReadOnlyDiskObserver(),
        setupLoader: SystemSetupFactsLoader = SystemSetupFactsLoader(),
        diagnostics: Diagnostics = Diagnostics(),
        diagnosticsArchive: DiagnosticSnapshotArchive? = nil,
        applicationIdentity: DiagnosticApplicationIdentity? = ReadOnlyAppStore
            .currentApplicationIdentity()
    ) {
        let observationSession = ReadOnlyObservationSession()
        self.diskObserver = diskObserver
        self.setupLoader = setupLoader
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

    func refresh() {
        let revision = observationSession.beginRefresh()
        selectionResetEpoch = observationSession.selectionResetEpoch
        observationTask?.cancel()
        setupTask?.cancel()

        isSetupRefreshing = true
        setupReport = nil
        render()

        setupTask = Task { [weak self, setupLoader] in
            let report = await setupLoader.currentReport()
            guard !Task.isCancelled,
                  let self,
                  self.observationSession.isCurrent(revision)
            else {
                return
            }
            self.setupReport = report
            self.setupAssessment = SetupChecker.assess(report.reconciledFacts)
            self.isSetupRefreshing = false
            self.render()
            await self.recordSetupDiagnostics(report: report)
        }

        observationTask = Task { [weak self, diskObserver] in
            do {
                let observations = try diskObserver.observations()
                for await observation in observations {
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

    private func publishDiagnosticsSnapshot() async {
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
                    self.diagnosticsText = try snapshot.copyText()
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
    private let store = ReadOnlyAppStore()
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "NTFS"
        item.button?.toolTip = "NTFS 轻量助手（只读观察）"

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

    private func installMainWindow() {
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
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func refresh() {
        NotificationCenter.default.post(name: .ntfsLiteRefreshRequested, object: nil)
        openMainWindow()
    }

    @objc private func refreshAfterWake() {
        store.refresh()
    }

    @objc private func terminate() {
        NSApplication.shared.terminate(nil)
    }
}
