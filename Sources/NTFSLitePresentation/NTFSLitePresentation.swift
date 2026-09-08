import NTFSLiteCore

public enum PresentationAction: Equatable, Sendable {
    case enableWriting
    case openInFinder
    case safeEject
    case viewResolution
    case retryEject
    case copyDiagnostics
    case finish
}

public struct VolumePresentation: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let primaryAction: PresentationAction?
    public let secondaryActions: [PresentationAction]
    public let isBusy: Bool

    public var actionsEnabled: Bool {
        !isBusy
    }

    public init(
        title: String,
        detail: String,
        primaryAction: PresentationAction?,
        secondaryActions: [PresentationAction],
        isBusy: Bool
    ) {
        self.title = title
        self.detail = detail
        self.primaryAction = primaryAction
        self.secondaryActions = secondaryActions
        self.isBusy = isBusy
    }
}

public enum VolumePresenter {
    public static func presentation(
        for status: VolumeStatusSnapshot
    ) -> VolumePresentation {
        let base = presentation(for: status.state)
        let ejectAware = applyingSafeEjectAvailability(
            status.safeEjectAvailability,
            to: base
        )
        guard status.isPhysicalDiskBusy else {
            return ejectAware
        }
        return VolumePresentation(
            title: "同盘操作进行中",
            detail: "同一物理盘的另一分区正在执行变更。请勿读写或断开磁盘，等待操作结束。",
            primaryAction: nil,
            secondaryActions: [],
            isBusy: true
        )
    }

    private static func presentation(for state: VolumeState) -> VolumePresentation {
        switch state {
        case .readOnlyReady:
            return VolumePresentation(
                title: "当前只读",
                detail: "磁盘健康，可以手动启用写入。",
                primaryAction: .enableWriting,
                secondaryActions: [.openInFinder, .safeEject],
                isBusy: false
            )
        case .unmountedReady:
            return VolumePresentation(
                title: "当前未挂载",
                detail: "磁盘已识别，可以重新检查后手动启用写入。",
                primaryAction: .enableWriting,
                secondaryActions: [.safeEject],
                isBusy: false
            )
        case let .existingWriteMountUnverified(writeBlockReason):
            let detail: String
            if let writeBlockReason {
                detail = "发现未由本应用验证的可写挂载，同时存在风险：\(writeBlockDetail(for: writeBlockReason))"
            } else {
                detail = "发现已有可写挂载，但尚未确认后端、磁盘身份和挂载点。"
            }
            return VolumePresentation(
                title: "发现未验证的可写挂载",
                detail: detail,
                primaryAction: .viewResolution,
                secondaryActions: recoveryActions(for: writeBlockReason),
                isBusy: false
            )
        case .unmountingForWrite:
            return busy(
                title: "正在准备写入",
                detail: "正在标准卸载系统只读卷。"
            )
        case .awaitingSafetySnapshot:
            return busy(
                title: "正在重新检查",
                detail: "正在确认磁盘身份、健康状态和卸载结果。"
            )
        case .mountingWrite:
            return busy(
                title: "正在启用写入",
                detail: "正在通过 FSKit 安全后端挂载。"
            )
        case .awaitingWriteVerification:
            return busy(
                title: "正在验证写入",
                detail: "正在读取系统中的实际挂载状态。"
            )
        case .writable:
            return VolumePresentation(
                title: "已验证可写",
                detail: "可以在访达中修改文件，完成后请安全推出。",
                primaryAction: .openInFinder,
                secondaryActions: [.safeEject],
                isBusy: false
            )
        case let .writeVerificationFailed(failure):
            return VolumePresentation(
                title: "未能确认可写",
                detail: writeVerificationDetail(for: failure),
                primaryAction: .viewResolution,
                secondaryActions: [.safeEject, .copyDiagnostics],
                isBusy: false
            )
        case .unmountingForEject:
            return busy(
                title: "正在同步并卸载",
                detail: "正在标准卸载这块物理盘的所有分区。"
            )
        case .awaitingUnmountVerification:
            return busy(
                title: "正在检查所有分区",
                detail: "正在确认没有同盘分区仍在使用。"
            )
        case .ejecting:
            return busy(
                title: "正在推出磁盘",
                detail: "请保持磁盘连接。"
            )
        case .awaitingRemovalVerification:
            return busy(
                title: "正在确认推出结果",
                detail: "正在读取系统中的实际磁盘状态。"
            )
        case .safeToRemove:
            return VolumePresentation(
                title: "已验证可以拔出",
                detail: "系统已确认磁盘推出，现在可以断开连接。",
                primaryAction: .finish,
                secondaryActions: [],
                isBusy: false
            )
        case let .ejectFailed(failure):
            return VolumePresentation(
                title: "未能安全推出",
                detail: ejectFailureDetail(for: failure),
                primaryAction: .retryEject,
                secondaryActions: [.copyDiagnostics],
                isBusy: false
            )
        case let .ejectBlocked(reason):
            return VolumePresentation(
                title: "安全推出已阻止",
                detail: ejectBlockDetail(for: reason),
                primaryAction: .viewResolution,
                secondaryActions: [.copyDiagnostics],
                isBusy: false
            )
        case let .writeBlocked(reason):
            return VolumePresentation(
                title: "写入已阻止",
                detail: writeBlockDetail(for: reason),
                primaryAction: .viewResolution,
                secondaryActions: recoveryActions(for: reason),
                isBusy: false
            )
        case .mediaInvalidated:
            return VolumePresentation(
                title: "磁盘已变化",
                detail: "之前的操作证据已经失效，请等待重新检测磁盘。",
                primaryAction: nil,
                secondaryActions: [.copyDiagnostics],
                isBusy: false
            )
        case .mediaUnavailable:
            return VolumePresentation(
                title: "磁盘已断开",
                detail: "之前的读写状态已经撤销，重新连接后会从系统重新检测。",
                primaryAction: .finish,
                secondaryActions: [],
                isBusy: false
            )
        case let .writeOperationFailed(stage, failure):
            return VolumePresentation(
                title: "未能启用写入",
                detail: writeOperationFailureDetail(stage: stage, failure: failure),
                primaryAction: .viewResolution,
                secondaryActions: [.safeEject, .copyDiagnostics],
                isBusy: false
            )
        case let .writeMutationQuiescencePending(stage, failure):
            return busy(
                title: "正在等待操作停止",
                detail: "系统操作结果暂不确定。已锁定这块物理盘，正在等待进程真正结束：\(writeOperationFailureDetail(stage: stage, failure: failure))"
            )
        case let .awaitingWriteMutationReconciliation(stage, failure):
            return busy(
                title: "正在核对磁盘状态",
                detail: "操作进程已经结束，正在重新读取磁盘事实后再解除锁定：\(writeOperationFailureDetail(stage: stage, failure: failure))"
            )
        case let .ejectMutationQuiescencePending(stage, failure):
            return busy(
                title: "正在等待推出操作停止",
                detail: "系统操作结果暂不确定。整块物理盘保持锁定，直到进程真正结束：\(ejectMutationFailureDetail(stage: stage, failure: failure))"
            )
        case let .awaitingEjectMutationReconciliation(stage, failure):
            return busy(
                title: "正在核对整块物理盘",
                detail: "操作进程已经结束，正在读取所有分区和物理盘状态：\(ejectMutationFailureDetail(stage: stage, failure: failure))"
            )
        }
    }

    private static func applyingSafeEjectAvailability(
        _ availability: SafeEjectAvailability,
        to presentation: VolumePresentation
    ) -> VolumePresentation {
        guard availability != .available else {
            return presentation
        }
        let hasEjectAction = presentation.primaryAction == .safeEject
            || presentation.primaryAction == .retryEject
            || presentation.secondaryActions.contains(.safeEject)
        guard hasEjectAction else {
            return presentation
        }

        let availabilityDetail: String
        switch availability {
        case .available:
            return presentation
        case let .blocked(reason):
            availabilityDetail = ejectBlockDetail(for: reason)
        case .temporarilyUnavailable:
            availabilityDetail = "正在重新核对整块物理盘的范围，暂不提供安全推出。"
        }
        let primaryAction: PresentationAction?
        if presentation.primaryAction == .safeEject
            || presentation.primaryAction == .retryEject
        {
            primaryAction = .viewResolution
        } else {
            primaryAction = presentation.primaryAction
        }
        return VolumePresentation(
            title: presentation.title,
            detail: "\(presentation.detail) \(availabilityDetail)",
            primaryAction: primaryAction,
            secondaryActions: presentation.secondaryActions.filter { $0 != .safeEject },
            isBusy: presentation.isBusy
        )
    }

    private static func busy(title: String, detail: String) -> VolumePresentation {
        VolumePresentation(
            title: title,
            detail: detail,
            primaryAction: nil,
            secondaryActions: [],
            isBusy: true
        )
    }

    private static func writeBlockDetail(for reason: WriteBlockReason) -> String {
        switch reason {
        case .windowsHibernated:
            return "Windows 仍处于休眠或快速启动状态，请回 Windows 完整关机。"
        case .dirtyFileSystem:
            return "磁盘未干净卸载，请先在 Windows 中运行完整文件系统检查。"
        case .healthUnknown:
            return "无法取得足够的安全证据，因此保持只读。"
        case .internalVolume:
            return "个人轻量版不对内部 NTFS 卷启用写入。"
        case .bootCampVolume:
            return "个人轻量版不对 Boot Camp 系统卷启用写入。"
        case .protectedVolume:
            return "该卷具有受保护角色，个人轻量版不会对其启用写入。"
        case .unsupportedFileSystem:
            return "当前卷不是受支持的 NTFS 数据卷。"
        }
    }

    private static func recoveryActions(
        for reason: WriteBlockReason?
    ) -> [PresentationAction] {
        switch reason {
        case .internalVolume?, .bootCampVolume?, .protectedVolume?:
            return [.copyDiagnostics]
        default:
            return [.safeEject, .copyDiagnostics]
        }
    }

    private static func writeVerificationDetail(for failure: MountVerificationFailure) -> String {
        switch failure {
        case .wrongVolume:
            return "系统返回了另一卷的挂载结果，未确认本卷可写。"
        case .observationIncomplete:
            return "没有取得完整的系统挂载信息，未确认本卷可写。"
        case .sourceDeviceMismatch:
            return "挂载点对应的来源设备不是目标卷。"
        case .notReadWrite:
            return "实际挂载仍为只读。"
        case .unexpectedBackend:
            return "实际挂载未使用预期的 FSKit 安全后端。"
        case .invalidMountPoint:
            return "实际挂载点不在有效的 /Volumes 位置。"
        case .untrustedMountPath:
            return "挂载点不是可信的规范路径，或经过了符号链接。"
        }
    }

    private static func ejectFailureDetail(for failure: EjectFailure) -> String {
        switch failure {
        case .busy:
            return "磁盘仍被使用。关闭正在访问它的访达窗口或应用后重试。"
        case let .volumesStillMounted(volumeIDs):
            return "同一物理盘仍有 \(volumeIDs.count) 个分区处于挂载状态。"
        case .diskStillPresent:
            return "系统仍能看到这块磁盘，因此还不能拔出。"
        case .observationIncomplete:
            return "没有取得完整的磁盘状态，已停止推出流程。"
        case .timedOut:
            return "等待系统推出操作超时；完整重新检查后确认磁盘仍在。"
        case .cancelled:
            return "推出操作已取消；完整重新检查后确认磁盘仍在。"
        }
    }

    private static func ejectBlockDetail(for reason: EjectBlockReason) -> String {
        switch reason {
        case .internalDisk:
            return "个人轻量版不会推出内部物理磁盘。"
        case .bootCampDisk:
            return "个人轻量版不会推出包含 Boot Camp 的物理磁盘。"
        case .protectedDisk:
            return "该卷具有受保护角色，个人轻量版不会推出其物理磁盘。"
        case .protectedSibling:
            return "同一物理盘包含内部或 Boot Camp 分区，已停止整盘推出。"
        case .notEjectable:
            return "系统事实表明此物理磁盘不能由软件推出。"
        }
    }

    private static func writeOperationFailureDetail(
        stage: WriteOperationStage,
        failure: WriteOperationFailure
    ) -> String {
        let stageText: String
        switch stage {
        case .unmountingReadOnly:
            stageText = "卸载只读卷"
        case .inspectingSafety:
            stageText = "重新检查磁盘"
        case .mountingWrite:
            stageText = "启用写入"
        case .inspectingWriteMount:
            stageText = "验证实际挂载"
        }
        let failureText: String
        switch failure {
        case .busy:
            failureText = "磁盘仍被使用"
        case .permissionDenied:
            failureText = "权限不足"
        case .dependencyUnavailable:
            failureText = "所需组件不可用"
        case .engineFailed:
            failureText = "挂载引擎失败"
        case .inspectionUnavailable:
            failureText = "无法取得完整系统状态"
        case .timedOut:
            failureText = "等待系统响应超时"
        case .cancelled:
            failureText = "操作已取消"
        }
        return "在\(stageText)阶段停止：\(failureText)。磁盘不会被强制修改。"
    }

    private static func ejectMutationFailureDetail(
        stage: EjectMutationStage,
        failure: EjectFailure
    ) -> String {
        let stageText: String
        switch stage {
        case .unmountingPhysicalDisk:
            stageText = "卸载整块物理盘"
        case .ejectingPhysicalDisk:
            stageText = "推出整块物理盘"
        }
        let failureText: String
        switch failure {
        case .timedOut:
            failureText = "等待系统响应超时"
        case .cancelled:
            failureText = "操作已取消"
        default:
            failureText = "结果暂不确定"
        }
        return "在\(stageText)阶段出现：\(failureText)。"
    }
}
