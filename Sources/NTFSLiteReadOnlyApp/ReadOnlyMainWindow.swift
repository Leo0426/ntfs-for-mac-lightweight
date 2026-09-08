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
            HStack(spacing: 16) {
                phaseNotice
                Spacer(minLength: 12)
                Button("重新读取") {
                    store.refresh()
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                phaseNotice
                Button("重新读取") {
                    store.refresh()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private var phaseNotice: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("只读观察阶段")
                .font(.headline)
            Text("当前版本不会挂载、卸载、推出或修改磁盘")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
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
            VStack(alignment: .leading, spacing: 14) {
                sidebarGroup(title: "概览") {
                    sidebarButton("概览", selection: .overview)
                }
                ForEach(store.dashboard.physicalDisks) { disk in
                    sidebarGroup(title: disk.title) {
                        ForEach(disk.volumes) { volume in
                            sidebarButton(volume.title, selection: .volume(volume.id))
                        }
                    }
                }
                sidebarGroup(title: "设置") {
                    sidebarButton("运行环境", selection: .environment)
                    sidebarButton("诊断摘要", selection: .diagnostics)
                }
            }
            .padding(10)
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
        selection target: ReadOnlyDashboardSelection
    ) -> some View {
        Button {
            retainedSelection = target
        } label: {
            Text(title)
                .fontWeight(presentedSelection == target ? .semibold : .regular)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
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
                    ReadOnlyOverview(dashboard: store.dashboard)
                case let .volume(volume, disk):
                    ReadOnlyVolumeDetail(volume: volume, physicalDisk: disk)
                case .environment:
                    ReadOnlySetupDetail(store: store, setup: store.dashboard.setup)
                case .diagnostics:
                    ReadOnlyDiagnosticsDetail(store: store)
                }
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("诊断摘要")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("只包含固定状态码、数量、版本和运行期数字别名；不包含用户名、完整路径、卷标、设备 UUID/BSD 名或驱动原名。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

            GroupBox("结构化内容") {
                ScrollView(.vertical) {
                    Text(store.diagnosticsText)
                        .font(.system(.caption, design: .monospaced))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(dashboard.title)
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                Text(dashboard.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            if dashboard.phase == .scanning {
                ProgressView("正在读取系统磁盘信息")
            }

            ForEach(dashboard.physicalDisks) { disk in
                GroupBox(disk.title) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(disk.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(disk.volumes) { volume in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(volume.title)
                                    .fontWeight(.semibold)
                                Text("挂载状态：\(volume.accessText)")
                                Text(volume.detail)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            GroupBox("当前功能边界") {
                Text("界面仅展示只读系统事实。写入、安全推出、自动安装和系统设置变更均未开放。")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ReadOnlyVolumeDetail: View {
    let volume: ReadOnlyVolumePresentation
    let physicalDisk: ReadOnlyPhysicalDiskPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(volume.title)
                .font(.largeTitle.bold())
                .lineLimit(2)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)

            GroupBox("设备摘要") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(physicalDisk.title)
                        .fontWeight(.semibold)
                    Text(physicalDisk.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }

            GroupBox("当前状态") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(volume.accessText)
                        .font(.title3.weight(.semibold))
                    Text(volume.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("可执行操作") {
                Text("当前没有磁盘变更操作。后续只有在真实磁盘、安全后端和权限边界全部通过验证后才会逐步开放。")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ReadOnlySetupDetail: View {
    @ObservedObject var store: ReadOnlyAppStore
    let setup: SetupPresentation
    @State private var guideRequirementID: SetupRequirementID?
    @State private var actionFeedback: ReadOnlyActionFeedback?
    @State private var isAwaitingRecheckResult = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(setup.title)
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(setup.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if setup.isBusy {
                ProgressView("正在检查运行环境")
            }

            VStack(spacing: 0) {
                ForEach(Array(setup.requirements.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: 14) {
                        Text(row.statusText)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(statusColor(row.state))
                            .frame(width: 58, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title)
                                .fontWeight(.semibold)
                            Text(row.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 10)

                    if index < setup.requirements.count - 1 {
                        Divider()
                    }
                }
            }

            if let guideRequirement {
                GroupBox("下一步") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(guideRequirement.title)
                            .fontWeight(.semibold)
                        Text(guideRequirement.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("完成手动步骤后使用“重新检查”。应用不会代替你修改系统设置。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                Text("本页只检查并展示状态，不会下载依赖、请求提权、启用扩展或修改系统设置。")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: setup) { _, currentSetup in
            guard isAwaitingRecheckResult, !currentSetup.isBusy else {
                return
            }
            guideRequirementID = nil
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

    private var guideRequirement: SetupRequirementPresentation? {
        if let guideRequirementID {
            return setup.requirements.first {
                $0.id == guideRequirementID && $0.state == .actionRequired
            }
        }
        return nil
    }

    private func perform(_ action: SetupPresentationAction) {
        switch action {
        case .continueSetup:
            guideRequirementID = setup.requirements.first {
                $0.state == .actionRequired
            }?.id
            report(
                ReadOnlySetupInteractionPresenter.guideFeedback(
                    requirementID: guideRequirementID
                )
            )
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

    private func statusColor(_ state: SetupRequirementState) -> Color {
        switch state {
        case .satisfied:
            return .secondary
        case .actionRequired:
            return .orange
        case .checking:
            return .secondary
        }
    }
}

private func postAccessibilityAnnouncement(_ text: String) {
    guard !text.isEmpty else {
        return
    }
    AccessibilityNotification.Announcement(text).post()
}
