import AppKit
import NTFSLitePresentation
import SwiftUI

struct ScenarioWindow: View {
    @Binding var scenarioID: ScenarioID
    @State private var selection: ScenarioSelection = .environment
    @State private var lastIntent = "尚未触发任何模拟操作。"

    private var fixture: ScenarioFixture {
        scenarioID.fixture
    }

    var body: some View {
        VStack(spacing: 0) {
            PrototypeHeader(scenarioID: $scenarioID, headline: fixture.headline)
            Divider()
            GeometryReader { geometry in
                if geometry.size.width < 560 {
                    compactContent
                } else {
                    wideContent
                }
            }
        }
        .frame(minWidth: 320, minHeight: 460)
        .onChange(of: scenarioID) { _, newValue in
            selection = newValue.fixture.initialSelection
            lastIntent = "已切换模拟场景；尚未触发任何操作。"
            AccessibilityAnnouncement.post(
                "模拟场景已切换。\(newValue.title)。\(newValue.fixture.headline)"
            )
        }
    }

    private var wideContent: some View {
        HStack(spacing: 0) {
            ScenarioSidebar(
                groups: fixture.sidebarGroups,
                fixture: fixture,
                selection: $selection
            )
            .frame(width: 220)

            Divider()

            detail
        }
    }

    private var compactContent: some View {
        VStack(spacing: 0) {
            Picker("当前项目", selection: $selection) {
                ForEach(fixture.sidebarEntries, id: \.self) { entry in
                    Text("\(entry.category(in: fixture)) · \(entry.title(in: fixture))")
                        .tag(entry)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()
            detail
        }
    }

    private var detail: some View {
        ScenarioDetail(
            selection: selection,
            fixture: fixture,
            lastIntent: lastIntent,
            onIntent: {
                lastIntent = $0
                AccessibilityAnnouncement.post($0)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PrototypeHeader: View {
    @Binding var scenarioID: ScenarioID
    let headline: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                prototypeNotice
                Spacer(minLength: 12)
                scenarioPicker
            }
            VStack(alignment: .leading, spacing: 8) {
                prototypeNotice
                scenarioPicker
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private var prototypeNotice: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("一次性原型 · 仅模拟数据")
                .font(.headline)
            Text(headline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var scenarioPicker: some View {
        Picker("演示场景", selection: $scenarioID) {
            ForEach(ScenarioID.allCases) { scenario in
                Text(scenario.title).tag(scenario)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 260)
    }
}

private struct ScenarioSidebar: View {
    let groups: [ScenarioSidebarGroup]
    let fixture: ScenarioFixture
    @Binding var selection: ScenarioSelection

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .accessibilityAddTraits(.isHeader)

                        ForEach(group.entries, id: \.self) { entry in
                            Button {
                                selection = entry
                            } label: {
                            Text(entry.title(in: fixture))
                                .fontWeight(selection == entry ? .semibold : .regular)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(
                                selection == entry
                                    ? Color.accentColor.opacity(0.14)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .accessibilityValue(selection == entry ? "已选中" : "未选中")
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct ScenarioDetail: View {
    let selection: ScenarioSelection
    let fixture: ScenarioFixture
    let lastIntent: String
    let onIntent: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch selection {
                case .noDisk:
                    EmptyDiskDetail()
                case let .volume(id):
                    if let volume = fixture.volumes.first(where: { $0.id == id }) {
                        VolumeDetail(volume: volume, onIntent: onIntent)
                    } else {
                        EmptyDiskDetail()
                    }
                case .environment:
                    SetupDetail(presentation: fixture.setup, onIntent: onIntent)
                case .diagnostics:
                    DiagnosticsDetail(lines: fixture.diagnosticLines, onIntent: onIntent)
                }

                GroupBox("原型交互状态") {
                    Text(lastIntent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("原型交互状态：\(lastIntent)")
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct EmptyDiskDetail: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("没有检测到 NTFS 磁盘")
                .font(.largeTitle.bold())
            Text("连接外置 NTFS 磁盘后会自动显示。原型不会读取当前 Mac 的真实磁盘。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("当前没有可执行操作。")
                .font(.headline)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SetupDetail: View {
    let presentation: SetupPresentation
    let onIntent: (String) -> Void
    @State private var guideRequirementID: SetupRequirementID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(presentation.title)
                    .font(.largeTitle.bold())
                Text(presentation.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if presentation.isBusy {
                ProgressView("正在检查；写入保持关闭")
                    .accessibilityLabel("正在检查运行环境。完成前写入保持关闭。")
            }

            VStack(spacing: 0) {
                ForEach(Array(presentation.requirements.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 14) {
                        Text(row.statusText)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(statusColor(row.state))
                            .frame(width: 58, alignment: .leading)
                            .accessibilityLabel("状态：\(row.statusText)")
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

                    if row.id != presentation.requirements.last?.id {
                        Divider()
                    }
                }
            }

            if let guideRequirement {
                GroupBox("处理说明") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(guideRequirement.title)
                            .font(.headline)
                        Text(guideRequirement.detail)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("完成手动步骤后再选择“重新检查”。原型不会打开网页、下载安装或修改系统设置。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "处理说明。\(guideRequirement.title)。\(guideRequirement.detail)"
                )
            }

            setupActions
        }
        .onChange(of: presentation) { _, _ in
            guideRequirementID = nil
        }
    }

    private var guideRequirement: SetupRequirementPresentation? {
        guard let guideRequirementID else {
            return nil
        }
        return presentation.requirements.first { $0.id == guideRequirementID }
    }

    @ViewBuilder
    private var setupActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let primaryAction = visiblePrimaryAction {
                Button(primaryAction.title) {
                    perform(primaryAction)
                }
                .buttonStyle(.borderedProminent)
                .disabled(presentation.isBusy)
                .accessibilityLabel("模拟操作：\(primaryAction.title)")
            }

            ForEach(Array(presentation.secondaryActions.enumerated()), id: \.offset) { _, action in
                Button(action.title) {
                    perform(action)
                }
                .buttonStyle(.bordered)
                .disabled(presentation.isBusy)
                .accessibilityLabel("模拟操作：\(action.title)")
            }
        }
    }

    private var visiblePrimaryAction: SetupPresentationAction? {
        guideRequirement == nil ? presentation.primaryAction : .recheck
    }

    private func perform(_ action: SetupPresentationAction) {
        switch action {
        case .continueSetup:
            guard let requirement = presentation.requirements.first(where: {
                $0.state == .actionRequired
            }) else {
                onIntent("模拟导航：没有找到待处理项。没有执行真实系统动作。")
                return
            }
            guideRequirementID = requirement.id
            onIntent(
                "模拟导航：已在当前窗口打开“\(requirement.title)”处理说明。没有执行真实系统动作。"
            )
        case .recheck:
            guideRequirementID = nil
            onIntent("模拟操作：重新检查。没有读取真实系统或磁盘状态。")
        case .copyDiagnostics:
            onIntent("模拟操作：复制诊断摘要。未写入系统剪贴板。")
        }
    }

    private func statusColor(_ state: SetupRequirementState) -> Color {
        switch state {
        case .satisfied:
            .primary
        case .actionRequired:
            .orange
        case .checking:
            .secondary
        }
    }
}

private struct VolumeDetail: View {
    let volume: ScenarioVolume
    let onIntent: (String) -> Void

    private var presentation: VolumePresentation {
        volume.presentation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(volume.displayName)
                    .font(.largeTitle.bold())
                Text(volume.deviceSummary)
                    .foregroundStyle(.secondary)
                Text(volume.physicalDiskSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox("当前状态") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(presentation.title)
                        .font(.title2.bold())
                    Text(presentation.detail)
                        .fixedSize(horizontal: false, vertical: true)
                    if presentation.isBusy {
                        Text("状态：处理中")
                            .font(.callout.weight(.semibold))
                        ProgressView("操作处理中")
                            .accessibilityLabel(
                                "\(presentation.title)。\(presentation.detail)"
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ActionButtons(
                primaryTitle: presentation.primaryAction.map(prototypeTitle),
                secondaryTitles: presentation.secondaryActions.map(prototypeTitle),
                isBusy: presentation.isBusy,
                onIntent: onIntent
            )

            if presentation.primaryAction == nil && presentation.secondaryActions.isEmpty {
                Text("当前没有可执行操作。")
                    .font(.headline)
            }
        }
    }

    private func prototypeTitle(_ action: PresentationAction) -> String {
        switch action {
        case .enableWriting:
            "启用写入"
        case .openInFinder:
            "在访达中打开"
        case .safeEject:
            "安全推出整块磁盘"
        case .viewResolution:
            "查看处理方法"
        case .retryEject:
            "重新安全推出"
        case .copyDiagnostics:
            "复制诊断摘要"
        case .finish:
            "完成"
        }
    }
}

private struct DiagnosticsDetail: View {
    let lines: [String]
    let onIntent: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("诊断摘要")
                    .font(.largeTitle.bold())
                Text("以下内容全部来自模拟 fixture，并已按产品规则脱敏。")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("模拟复制诊断摘要") {
                onIntent("模拟操作：复制诊断摘要。未写入系统剪贴板。")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct ActionButtons: View {
    let primaryTitle: String?
    let secondaryTitles: [String]
    let isBusy: Bool
    let onIntent: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let primaryTitle {
                Button(primaryTitle) {
                    onIntent("模拟操作：\(primaryTitle)。没有执行真实系统动作。")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
                .accessibilityLabel("模拟操作：\(primaryTitle)")
            }

            if !secondaryTitles.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Array(secondaryTitles.enumerated()), id: \.offset) { _, title in
                            secondaryButton(title)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(secondaryTitles.enumerated()), id: \.offset) { _, title in
                            secondaryButton(title)
                        }
                    }
                }
            }
        }
    }

    private func secondaryButton(_ title: String) -> some View {
        Button(title) {
            onIntent("模拟操作：\(title)。没有执行真实系统动作。")
        }
        .buttonStyle(.bordered)
        .disabled(isBusy)
        .accessibilityLabel("模拟操作：\(title)")
    }
}

@MainActor
private enum AccessibilityAnnouncement {
    static func post(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
