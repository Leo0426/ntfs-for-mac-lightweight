import NTFSLiteCore

public enum ReadOnlyDashboardSelection: Equatable, Hashable, Sendable {
    case overview
    case volume(VolumeInstanceID)
    case environment
    case diagnostics
}

public enum ReadOnlyDashboardDetail: Equatable, Sendable {
    case overview
    case volume(ReadOnlyVolumePresentation, ReadOnlyPhysicalDiskPresentation)
    case environment
    case diagnostics
}

public enum ReadOnlyNavigationLayout: Equatable, Sendable {
    case compact
    case wide
}

public enum ReadOnlyNavigationFocus: Equatable, Hashable, Sendable {
    case compactPicker
    case wide(ReadOnlyDashboardSelection)
}

public enum ReadOnlyNavigationFocusPresenter {
    public static func reconciledFocus(
        _ focus: ReadOnlyNavigationFocus?,
        from previousLayout: ReadOnlyNavigationLayout,
        to currentLayout: ReadOnlyNavigationLayout,
        previousPresentedSelection: ReadOnlyDashboardSelection,
        currentPresentedSelection: ReadOnlyDashboardSelection,
        in dashboard: ReadOnlyDashboardPresentation
    ) -> ReadOnlyNavigationFocus? {
        guard let focus else {
            return nil
        }

        if previousLayout != currentLayout {
            switch (focus, currentLayout) {
            case (.wide, .compact):
                return .compactPicker
            case (.compactPicker, .wide):
                return .wide(currentPresentedSelection)
            default:
                return focus
            }
        }

        guard case let .wide(focusedSelection) = focus else {
            return focus
        }
        if ReadOnlySelectionPresenter.presentedSelection(
            for: focusedSelection,
            in: dashboard
        ) != focusedSelection {
            return .wide(currentPresentedSelection)
        }

        guard
              focusedSelection == previousPresentedSelection,
              previousPresentedSelection != currentPresentedSelection,
              currentPresentedSelection == .overview
        else {
            return focus
        }
        return .wide(.overview)
    }
}

public enum ReadOnlySelectionPresenter {
    public static func presentedSelection(
        for retainedSelection: ReadOnlyDashboardSelection,
        in dashboard: ReadOnlyDashboardPresentation
    ) -> ReadOnlyDashboardSelection {
        guard case let .volume(selectedID) = retainedSelection,
              !dashboard.volumes.contains(where: { $0.id == selectedID })
        else {
            return retainedSelection
        }
        return .overview
    }

    public static func reconciledSelection(
        _ selection: ReadOnlyDashboardSelection,
        selectedIn selectionEpoch: ReadOnlySelectionResetEpoch,
        for dashboard: ReadOnlyDashboardPresentation,
        in currentEpoch: ReadOnlySelectionResetEpoch
    ) -> ReadOnlyDashboardSelection {
        guard selectionEpoch == currentEpoch else {
            return .overview
        }
        return reconciledSelection(selection, for: dashboard)
    }

    public static func reconciledSelection(
        _ selection: ReadOnlyDashboardSelection,
        for dashboard: ReadOnlyDashboardPresentation
    ) -> ReadOnlyDashboardSelection {
        guard case let .volume(selectedID) = selection,
              dashboard.phase != .scanning,
              !dashboard.volumes.contains(where: { $0.id == selectedID })
        else {
            return selection
        }
        return .overview
    }

    public static func detail(
        for selection: ReadOnlyDashboardSelection,
        in dashboard: ReadOnlyDashboardPresentation
    ) -> ReadOnlyDashboardDetail {
        switch selection {
        case .overview:
            return .overview
        case let .volume(id):
            guard let disk = dashboard.physicalDisks.first(where: { disk in
                disk.volumes.contains(where: { $0.id == id })
            }), let volume = disk.volumes.first(where: { $0.id == id }) else {
                return .overview
            }
            return .volume(volume, disk)
        case .environment:
            return .environment
        case .diagnostics:
            return .diagnostics
        }
    }
}

public enum ReadOnlySetupInteractionPresenter {
    public static func primaryAction(
        for setup: SetupPresentation,
        guideRequirementID: SetupRequirementID?
    ) -> SetupPresentationAction? {
        guard !setup.isBusy else {
            return nil
        }
        if let guideRequirementID,
           setup.requirements.contains(where: {
               $0.id == guideRequirementID && $0.state == .actionRequired
           }) {
            return .recheck
        }
        return setup.primaryAction
    }

    public static func completedRecheckStatus(
        for setup: SetupPresentation
    ) -> String {
        if setup.isReady {
            return "重新检查完成，运行环境已满足当前要求。"
        }
        let actionRequiredCount = setup.requirements.count {
            $0.state == .actionRequired
        }
        guard actionRequiredCount > 0 else {
            return "重新检查完成，但运行环境状态仍未确认。"
        }
        return "重新检查完成，仍有 \(actionRequiredCount) 项需要处理。"
    }

    public static func guideFeedback(
        requirementID: SetupRequirementID?
    ) -> ReadOnlyActionFeedback {
        ReadOnlyActionFeedback(
            requirementID == nil
                ? "当前没有可继续的设置步骤，请重新检查。"
                : "已展开首个待处理项目。"
        )
    }

    public static let recheckStartedFeedback = ReadOnlyActionFeedback(
        "正在重新检查运行环境。"
    )

    public static func completedRecheckFeedback(
        for setup: SetupPresentation
    ) -> ReadOnlyActionFeedback {
        ReadOnlyActionFeedback(completedRecheckStatus(for: setup))
    }
}

public struct ReadOnlyActionFeedback: Equatable, Sendable {
    public let visibleText: String
    public let accessibilityAnnouncement: String

    fileprivate init(_ text: String) {
        visibleText = text
        accessibilityAnnouncement = text
    }
}

public enum ReadOnlyDiagnosticInteractionPresenter {
    public static let copyActionTitle = "复制摘要"

    public static func clearActionTitle(isClearing: Bool) -> String {
        isClearing ? "正在清除" : "清除诊断"
    }

    public static func copyFeedback(
        didSucceed: Bool
    ) -> ReadOnlyActionFeedback {
        ReadOnlyActionFeedback(
            didSucceed
                ? "诊断摘要已复制。"
                : "未能复制诊断摘要，请稍后重试。"
        )
    }

    public static let clearStartedFeedback = ReadOnlyActionFeedback(
        "正在清除诊断记录。"
    )

    public static func clearFeedback(
        didSucceed: Bool
    ) -> ReadOnlyActionFeedback {
        ReadOnlyActionFeedback(
            didSucceed
                ? "诊断记录与本地存档已清除，运行标识已轮换。"
                : "诊断内存已重置，但本地旧存档未能确认清除。"
        )
    }
}

public struct ReadOnlyAccessibilityAnnouncementEvent: Equatable, Sendable {
    private let selection: ReadOnlyDashboardSelection
    public let text: String

    fileprivate init(
        selection: ReadOnlyDashboardSelection,
        text: String
    ) {
        self.selection = selection
        self.text = text
    }
}

public enum ReadOnlyAccessibilityPresenter {
    public static func selectionLabel(
        for selection: ReadOnlyDashboardSelection,
        in dashboard: ReadOnlyDashboardPresentation
    ) -> String {
        switch ReadOnlySelectionPresenter.detail(for: selection, in: dashboard) {
        case .overview:
            return "概览"
        case let .volume(volume, disk):
            return "\(disk.title)，\(volume.title)"
        case .environment:
            return "运行环境"
        case .diagnostics:
            return "诊断摘要"
        }
    }

    public static func announcementEvent(
        for selection: ReadOnlyDashboardSelection,
        in dashboard: ReadOnlyDashboardPresentation
    ) -> ReadOnlyAccessibilityAnnouncementEvent {
        ReadOnlyAccessibilityAnnouncementEvent(
            selection: selection,
            text: announcement(for: selection, in: dashboard)
        )
    }

    public static func announcement(
        for selection: ReadOnlyDashboardSelection,
        in dashboard: ReadOnlyDashboardPresentation
    ) -> String {
        switch ReadOnlySelectionPresenter.detail(for: selection, in: dashboard) {
        case .overview:
            return "\(dashboard.title)。\(dashboard.detail)"
        case let .volume(volume, disk):
            return "\(volume.title)，\(disk.title)。挂载状态：\(volume.accessText)。\(volume.detail)"
        case .environment:
            return "\(dashboard.setup.title)。\(dashboard.setup.detail)"
        case .diagnostics:
            return "诊断摘要。只展示经过约束的本地状态信息。"
        }
    }
}
