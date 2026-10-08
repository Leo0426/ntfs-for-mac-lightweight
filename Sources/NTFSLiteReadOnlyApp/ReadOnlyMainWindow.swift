import NTFSLiteCore
import NTFSLitePresentation
import SwiftUI

struct ReadOnlyMainWindow: View {
    @ObservedObject var store: ReadOnlyAppStore
    @State private var retainedSelection: ReadOnlyDashboardSelection = .overview
    @State private var navigationLayout: ReadOnlyNavigationLayout = .wide
    @FocusState private var navigationFocus: ReadOnlyNavigationFocus?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geometry in
                let currentLayout: ReadOnlyNavigationLayout = geometry.size.width < 560
                    ? .compact
                    : .wide
                Group {
                    if currentLayout == .compact {
                        compactContent
                    } else {
                        wideContent
                    }
                }
                .onAppear {
                    reconcileNavigationLayout(to: currentLayout)
                }
                .onChange(of: currentLayout) { _, layout in
                    reconcileNavigationLayout(to: layout)
                }
            }
        }
        .frame(minWidth: 320, minHeight: 460)
        .task {
            store.start()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .ntfsLiteRefreshRequested)
        ) { _ in
            store.refresh()
        }
        .onChange(of: store.selectionResetEpoch) { previousEpoch, currentEpoch in
            let previousPresentedSelection = presentedSelection
            let nextRetainedSelection = ReadOnlySelectionPresenter.reconciledSelection(
                retainedSelection,
                selectedIn: previousEpoch,
                for: store.dashboard,
                in: currentEpoch
            )
            applySelectionReconciliation(
                nextRetainedSelection,
                previousPresentedSelection: previousPresentedSelection,
                dashboard: store.dashboard
            )
        }
        .onChange(of: store.dashboard) { previousDashboard, dashboard in
            let previousPresentedSelection = ReadOnlySelectionPresenter
                .presentedSelection(
                    for: retainedSelection,
                    in: previousDashboard
                )
            let nextRetainedSelection = ReadOnlySelectionPresenter.reconciledSelection(
                retainedSelection,
                for: dashboard
            )
            applySelectionReconciliation(
                nextRetainedSelection,
                previousPresentedSelection: previousPresentedSelection,
                dashboard: dashboard
            )
        }
        .onChange(of: currentAccessibilityAnnouncementEvent) { _, event in
            postAccessibilityAnnouncement(event.text)
        }
    }

    private var currentAccessibilityAnnouncementEvent: ReadOnlyAccessibilityAnnouncementEvent {
        ReadOnlyAccessibilityPresenter.announcementEvent(
            for: presentedSelection,
            in: store.dashboard
        )
    }

    private var presentedSelection: ReadOnlyDashboardSelection {
        ReadOnlySelectionPresenter.presentedSelection(
            for: retainedSelection,
            in: store.dashboard
        )
    }

    private var presentedSelectionBinding: Binding<ReadOnlyDashboardSelection> {
        Binding(
            get: { presentedSelection },
            set: { retainedSelection = $0 }
        )
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                appIdentity
                Spacer(minLength: 12)
                observationBadge
                refreshButton
            }
            HStack(spacing: 12) {
                appIdentity
                Spacer(minLength: 8)
                refreshButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.regularMaterial)
    }

    private var appIdentity: some View {
        HStack(spacing: 11) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("NTFS 轻量助手")
                    .font(.headline)
                Text("外置磁盘状态与安全操作")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var observationBadge: some View {
        let declarationAvailable = store.dashboard.volumes.contains {
            $0.actions.canEnableWriting && $0.actions.requiresDataDeclaration
        }
        let status: (symbol: String, title: String, color: Color) = switch store.dashboard.phase {
        case .scanning: ("arrow.triangle.2.circlepath", "正在检查", .secondary)
        case .limited: declarationAvailable
            ? ("questionmark.circle.fill", "请确认卷用途", .orange)
            : ("exclamationmark.circle.fill", "信息待确认", .orange)
        case .settled: ("checkmark.circle.fill", "磁盘检查完成", .green)
        }
        return Label(status.title, systemImage: status.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(status.color.opacity(0.10), in: Capsule())
    }

    private var refreshButton: some View {
        Button {
            store.refresh()
        } label: {
            Label("重新读取", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .help("重新读取磁盘与运行环境状态")
    }

    private var wideContent: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            Divider()
            detail
        }
    }

    private var compactContent: some View {
        VStack(spacing: 0) {
            Picker("当前项目", selection: presentedSelectionBinding) {
                pickerEntries
            }
            .pickerStyle(.menu)
            .focused($navigationFocus, equals: .compactPicker)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            detail
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sidebarGroup(title: "工作台") {
                    sidebarButton("概览", symbol: "square.grid.2x2", selection: .overview)
                }
                ForEach(store.dashboard.physicalDisks) { disk in
                    sidebarGroup(title: disk.title) {
                        ForEach(disk.volumes) { volume in
                            sidebarButton(
                                volume.title,
                                symbol: "externaldrive",
                                subtitle: volume.accessText,
                                selection: .volume(volume.id)
                            )
                        }
                    }
                }
                sidebarGroup(title: "工具") {
                    sidebarButton("运行环境", symbol: "checklist", selection: .environment)
                    sidebarButton("诊断摘要", symbol: "waveform.path.ecg", selection: .diagnostics)
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var pickerEntries: some View {
        Text("磁盘 · 概览").tag(ReadOnlyDashboardSelection.overview)
        ForEach(store.dashboard.physicalDisks) { disk in
            Section(disk.title) {
                ForEach(disk.volumes) { volume in
                    Text("\(disk.title) · \(volume.title)")
                        .tag(ReadOnlyDashboardSelection.volume(volume.id))
                        .accessibilityLabel(
                            ReadOnlyAccessibilityPresenter.selectionLabel(
                                for: .volume(volume.id),
                                in: store.dashboard
                            )
                        )
                }
            }
        }
        Text("设置 · 运行环境").tag(ReadOnlyDashboardSelection.environment)
        Text("设置 · 诊断摘要").tag(ReadOnlyDashboardSelection.diagnostics)
    }

    private func sidebarGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func sidebarButton(
        _ title: String,
        symbol: String,
        subtitle: String? = nil,
        selection target: ReadOnlyDashboardSelection
    ) -> some View {
        Button {
            retainedSelection = target
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(presentedSelection == target ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .fontWeight(presentedSelection == target ? .semibold : .regular)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($navigationFocus, equals: .wide(target))
        .background(
            presentedSelection == target ? Color.accentColor.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .accessibilityLabel(
            ReadOnlyAccessibilityPresenter.selectionLabel(
                for: target,
                in: store.dashboard
            )
        )
        .accessibilityValue(presentedSelection == target ? "已选中" : "未选中")
    }

    private var detail: some View {
        ScrollView {
            Group {
                switch ReadOnlySelectionPresenter.detail(
                    for: presentedSelection,
                    in: store.dashboard
                ) {
                case .overview:
                    ReadOnlyOverview(
                        dashboard: store.dashboard,
                        writeController: store.writeController,
                        selectVolume: { retainedSelection = .volume($0) },
                        openEnvironment: { retainedSelection = .environment }
                    )
                case let .volume(volume, disk):
                    ReadOnlyVolumeDetail(
                        volume: volume,
                        physicalDisk: disk,
                        writeController: store.writeController,
                        openEnvironment: { retainedSelection = .environment }
                    )
                case .environment:
                    ReadOnlySetupDetail(store: store, setup: store.dashboard.setup)
                case .diagnostics:
                    ReadOnlyDiagnosticsDetail(store: store)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(presentedSelection)
    }

    private func applySelectionReconciliation(
        _ nextRetainedSelection: ReadOnlyDashboardSelection,
        previousPresentedSelection: ReadOnlyDashboardSelection,
        dashboard: ReadOnlyDashboardPresentation
    ) {
        let nextPresentedSelection = ReadOnlySelectionPresenter.presentedSelection(
            for: nextRetainedSelection,
            in: dashboard
        )
        navigationFocus = ReadOnlyNavigationFocusPresenter.reconciledFocus(
            navigationFocus,
            from: navigationLayout,
            to: navigationLayout,
            previousPresentedSelection: previousPresentedSelection,
            currentPresentedSelection: nextPresentedSelection,
            in: dashboard
        )
        retainedSelection = nextRetainedSelection
    }

    private func reconcileNavigationLayout(
        to currentLayout: ReadOnlyNavigationLayout
    ) {
        navigationFocus = ReadOnlyNavigationFocusPresenter.reconciledFocus(
            navigationFocus,
            from: navigationLayout,
            to: currentLayout,
            previousPresentedSelection: presentedSelection,
            currentPresentedSelection: presentedSelection,
            in: store.dashboard
        )
        navigationLayout = currentLayout
    }
}

private struct ReadOnlyDiagnosticsDetail: View {
    @ObservedObject var store: ReadOnlyAppStore
    @State private var actionFeedback: ReadOnlyActionFeedback?
    @State private var isClearing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("诊断摘要")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("用于排查运行环境和磁盘识别问题。内容已按固定字段脱敏。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label("不包含用户名、完整路径、卷标、设备 UUID 或 BSD 名。复制前仍可先检查下方内容。",
                  systemImage: "hand.raised.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .surfacePanel()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    copySummaryButton
                    clearDiagnosticsButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    copySummaryButton
                    clearDiagnosticsButton
                }
            }

            if let actionFeedback {
                Text(actionFeedback.visibleText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(actionFeedback.accessibilityAnnouncement)
            }

            GroupBox("诊断报告") {
                ScrollView(.vertical) {
                    Text(store.diagnosticsText)
                        .font(.body)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 220, maxHeight: 360)
            }
        }
    }

    private var copySummaryButton: some View {
        Button(ReadOnlyDiagnosticInteractionPresenter.copyActionTitle) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let copied = pasteboard.setString(
                store.diagnosticsText,
                forType: .string
            )
            report(
                ReadOnlyDiagnosticInteractionPresenter.copyFeedback(
                    didSucceed: copied
                )
            )
        }
    }

    private var clearDiagnosticsButton: some View {
        Button(
            ReadOnlyDiagnosticInteractionPresenter.clearActionTitle(
                isClearing: isClearing
            )
        ) {
            isClearing = true
            report(ReadOnlyDiagnosticInteractionPresenter.clearStartedFeedback)
            Task {
                let cleared = await store.clearDiagnostics()
                report(
                    ReadOnlyDiagnosticInteractionPresenter.clearFeedback(
                        didSucceed: cleared
                    )
                )
                isClearing = false
            }
        }
        .disabled(isClearing)
    }

    private func report(_ feedback: ReadOnlyActionFeedback) {
        actionFeedback = feedback
        postAccessibilityAnnouncement(feedback.accessibilityAnnouncement)
    }
}

private struct ReadOnlyOverview: View {
    let dashboard: ReadOnlyDashboardPresentation
    @ObservedObject var writeController: WriteController
    let selectVolume: (VolumeInstanceID) -> Void
    let openEnvironment: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("磁盘概览")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("查看连接状态，选择一个卷继续。")
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 14) {
                Image(systemName: dashboard.phase == .limited
                    ? "exclamationmark.shield.fill" : "externaldrive.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(dashboard.phase == .limited ? Color.orange : Color.accentColor)
                    .frame(width: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    Text(dashboard.title)
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(dashboard.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if dashboard.phase == .scanning {
                        ProgressView("正在读取系统磁盘信息")
                            .padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
            }
            .surfacePanel()

            WritableVolumesSummary(
                controller: writeController,
                openEnvironment: openEnvironment
            )

            ForEach(dashboard.physicalDisks) { disk in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 9) {
                        Image(systemName: "externaldrive.fill")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        Text(disk.title)
                            .font(.headline)
                        Spacer()
                        Text("\(disk.volumes.count) 个卷")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 11) {
                        Text(disk.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(disk.volumes) { volume in
                            Button {
                                selectVolume(volume.id)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.on.externaldrive")
                                        .foregroundStyle(Color.accentColor)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(volume.title)
                                            .fontWeight(.medium)
                                            .lineLimit(2)
                                            .truncationMode(.middle)
                                        Text(volume.accessText)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                        .accessibilityHidden(true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color(nsColor: .controlBackgroundColor),
                                            in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("查看\(disk.title)中的\(volume.title)，\(volume.accessText)")
                        }
                    }
                }
                .surfacePanel()
            }

            if dashboard.physicalDisks.isEmpty && dashboard.phase == .settled {
                VStack(alignment: .leading, spacing: 12) {
                    Label("准备连接磁盘", systemImage: "cable.connector")
                        .font(.headline)
                    Text("连接外置 NTFS 磁盘后会自动显示。第一次使用时，可以先查看运行环境。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("查看运行环境", action: openEnvironment)
                        .buttonStyle(.bordered)
                }
                .surfacePanel()
            }

            Label("写入能力基于有限的实物验证，Windows 端复核和长期兼容性验证尚未完成。重要数据请先备份。",
                  systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ReadOnlyVolumeDetail: View {
    let volume: ReadOnlyVolumePresentation
    let physicalDisk: ReadOnlyPhysicalDiskPresentation
    @ObservedObject var writeController: WriteController
    let openEnvironment: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 54, height: 54)
                    .background(Color.accentColor.opacity(0.11),
                                in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(volume.title)
                        .font(.largeTitle.bold())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .accessibilityAddTraits(.isHeader)
                    Text("NTFS 卷 · \(physicalDisk.title)")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("原生分区的最近一次观察", systemImage: "circle.grid.cross")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(volume.accessText)
                    .font(.title2.weight(.semibold))
                Text(volume.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfacePanel()

            VStack(alignment: .leading, spacing: 8) {
                Label("所在磁盘", systemImage: "square.stack.3d.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(physicalDisk.title)
                    .font(.headline)
                Text(physicalDisk.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfacePanel()

            VolumeWriteActions(
                controller: writeController,
                volume: volume,
                physicalDisk: physicalDisk,
                openEnvironment: openEnvironment
            )
        }
    }
}

private struct ReadOnlySetupDetail: View {
    @ObservedObject var store: ReadOnlyAppStore
    let setup: SetupPresentation
    @State private var expandedSetupGroupID: SetupRequirementGroupID?
    @AccessibilityFocusState private var focusedSetupGroupID: SetupRequirementGroupID?
    @State private var actionFeedback: ReadOnlyActionFeedback?
    @State private var isAwaitingRecheckResult = false
    @State private var isConfirmingHelperReregistration = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("运行环境")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("查看依赖和系统状态。启用写入时，帮助程序仍会重新核对目标磁盘与安全条件。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("后台帮助程序", systemImage: "lock.shield")
                    .font(.headline)
                Text(store.writeController.helperState.text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let helperMessage = store.writeController.helperMessage {
                    Text(helperMessage)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.writeController.helperState.canAttemptRegistration {
                    Button(store.writeController.helperState == .notFound
                           ? "尝试注册帮助程序" : "启用帮助程序") {
                        store.writeController.installHelper()
                    }
                    .buttonStyle(.borderedProminent)
                } else if store.writeController.helperState == .requiresApproval {
                    Button("打开系统设置") {
                        store.writeController.openHelperApprovalSettings()
                    }
                    .buttonStyle(.borderedProminent)
                } else if store.writeController.helperState.canAttemptReregistration {
                    Button("重新注册帮助程序") {
                        isConfirmingHelperReregistration = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.writeController.isReregisteringHelper)
                }
                Button("重新检查帮助程序") {
                    store.writeController.refreshHelperState()
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfacePanel()
            .confirmationDialog("重新注册帮助程序？", isPresented: $isConfirmingHelperReregistration) {
                Button("重新注册") {
                    store.writeController.reregisterHelper()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会先注销后台帮助程序并等待系统完成，再重新注册。不会操作任何磁盘；之后可能需要在“系统设置 → 通用 → 登录项与扩展”中重新允许。")
            }
            .onChange(of: store.writeController.helperState) { _, newState in
                if !newState.canAttemptReregistration { isConfirmingHelperReregistration = false }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("只读环境检查")
                        .font(.headline)
                    Spacer()
                    if setup.isBusy {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("正在检查运行环境")
                    }
                }
                Text(setup.title + "。" + setup.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfacePanel()

            ForEach(setup.groups, id: \.id) { group in
                setupGroup(group)
            }

            if let primaryAction = visiblePrimaryAction {
                Button(primaryAction.title) {
                    perform(primaryAction)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(setup.isBusy)
            }

            ForEach(Array(setup.secondaryActions.enumerated()), id: \.offset) { _, action in
                Button(action.title) {
                    perform(action)
                }
                .disabled(setup.isBusy)
            }

            if let actionFeedback {
                Text(actionFeedback.visibleText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(actionFeedback.accessibilityAnnouncement)
            }

            GroupBox("说明") {
                Text("环境检查只读取系统状态。帮助程序安装需要你明确点击；应用不会自动下载依赖或更改系统设置。")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: setup) { _, currentSetup in
            guard isAwaitingRecheckResult, !currentSetup.isBusy else {
                return
            }
            isAwaitingRecheckResult = false
            report(
                ReadOnlySetupInteractionPresenter
                    .completedRecheckFeedback(for: currentSetup)
            )
        }
    }

    private var visiblePrimaryAction: SetupPresentationAction? {
        ReadOnlySetupInteractionPresenter.primaryAction(
            for: setup,
            guideRequirementID: guideRequirementID
        )
    }

    private var guideRequirementID: SetupRequirementID? {
        setup.groups.first { $0.id == expandedSetupGroupID }?
            .requirements.first { $0.state == .actionRequired }?.id
    }

    private func perform(_ action: SetupPresentationAction) {
        switch action {
        case .continueSetup:
            let group = ReadOnlySetupInteractionPresenter.guideGroup(for: setup)
            expandedSetupGroupID = group?.id
            report(
                ReadOnlySetupInteractionPresenter.guideFeedback(
                    group: group
                )
            )
            if let group {
                focusedSetupGroupID = group.id
            }
        case .recheck:
            isAwaitingRecheckResult = true
            report(ReadOnlySetupInteractionPresenter.recheckStartedFeedback)
            store.refresh()
        case .copyDiagnostics:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let copied = pasteboard.setString(
                store.diagnosticsText,
                forType: .string
            )
            report(
                ReadOnlyDiagnosticInteractionPresenter.copyFeedback(
                    didSucceed: copied
                )
            )
        }
    }

    private func report(_ feedback: ReadOnlyActionFeedback) {
        actionFeedback = feedback
        postAccessibilityAnnouncement(feedback.accessibilityAnnouncement)
    }

    private func setupGroup(_ group: SetupRequirementGroupPresentation) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedSetupGroupID == group.id },
            set: { expandedSetupGroupID = $0 ? group.id : nil }
        )) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.requirements, id: \.id) { row in
                    Divider()
                    setupRequirementRow(row)
                }
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(group.title)
                        .font(.headline)
                    Spacer(minLength: 4)
                    Text(group.statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor(group.state))
                }
                Text(group.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(group.title)，\(group.statusText)。\(group.detail)")
        }
        .accessibilityFocused($focusedSetupGroupID, equals: group.id)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfacePanel()
    }

    private func setupRequirementRow(_ row: SetupRequirementPresentation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: requirementSymbol(row.state))
                .foregroundStyle(statusColor(row.state))
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.title)
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text(row.statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor(row.state))
                        .fixedSize()
                }
                Text(row.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title)，\(row.statusText)。\(row.detail)")
    }

    private func statusColor(_ state: SetupRequirementState) -> Color {
        switch state {
        case .satisfied:
            return .green
        case .actionRequired:
            return .orange
        case .checking:
            return .secondary
        }
    }

    private func requirementSymbol(_ state: SetupRequirementState) -> String {
        switch state {
        case .satisfied: "checkmark.circle.fill"
        case .actionRequired: "exclamationmark.circle.fill"
        case .checking: "circle.dotted"
        }
    }
}

private func postAccessibilityAnnouncement(_ text: String) {
    guard !text.isEmpty else {
        return
    }
    AccessibilityNotification.Announcement(text).post()
}

private struct SurfacePanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }
}

private extension View {
    func surfacePanel() -> some View {
        modifier(SurfacePanel())
    }
}
