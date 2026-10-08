import Foundation

public enum DiagnosticSummarySource: Sendable {
    case currentRun
    case previousRun
}

/// A display/export projection only. The archive continues to use canonical JSON.
enum DiagnosticSummaryFormatter {
    static func text(
        for snapshot: DiagnosticSnapshot,
        source: DiagnosticSummarySource,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"

        var setup: DiagnosticSetupEvent?
        var inventory: DiagnosticInventoryEvent?
        for entry in snapshot.entries {
            switch entry.event {
            case let .setup(event): setup = event
            case let .inventory(event): inventory = event
            case .volume, .operation: break
            }
        }
        let recentEntries = snapshot.entries.suffix(10).reversed()
        let sourceText = switch source {
        case .currentRun: "本次运行"
        case .previousRun: "上次运行（历史记录）"
        }
        let scopeNote = switch source {
        case .currentRun: "以下是已记录的检查结果；当前状态请以主窗口重新读取为准。"
        case .previousRun: "这是上次运行的历史记录，不代表当前状态。请重新读取。"
        }
        let overview = [
            "运行环境：\(setup.map(setupStatus) ?? "尚未记录")",
            "磁盘识别：\(inventory.map(inventoryStatus) ?? "尚未记录")",
            scopeNote,
            "此摘要不能判断磁盘是否可写或可以拔出；请查看卷详情中的实时核验结果。",
        ]
        var guidance = setup?.issueCodes.map(\.guidance) ?? []
        if setup == nil || inventory == nil {
            guidance.append("部分检查尚未记录，请在主窗口点击“重新读取”，等待检查完成。")
        }
        if let setup, setup.issueCodes.isEmpty, !setupFactsAreConfirmed(setup) {
            guidance.append("部分运行环境事实尚未确认，请重新读取并查看“运行环境”中的检查说明。")
        }
        if let inventory, !inventory.isComplete || !inventory.issueCodes.isEmpty {
            guidance.append("磁盘信息尚未完整确认，请点击“重新读取”；若仍未确认，查看下方具体原因。")
            if inventory.issueCodes.contains(.unknownVolumeRole) {
                guidance.append("卷用途需由你确认；只有确定它是普通数据卷且不是 Windows 系统卷时，才在卷详情中声明用途。")
            }
        }
        if guidance.isEmpty {
            guidance.append("已记录的检查未报告问题；需要操作磁盘时，请在卷详情中查看当前资格。")
        }
        let environment: [String]
        if let setup {
            environment = [
                "检查结果：\(setupStatus(setup))",
                "应用版本：\(version(setup.applicationVersion))（构建 \(setup.applicationBuild)）",
                "macOS：\(version(setup.macOSVersion))",
                "处理器：\(setup.architecture.label)",
                "macFUSE：\(setup.macFUSEVersion.map(version) ?? "未确认版本")",
                "NTFS-3G：\(setup.ntfs3GVersion.map(version) ?? "未确认版本")",
                "文件系统扩展：\(setup.fileSystemExtensionEnabled ? "已观察到启用" : "未确认启用")",
                "挂载后端：\(setup.selectedBackend.label)",
                "驱动冲突：已观察到 \(setup.conflictingDriverCount) 个已知冲突驱动（只覆盖已检查范围）",
            ] + setup.issueCodes.map { "• \($0.explanation)" }
        } else {
            environment = ["尚未记录运行环境检查，无法判断是否满足要求。"]
        }
        let disks: [String]
        if let inventory {
            disks = [
                "检查结果：\(inventoryStatus(inventory))",
                "已观察到：\(inventory.physicalDiskCount) 块物理盘，\(inventory.volumeCount) 个卷",
                "统计包含本机磁盘与其他文件系统，不是外置 NTFS 目标数量。",
            ] + inventory.issueCodes.map { "• \($0.explanation)" }
        } else {
            disks = ["尚未记录磁盘识别结果，不能据此判断是否连接了磁盘。"]
        }
        let history = recentEntries.map {
            "• \(timestamp($0.occurredAt, formatter: formatter))｜\(eventText($0.event))"
        }
        return [
            "NTFS 轻量助手 · 诊断摘要\n记录来源：\(sourceText)\n生成时间：\(timestamp(snapshot.generatedAt, formatter: formatter))\n保留记录：\(snapshot.entries.count) 条",
            section("状态概览", overview),
            section("处理建议", guidance.map { "• \($0)" }),
            section("运行环境", environment),
            section("磁盘识别", disks),
            section("最近记录（显示 \(recentEntries.count) / \(snapshot.entries.count) 条，最新在前）",
                    history.isEmpty ? ["暂无诊断记录。"] : history),
            section("隐私说明", ["内容已脱敏，不包含用户名、完整路径、卷标、设备 UUID、BSD 名或命令输出。磁盘与卷仅使用本次记录内的数字别名。"]),
        ].joined(separator: "\n\n")
    }

    private static func section(_ title: String, _ lines: [String]) -> String {
        "【\(title)】\n" + lines.joined(separator: "\n")
    }

    private static func version(_ version: DiagnosticVersion) -> String {
        "\(version.major).\(version.minor).\(version.patch)"
    }

    private static func timestamp(_ value: DiagnosticTimestamp, formatter: DateFormatter) -> String {
        let text = formatter.string(from: Date(timeIntervalSince1970: Double(value.millisecondsSince1970) / 1_000))
        return text.isEmpty ? "时间无法显示" : text
    }

    private static func setupStatus(_ event: DiagnosticSetupEvent) -> String {
        if !event.issueCodes.isEmpty { return "需要处理（\(event.issueCodes.count) 项）" }
        guard setupFactsAreConfirmed(event) else { return "部分事实未确认" }
        return "已记录的检查未报告问题"
    }

    private static func setupFactsAreConfirmed(_ event: DiagnosticSetupEvent) -> Bool {
        event.architecture != .unknown && event.macFUSEVersion != nil
            && event.ntfs3GVersion != nil && event.fileSystemExtensionEnabled
            && event.selectedBackend == .fsKit && event.conflictingDriverCount == 0
    }

    private static func inventoryStatus(_ event: DiagnosticInventoryEvent) -> String {
        event.isComplete && event.issueCodes.isEmpty ? "本次记录完整" : "信息不完整"
    }

    private static func target(_ target: DiagnosticTarget) -> String {
        if let ordinal = target.volumeOrdinal {
            return "磁盘 \(target.diskOrdinal) / 卷 \(ordinal)（连接编号 \(target.mediaGeneration)）"
        }
        return "磁盘 \(target.diskOrdinal)（连接编号 \(target.mediaGeneration)）"
    }

    private static func eventText(_ event: DiagnosticInput) -> String {
        switch event {
        case let .setup(event):
            return "环境检查：\(setupStatus(event))" + details(event.issueCodes.map(\.explanation))
        case let .inventory(event):
            return "磁盘识别：\(inventoryStatus(event))；\(event.physicalDiskCount) 块物理盘，\(event.volumeCount) 个卷"
                + details(event.issueCodes.map(\.explanation))
        case let .volume(event):
            return "\(target(event.target))：\(event.state.label)"
                + details([
                    "\(event.fileSystem.label)，\(event.location.label)，\(event.role.label)",
                    "健康状态：\(event.health.label)",
                    "访问方式：\(event.mountAccess.label)",
                    "后端：\(event.backend.label)",
                    "系统信息：\(event.observationComplete ? "完整" : "不完整")",
                    "挂载位置：\(event.isCanonicalMountPoint ? "规范" : "未确认规范")",
                    "符号链接：\(event.isSymbolicLinkMountPoint ? "是" : "否")",
                ] + (event.reason.map { ["原因：\($0.label)"] } ?? []))
        case let .operation(event):
            var fields = ["结果：\(event.result.label)", "耗时：\(event.elapsedMilliseconds) 毫秒"]
            if let status = event.exitStatus {
                let code = status.code.map { "（\($0)）" } ?? ""
                fields.append("进程：\(status.kind.label)\(code)")
            }
            if event.result == .succeeded {
                fields.append("阶段完成不代表已确认可写或可以拔出")
            }
            return "\(target(event.target)) · \(event.kind.label) · \(event.stage.label)" + details(fields)
        }
    }

    private static func details(_ values: [String]) -> String {
        values.isEmpty ? "" : "；" + values.joined(separator: "；")
    }
}

private extension DiagnosticSetupIssueCode {
    var explanation: String {
        switch self {
        case .unsupportedOperatingSystem: "macOS 版本不满足当前要求"
        case .unsupportedArchitecture: "处理器架构不支持或尚未确认"
        case .macFUSEMissing: "未确认 macFUSE 可用"
        case .macFUSETooOld: "macFUSE 版本低于当前要求"
        case .fileSystemExtensionDisabled: "未确认文件系统扩展已启用"
        case .ntfs3GMissing: "未确认 NTFS-3G 可用"
        case .ntfs3GTooOld: "NTFS-3G 版本低于当前要求"
        case .unsafeBackend: "挂载后端不是已确认的 FSKit"
        case .requiredAuthorizationUnavailable: "必要授权不可用或尚未确认"
        case .conflictScanIncomplete: "冲突扫描未完成，无法确认无冲突"
        case .conflictingDrivers: "发现其他 NTFS 写入驱动"
        }
    }

    var guidance: String {
        switch self {
        case .unsupportedOperatingSystem: "macOS 版本不满足要求，请查看“运行环境”中的系统兼容说明。"
        case .unsupportedArchitecture: "处理器架构未满足要求，请查看“运行环境”中的系统兼容说明。"
        case .macFUSEMissing, .macFUSETooOld: "macFUSE 尚未满足要求，请按“运行环境”中的写入组件说明处理后重新读取。"
        case .fileSystemExtensionDisabled: "文件系统扩展尚未确认启用，请按“运行环境”中的 FSKit 支持说明检查。"
        case .ntfs3GMissing, .ntfs3GTooOld: "应用内 NTFS-3G 尚未满足要求，请查看“运行环境”中的写入组件说明。"
        case .unsafeBackend: "挂载后端尚未确认是 FSKit，请查看“运行环境”中的后端检查。"
        case .requiredAuthorizationUnavailable: "必要授权尚未确认，请查看“运行环境”中的授权说明。"
        case .conflictScanIncomplete: "冲突扫描未完成，请重新读取；当前不能确认没有冲突驱动。"
        case .conflictingDrivers: "发现其他 NTFS 写入驱动，请停用冲突驱动后重新读取。"
        }
    }
}

private extension DiagnosticInventoryIssueCode {
    var explanation: String {
        switch self {
        case .initialEnumerationPending: "系统仍在读取磁盘清单"
        case .enumerationCoverageUnverified: "磁盘清单尚未完成独立核对"
        case .eventSourceUnavailable: "系统磁盘事件源不可用"
        case .unidentifiedDiskEvent: "收到无法识别身份的磁盘事件"
        case .mountTableReadFailed: "系统挂载信息读取失败"
        case .missingPhysicalDiskDescription: "整块物理盘的信息缺失"
        case .unknownDiskKind: "物理盘类型未确认"
        case .physicalParentMismatch: "卷与所属物理盘的关系不一致"
        case .missingPhysicalLocation: "物理盘的内置或外置位置未确认"
        case .missingEjectability: "物理盘是否可推出尚未确认"
        case .missingRemovability: "物理盘是否可移除尚未确认"
        case .contradictoryEjectability: "物理盘的推出与移除信息相互矛盾"
        case .childLocationMismatch: "卷与物理盘的内置或外置位置不一致"
        case .duplicateMountTableEntry: "系统挂载信息存在重复条目"
        case .missingBSDName: "卷的系统设备标识缺失"
        case .invalidBSDName: "卷的系统设备标识无效"
        case .missingVolumeUUID: "卷身份缺失"
        case .invalidVolumeUUID: "卷身份无效"
        case .missingPhysicalDiskBSDName: "所属物理盘的系统设备标识缺失"
        case .invalidPhysicalDiskBSDName: "所属物理盘的系统设备标识无效"
        case .invalidMediaGeneration: "本次磁盘连接的身份代次无效"
        case .missingDisplayName: "卷的显示名称缺失"
        case .missingFileSystemName: "卷的文件系统未确认"
        case .missingLocation: "卷的内置或外置位置未确认"
        case .unknownVolumeRole: "卷用途未确认"
        case .conflictingVolumeRole: "卷用途的信息相互矛盾"
        case .missingMountTableEntry: "卷对应的系统挂载信息缺失"
        case .unexpectedMountTableEntry: "发现与卷状态不符的挂载条目"
        case .incompleteMountTableEntry: "卷的系统挂载信息不完整"
        case .mountAccessMismatch: "卷的只读或可写状态不一致"
        case .sourceDeviceMismatch: "挂载来源与目标设备不一致"
        case .mountPointMismatch: "挂载位置不一致"
        case .nonCanonicalMountPoint: "挂载位置不符合规范"
        case .symbolicLinkMountPoint: "挂载位置是符号链接，不能信任"
        }
    }
}

private extension DiagnosticArchitecture {
    var label: String { switch self {
    case .appleSilicon: "Apple Silicon"
    case .intel: "Intel"
    case .unknown: "未知"
    } }
}

private extension DiagnosticBackend {
    var label: String { switch self {
    case .fsKit: "FSKit"
    case .kernelExtension: "内核扩展（不支持写入）"
    case .unknown: "未知"
    } }
}

private extension DiagnosticFileSystem {
    var label: String { switch self {
    case .ntfs: "NTFS"
    case .other: "其他文件系统"
    case .unknown: "文件系统未知"
    } }
}

private extension DiagnosticVolumeLocation {
    var label: String { switch self {
    case .external: "外置卷"
    case .internal: "内置卷"
    case .unknown: "位置未知"
    } }
}

private extension DiagnosticVolumeRole {
    var label: String { switch self {
    case .data: "数据卷"
    case .protected: "受保护卷"
    case .bootCamp: "Boot Camp 卷"
    case .unknown: "用途未知"
    } }
}

private extension DiagnosticVolumeHealth {
    var label: String { switch self {
    case .clean: "未发现脏标记或休眠标记"
    case .dirty: "存在脏标记"
    case .hibernated: "Windows 休眠状态"
    case .unknown: "未知"
    } }
}

private extension DiagnosticMountAccess {
    var label: String { switch self {
    case .unmounted: "未挂载"
    case .readOnly: "只读"
    case .readWrite: "读写"
    case .unknown: "未知"
    } }
}

private extension DiagnosticVolumeStateCode {
    var label: String { switch self {
    case .readOnlyReady: "已挂载为只读"
    case .unmountedReady: "尚未挂载"
    case .existingWriteMountUnverified: "现有可写挂载尚未核验"
    case .unmountingForWrite: "正在卸载只读卷"
    case .awaitingSafetySnapshot: "等待安全检查"
    case .mountingWrite: "正在挂载为可写"
    case .awaitingWriteVerification: "等待可写状态核验"
    case .writable: "已核验可写（记录时）"
    case .writeVerificationFailed: "可写状态核验失败"
    case .unmountingForEject: "正在卸载整盘上的卷"
    case .awaitingUnmountVerification: "等待卸载结果核验"
    case .ejecting: "正在推出整盘"
    case .awaitingRemovalVerification: "等待确认整盘已消失"
    case .safeToRemove: "已核验可以拔出（记录时）"
    case .ejectFailed: "推出失败"
    case .ejectBlocked: "推出已被阻止"
    case .writeBlocked: "写入已被阻止"
    case .mediaInvalidated: "磁盘身份已失效"
    case .mediaUnavailable: "磁盘不可用"
    case .writeMutationQuiescencePending: "写入操作尚未确认停止"
    case .awaitingWriteMutationReconciliation: "等待重新核对写入后的状态"
    case .ejectMutationQuiescencePending: "推出操作尚未确认停止"
    case .awaitingEjectMutationReconciliation: "等待重新核对推出后的状态"
    case .writeOperationFailed: "写入操作失败"
    } }
}

private extension DiagnosticReasonCode {
    var label: String { switch self {
    case .windowsHibernated: "Windows 尚处于休眠状态"
    case .dirtyFileSystem: "文件系统存在脏标记"
    case .healthUnknown: "文件系统健康状态未知"
    case .internalVolume: "目标是内置卷"
    case .bootCampVolume: "目标是 Boot Camp 卷"
    case .protectedVolume: "目标卷受保护"
    case .unsupportedFileSystem: "文件系统不受支持"
    case .internalDisk: "目标是内置物理盘"
    case .bootCampDisk: "物理盘包含 Boot Camp 卷"
    case .protectedDisk: "物理盘受保护"
    case .protectedSibling: "同一物理盘上存在受保护卷"
    case .wrongVolume: "当前卷与请求目标不一致"
    case .observationIncomplete: "系统信息不完整"
    case .sourceDeviceMismatch: "挂载来源与目标设备不一致"
    case .notReadWrite: "尚未确认读写访问"
    case .unexpectedBackend: "挂载后端不符合要求"
    case .invalidMountPoint: "挂载位置无效"
    case .untrustedMountPath: "挂载位置不能信任"
    case .busy: "磁盘或文件正在使用中"
    case .volumesStillMounted: "仍有卷处于挂载状态"
    case .diskStillPresent: "物理盘仍在系统中"
    case .permissionDenied: "权限不足"
    case .dependencyUnavailable: "所需写入组件不可用"
    case .engineFailed: "写入引擎失败"
    case .inspectionUnavailable: "系统状态无法核验"
    case .timedOut: "操作超时，不能据此确认操作已停止"
    case .cancelled: "操作已取消，不能据此确认操作已停止"
    case .mediaChanged: "磁盘连接或身份已改变"
    } }
}

private extension DiagnosticOperationKind {
    var label: String { switch self {
    case .enableWriting: "启用写入"
    case .safeEject: "安全推出"
    } }
}

private extension DiagnosticOperationStage {
    var label: String { switch self {
    case .unmountReadOnly: "卸载只读卷"
    case .inspectSafety: "核验写入安全性"
    case .mountWrite: "挂载为可写"
    case .inspectWriteMount: "核验可写挂载"
    case .unmountPhysicalDisk: "卸载整盘上的卷"
    case .inspectPhysicalDiskAfterUnmount: "核验整盘卸载结果"
    case .ejectPhysicalDisk: "推出整盘"
    case .inspectPhysicalDiskAfterEject: "核验整盘已消失"
    case .waitForProcessExit: "等待操作进程退出"
    case .reconcile: "重新核对系统状态"
    } }
}

private extension DiagnosticResultCode {
    var label: String { switch self {
    case .succeeded: "阶段已完成"
    case .rejected: "请求被拒绝"
    case .busy: "正在使用中"
    case .permissionDenied: "权限不足"
    case .dependencyUnavailable: "所需组件不可用"
    case .engineFailed: "引擎失败"
    case .inspectionUnavailable: "无法核验系统状态"
    case .timedOut: "操作超时，停止状态尚未由此确认"
    case .cancelled: "操作已取消，停止状态尚未由此确认"
    case .observationIncomplete: "系统信息不完整"
    case .targetChanged: "目标身份已改变"
    case .mediaUnavailable: "磁盘不可用"
    case .unsafeState: "状态不满足安全要求"
    case .stillMounted: "仍有卷处于挂载状态"
    case .stillPresent: "整盘仍在系统中"
    } }
}

private extension DiagnosticExitKind {
    var label: String { switch self {
    case .exited: "已退出"
    case .signaled: "因信号终止"
    case .launchFailed: "启动失败"
    } }
}
