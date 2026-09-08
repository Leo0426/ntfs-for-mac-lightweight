import NTFSLiteCore
import NTFSLitePresentation

enum ScenarioID: String, CaseIterable, Identifiable {
    case setupNeedsAttention
    case setupReady
    case setupRefreshing
    case noDisk
    case multipleVolumesBusy
    case readOnly
    case unmounted
    case existingWriteUnverified
    case unmountingForWrite
    case awaitingSafetySnapshot
    case mountingWrite
    case awaitingWriteVerification
    case writable
    case writeVerificationFailed
    case hibernated
    case dirtyFileSystem
    case healthUnknown
    case internalVolume
    case bootCampVolume
    case unsupportedFileSystem
    case writeOperationFailed
    case writeQuiescence
    case writeReconciliation
    case unmountingForEject
    case awaitingUnmountVerification
    case ejecting
    case awaitingRemovalVerification
    case safeToRemove
    case ejectFailed
    case ejectBlocked
    case ejectInternalDisk
    case ejectBootCampDisk
    case ejectQuiescence
    case ejectReconciliation
    case ejectTemporarilyUnavailable
    case ejectAvailabilityBlocked
    case mediaChanged
    case mediaUnavailable

    var id: Self { self }

    var title: String {
        switch self {
        case .setupNeedsAttention:
            "首次设置 · 待处理"
        case .setupReady:
            "首次设置 · 已完成"
        case .setupRefreshing:
            "首次设置 · 检查中"
        case .noDisk:
            "清单 · 未检测到磁盘"
        case .multipleVolumesBusy:
            "清单 · 同盘忙碌与多盘"
        case .readOnly:
            "写入 · 当前只读"
        case .unmounted:
            "写入 · 当前未挂载"
        case .existingWriteUnverified:
            "写入 · 未验证可写挂载"
        case .unmountingForWrite:
            "写入 · 正在卸载只读卷"
        case .awaitingSafetySnapshot:
            "写入 · 正在重新检查"
        case .mountingWrite:
            "写入 · 正在挂载"
        case .awaitingWriteVerification:
            "写入 · 正在验证"
        case .writable:
            "写入 · 已验证可写"
        case .writeVerificationFailed:
            "写入 · 验证失败"
        case .hibernated:
            "写入 · Windows 休眠"
        case .dirtyFileSystem:
            "写入 · 文件系统未正常卸载"
        case .healthUnknown:
            "写入 · 健康状态未知"
        case .internalVolume:
            "写入 · 内部卷"
        case .bootCampVolume:
            "写入 · Boot Camp"
        case .unsupportedFileSystem:
            "写入 · 非 NTFS 文件系统"
        case .writeOperationFailed:
            "写入 · 引擎失败"
        case .writeQuiescence:
            "写入 · 等待进程停止"
        case .writeReconciliation:
            "写入 · 正在核对状态"
        case .unmountingForEject:
            "推出 · 正在同步并卸载"
        case .awaitingUnmountVerification:
            "推出 · 正在检查分区"
        case .ejecting:
            "推出 · 正在推出物理盘"
        case .awaitingRemovalVerification:
            "推出 · 正在确认结果"
        case .safeToRemove:
            "推出 · 已验证可以拔出"
        case .ejectFailed:
            "推出 · 设备忙"
        case .ejectBlocked:
            "推出 · 受保护分区阻止"
        case .ejectInternalDisk:
            "推出 · 内部盘阻止"
        case .ejectBootCampDisk:
            "推出 · Boot Camp 阻止"
        case .ejectQuiescence:
            "推出 · 等待进程停止"
        case .ejectReconciliation:
            "推出 · 正在核对整盘"
        case .ejectTemporarilyUnavailable:
            "推出 · 暂不可用"
        case .ejectAvailabilityBlocked:
            "推出 · 当前被阻止"
        case .mediaChanged:
            "介质 · 已变化"
        case .mediaUnavailable:
            "介质 · 已断开"
        }
    }

    var fixture: ScenarioFixture {
        switch self {
        case .setupNeedsAttention:
            setupNeedsAttentionFixture
        case .setupReady:
            ScenarioFixture(
                headline: "验证全部通过后仍保持克制",
                setup: readySetup,
                volumes: [],
                initialSelection: .environment,
                diagnosticLines: commonDiagnostics + [
                    "环境状态：已满足",
                    "写入能力：等待磁盘",
                ]
            )
        case .setupRefreshing:
            ScenarioFixture(
                headline: "验证刷新时不会复用旧的成功状态",
                setup: SetupPresenter.presentation(
                    for: SetupAssessment(issues: []),
                    isRefreshing: true
                ),
                volumes: [],
                initialSelection: .environment,
                diagnosticLines: commonDiagnostics + [
                    "环境状态：检查中",
                    "写入能力：关闭",
                ]
            )
        case .noDisk:
            ScenarioFixture(
                headline: "验证空状态不会诱导用户执行操作",
                setup: readySetup,
                volumes: [],
                initialSelection: .noDisk,
                diagnosticLines: commonDiagnostics + [
                    "检测到的 NTFS 卷：0",
                ]
            )
        case .multipleVolumesBusy:
            multipleVolumesBusyFixture
        case .readOnly:
            volumeFixture(
                headline: "验证只读状态只有一个写入主操作",
                state: .readOnlyReady
            )
        case .unmounted:
            volumeFixture(
                headline: "验证未挂载卷仍需重新检查后才允许写入",
                state: .unmountedReady
            )
        case .existingWriteUnverified:
            volumeFixture(
                headline: "验证未知来源的可写挂载不会被宣称为安全",
                state: .existingWriteMountUnverified(nil)
            )
        case .unmountingForWrite:
            volumeFixture(
                headline: "验证标准卸载阶段没有重复动作",
                state: .unmountingForWrite
            )
        case .awaitingSafetySnapshot:
            volumeFixture(
                headline: "验证卸载后仍等待新的安全事实",
                state: .awaitingSafetySnapshot
            )
        case .mountingWrite:
            volumeFixture(
                headline: "验证 FSKit 挂载阶段无法重复触发",
                state: .mountingWrite
            )
        case .awaitingWriteVerification:
            volumeFixture(
                headline: "验证命令成功后不会提前显示可写",
                state: .awaitingWriteVerification
            )
        case .writable:
            volumeFixture(
                headline: "验证只有复核后才显示可写",
                state: .writable
            )
        case .writeVerificationFailed:
            volumeFixture(
                headline: "验证挂载证据不符时提供安全恢复动作",
                state: .writeVerificationFailed(.notReadWrite)
            )
        case .hibernated:
            volumeFixture(
                headline: "验证休眠卷只提供安全解释和推出",
                state: .writeBlocked(.windowsHibernated)
            )
        case .dirtyFileSystem:
            volumeFixture(
                headline: "验证未正常卸载的卷拒绝写入且不自动修复",
                state: .writeBlocked(.dirtyFileSystem)
            )
        case .healthUnknown:
            volumeFixture(
                headline: "验证健康状态未知时默认拒绝写入",
                state: .writeBlocked(.healthUnknown)
            )
        case .internalVolume:
            volumeFixture(
                headline: "验证内部卷不会获得写入动作",
                state: .writeBlocked(.internalVolume),
                profile: .internalNTFS
            )
        case .bootCampVolume:
            volumeFixture(
                headline: "验证 Boot Camp 卷不会获得写入动作",
                state: .writeBlocked(.bootCampVolume),
                profile: .bootCamp
            )
        case .unsupportedFileSystem:
            volumeFixture(
                headline: "验证非 NTFS 卷不会进入写入流程",
                state: .writeBlocked(.unsupportedFileSystem),
                profile: .externalOther
            )
        case .writeOperationFailed:
            volumeFixture(
                headline: "验证写入引擎失败不会宣称成功",
                state: .writeOperationFailed(stage: .mountingWrite, failure: .engineFailed)
            )
        case .writeQuiescence:
            volumeFixture(
                headline: "验证超时后继续锁定磁盘直到进程退出",
                state: .writeMutationQuiescencePending(
                    stage: .mountingWrite,
                    failure: .timedOut
                )
            )
        case .writeReconciliation:
            volumeFixture(
                headline: "验证进程退出后仍等待新的磁盘事实",
                state: .awaitingWriteMutationReconciliation(
                    stage: .mountingWrite,
                    failure: .timedOut
                )
            )
        case .unmountingForEject:
            volumeFixture(
                headline: "验证推出从整盘标准卸载开始",
                state: .unmountingForEject
            )
        case .awaitingUnmountVerification:
            volumeFixture(
                headline: "验证推出前重新检查所有同盘分区",
                state: .awaitingUnmountVerification
            )
        case .ejecting:
            volumeFixture(
                headline: "验证最终推出命令执行时保持连接提示",
                state: .ejecting
            )
        case .awaitingRemovalVerification:
            volumeFixture(
                headline: "验证推出命令成功后仍等待系统事实",
                state: .awaitingRemovalVerification
            )
        case .safeToRemove:
            volumeFixture(
                headline: "验证最终事实复核后的拔出提示",
                state: .safeToRemove
            )
        case .ejectFailed:
            volumeFixture(
                headline: "验证设备忙时不提供强制推出",
                state: .ejectFailed(.busy)
            )
        case .ejectBlocked:
            volumeFixture(
                headline: "验证含受保护分区时阻止整盘推出",
                state: .ejectBlocked(.protectedSibling)
            )
        case .ejectInternalDisk:
            volumeFixture(
                headline: "验证内部物理盘永不提供整盘推出",
                state: .ejectBlocked(.internalDisk),
                profile: .internalNTFS
            )
        case .ejectBootCampDisk:
            volumeFixture(
                headline: "验证 Boot Camp 所在物理盘永不提供整盘推出",
                state: .ejectBlocked(.bootCampDisk),
                profile: .bootCamp
            )
        case .ejectQuiescence:
            volumeFixture(
                headline: "验证推出超时后继续锁定整块物理盘",
                state: .ejectMutationQuiescencePending(
                    stage: .ejectingPhysicalDisk,
                    failure: .timedOut
                )
            )
        case .ejectReconciliation:
            volumeFixture(
                headline: "验证推出进程退出后仍核对完整整盘事实",
                state: .awaitingEjectMutationReconciliation(
                    stage: .ejectingPhysicalDisk,
                    failure: .timedOut
                )
            )
        case .ejectTemporarilyUnavailable:
            volumeFixture(
                headline: "验证整盘范围不完整时暂时隐藏推出动作",
                state: .readOnlyReady,
                safeEjectAvailability: .temporarilyUnavailable
            )
        case .ejectAvailabilityBlocked:
            volumeFixture(
                headline: "验证受保护 sibling 会移除推出动作并解释原因",
                state: .readOnlyReady,
                safeEjectAvailability: .blocked(.protectedSibling)
            )
        case .mediaChanged:
            volumeFixture(
                headline: "验证旧目标失效后不再提供变更操作",
                state: .mediaInvalidated(mediaMismatch)
            )
        case .mediaUnavailable:
            volumeFixture(
                headline: "验证断开后撤销之前的读写状态",
                state: .mediaUnavailable
            )
        }
    }

    var menuSummary: String {
        let currentFixture = fixture
        switch currentFixture.initialSelection {
        case .noDisk:
            return "未检测到 NTFS 磁盘"
        case let .volume(volumeID):
            return currentFixture.volumes
                .first(where: { $0.id == volumeID })?
                .presentation.title ?? "磁盘状态已变化"
        case .environment:
            return currentFixture.setup.title
        case .diagnostics:
            return "诊断摘要"
        }
    }

    private var setupNeedsAttentionFixture: ScenarioFixture {
        ScenarioFixture(
            headline: "验证缺失依赖是否能给出明确下一步",
            setup: SetupPresenter.presentation(
                for: SetupAssessment(
                    issues: [
                        .macFUSEMissing,
                        .fileSystemExtensionDisabled,
                        .ntfs3GTooOld(
                            minimum: SemanticVersion(major: 2026, minor: 7, patch: 7),
                            observed: SemanticVersion(major: 2026, minor: 2, patch: 25)
                        ),
                        .unsafeBackend(.unknown),
                        .conflictingDrivers([
                            "/Users/example/Library/Filesystems/commercial.driver",
                        ]),
                    ]
                ),
                isRefreshing: false
            ),
            volumes: [],
            initialSelection: .environment,
            diagnosticLines: commonDiagnostics + [
                "环境状态：5 项待处理",
                "写入能力：关闭",
            ]
        )
    }

    private var multipleVolumesBusyFixture: ScenarioFixture {
        let active = ScenarioVolume(
            id: "archive",
            displayName: "ARCHIVE — 家庭照片与归档",
            deviceSummary: "外置 NTFS · disk4s1 · 800 GB",
            physicalDiskID: "disk4",
            physicalDiskLabel: "物理盘 disk4 · 1 TB",
            physicalDiskSummary: "安全推出会作用于 disk4 的全部分区",
            status: VolumeStatusSnapshot(
                state: .mountingWrite,
                safeEjectAvailability: .available
            )
        )
        let sibling = ScenarioVolume(
            id: "transfer",
            displayName: "TRANSFER — 临时交换",
            deviceSummary: "外置 NTFS · disk4s2 · 200 GB",
            physicalDiskID: "disk4",
            physicalDiskLabel: "物理盘 disk4 · 1 TB",
            physicalDiskSummary: "同盘 ARCHIVE 正在执行变更；当前卷不可操作",
            status: VolumeStatusSnapshot(
                state: .readOnlyReady,
                safeEjectAvailability: .temporarilyUnavailable,
                isPhysicalDiskBusy: true
            )
        )
        let independent = ScenarioVolume(
            id: "backup",
            displayName: "BACKUP — 独立备份盘",
            deviceSummary: "外置 NTFS · disk6s1 · 2 TB",
            physicalDiskID: "disk6",
            physicalDiskLabel: "物理盘 disk6 · 2 TB",
            physicalDiskSummary: "独立物理盘；不受 disk4 的操作锁影响",
            status: VolumeStatusSnapshot(
                state: .readOnlyReady,
                safeEjectAvailability: .available
            )
        )
        return ScenarioFixture(
            headline: "验证同盘 sibling 锁定、物理盘分组与独立磁盘可操作",
            setup: readySetup,
            volumes: [active, sibling, independent],
            initialSelection: .volume(sibling.id),
            diagnosticLines: commonDiagnostics + [
                "物理盘数量：2",
                "NTFS 卷数量：3",
                "物理盘 1 操作锁：占用中",
                "物理盘 2 操作锁：空闲",
            ]
        )
    }

    private var readySetup: SetupPresentation {
        SetupPresenter.presentation(
            for: SetupAssessment(issues: []),
            isRefreshing: false
        )
    }

    private var commonDiagnostics: [String] {
        [
            "模式：一次性 C 版界面原型",
            "数据来源：内存 fixture",
            "真实磁盘访问：无",
            "真实进程调用：无",
        ]
    }

    private var mediaMismatch: MediaInstanceMismatch {
        MediaInstanceMismatch(
            expected: DiskInstanceID(
                physicalDiskID: PhysicalDiskID(rawValue: "disk4"),
                mediaGeneration: MediaGeneration(rawValue: 7)
            ),
            observed: DiskInstanceID(
                physicalDiskID: PhysicalDiskID(rawValue: "disk4"),
                mediaGeneration: MediaGeneration(rawValue: 8)
            )
        )
    }

    private func volumeFixture(
        headline: String,
        state: VolumeState,
        safeEjectAvailability: SafeEjectAvailability = .available,
        profile: ScenarioVolumeProfile = .externalNTFS
    ) -> ScenarioFixture {
        let volume = ScenarioVolume(
            id: profile.id,
            displayName: profile.displayName,
            deviceSummary: profile.deviceSummary,
            physicalDiskID: profile.physicalDiskID,
            physicalDiskLabel: profile.physicalDiskLabel,
            physicalDiskSummary: profile.physicalDiskSummary,
            status: VolumeStatusSnapshot(
                state: state,
                safeEjectAvailability: safeEjectAvailability
            )
        )
        return ScenarioFixture(
            headline: headline,
            setup: readySetup,
            volumes: [volume],
            initialSelection: .volume(volume.id),
            diagnosticLines: commonDiagnostics + profile.diagnosticLines
        )
    }
}

private struct ScenarioVolumeProfile: Sendable {
    let id: String
    let displayName: String
    let deviceSummary: String
    let physicalDiskID: String
    let physicalDiskLabel: String
    let physicalDiskSummary: String
    let diagnosticLines: [String]

    static let externalNTFS = ScenarioVolumeProfile(
        id: "archive",
        displayName: "ARCHIVE — 家庭照片与归档",
        deviceSummary: "外置 NTFS · disk4s1 · 1 TB",
        physicalDiskID: "disk4",
        physicalDiskLabel: "物理盘 disk4 · 1 TB",
        physicalDiskSummary: "安全推出会作用于 disk4 的全部分区",
        diagnosticLines: [
            "卷别名：卷 1",
            "文件系统：NTFS",
            "位置：外置",
            "物理盘别名：物理盘 1",
            "介质代次：7",
        ]
    )

    static let internalNTFS = ScenarioVolumeProfile(
        id: "internal-data",
        displayName: "INTERNAL DATA — 内部数据卷",
        deviceSummary: "内部 NTFS · disk0s5 · 250 GB",
        physicalDiskID: "disk0",
        physicalDiskLabel: "内部物理盘 disk0",
        physicalDiskSummary: "内部物理盘；不提供写入或整盘推出",
        diagnosticLines: [
            "卷别名：卷 1",
            "文件系统：NTFS",
            "位置：内部",
            "物理盘别名：物理盘 1",
            "介质代次：3",
        ]
    )

    static let bootCamp = ScenarioVolumeProfile(
        id: "bootcamp",
        displayName: "BOOTCAMP — Windows 系统卷",
        deviceSummary: "内部 NTFS · disk0s3 · 500 GB · Boot Camp",
        physicalDiskID: "disk0",
        physicalDiskLabel: "内部物理盘 disk0",
        physicalDiskSummary: "Boot Camp 系统卷；不提供写入或整盘推出",
        diagnosticLines: [
            "卷别名：卷 1",
            "文件系统：NTFS",
            "位置：内部",
            "角色：Boot Camp",
            "物理盘别名：物理盘 1",
            "介质代次：3",
        ]
    )

    static let externalOther = ScenarioVolumeProfile(
        id: "media",
        displayName: "MEDIA — 非 NTFS 外置卷",
        deviceSummary: "外置 exFAT · disk4s1 · 1 TB",
        physicalDiskID: "disk4",
        physicalDiskLabel: "物理盘 disk4 · 1 TB",
        physicalDiskSummary: "非 NTFS 卷；不进入写入切换流程",
        diagnosticLines: [
            "卷别名：卷 1",
            "文件系统：exFAT",
            "位置：外置",
            "物理盘别名：物理盘 1",
            "介质代次：7",
        ]
    )
}

struct ScenarioFixture {
    let headline: String
    let setup: SetupPresentation
    let volumes: [ScenarioVolume]
    let initialSelection: ScenarioSelection
    let diagnosticLines: [String]

    var sidebarGroups: [ScenarioSidebarGroup] {
        var groups: [ScenarioSidebarGroup] = []
        if volumes.isEmpty {
            groups.append(ScenarioSidebarGroup(title: "磁盘", entries: [.noDisk]))
        } else {
            var seenPhysicalDisks: [String] = []
            for volume in volumes where !seenPhysicalDisks.contains(volume.physicalDiskID) {
                seenPhysicalDisks.append(volume.physicalDiskID)
                let entries = volumes
                    .filter { $0.physicalDiskID == volume.physicalDiskID }
                    .map { ScenarioSelection.volume($0.id) }
                groups.append(
                    ScenarioSidebarGroup(title: volume.physicalDiskLabel, entries: entries)
                )
            }
        }
        groups.append(
            ScenarioSidebarGroup(title: "设置", entries: [.environment, .diagnostics])
        )
        return groups
    }

    var sidebarEntries: [ScenarioSelection] {
        sidebarGroups.flatMap(\.entries)
    }
}

struct ScenarioSidebarGroup {
    let title: String
    let entries: [ScenarioSelection]
}

struct ScenarioVolume {
    let id: String
    let displayName: String
    let deviceSummary: String
    let physicalDiskID: String
    let physicalDiskLabel: String
    let physicalDiskSummary: String
    let status: VolumeStatusSnapshot

    var presentation: VolumePresentation {
        VolumePresenter.presentation(for: status)
    }
}

enum ScenarioSelection: Hashable {
    case noDisk
    case volume(String)
    case environment
    case diagnostics

    func title(in fixture: ScenarioFixture) -> String {
        switch self {
        case .noDisk:
            "未检测到磁盘"
        case let .volume(id):
            fixture.volumes.first(where: { $0.id == id })?.displayName ?? "磁盘已变化"
        case .environment:
            "运行环境"
        case .diagnostics:
            "诊断摘要"
        }
    }

    func category(in fixture: ScenarioFixture) -> String {
        switch self {
        case .noDisk:
            "磁盘"
        case let .volume(id):
            fixture.volumes.first(where: { $0.id == id })?.physicalDiskLabel ?? "磁盘"
        case .environment, .diagnostics:
            "设置"
        }
    }
}

enum ScenarioCatalogValidation {
    static func validate() {
        let representedStates = Set(
            ScenarioID.allCases.compactMap { scenario -> VolumeStateCaseID? in
                let fixture = scenario.fixture
                guard case let .volume(volumeID) = fixture.initialSelection,
                      let volume = fixture.volumes.first(where: { $0.id == volumeID })
                else {
                    return nil
                }
                return VolumeStateCaseID(volume.status.state)
            }
        )
        let requiredStates = Set(VolumeStateCaseID.allCases)
        precondition(
            representedStates == requiredStates,
            "Scenario catalog must cover every VolumeState case exactly at least once"
        )
    }
}

private enum VolumeStateCaseID: CaseIterable, Hashable {
    case readOnlyReady
    case unmountedReady
    case existingWriteMountUnverified
    case unmountingForWrite
    case awaitingSafetySnapshot
    case mountingWrite
    case awaitingWriteVerification
    case writable
    case writeVerificationFailed
    case unmountingForEject
    case awaitingUnmountVerification
    case ejecting
    case awaitingRemovalVerification
    case safeToRemove
    case ejectFailed
    case ejectBlocked
    case writeBlocked
    case mediaInvalidated
    case mediaUnavailable
    case writeMutationQuiescencePending
    case awaitingWriteMutationReconciliation
    case ejectMutationQuiescencePending
    case awaitingEjectMutationReconciliation
    case writeOperationFailed

    init(_ state: VolumeState) {
        switch state {
        case .readOnlyReady:
            self = .readOnlyReady
        case .unmountedReady:
            self = .unmountedReady
        case .existingWriteMountUnverified:
            self = .existingWriteMountUnverified
        case .unmountingForWrite:
            self = .unmountingForWrite
        case .awaitingSafetySnapshot:
            self = .awaitingSafetySnapshot
        case .mountingWrite:
            self = .mountingWrite
        case .awaitingWriteVerification:
            self = .awaitingWriteVerification
        case .writable:
            self = .writable
        case .writeVerificationFailed:
            self = .writeVerificationFailed
        case .unmountingForEject:
            self = .unmountingForEject
        case .awaitingUnmountVerification:
            self = .awaitingUnmountVerification
        case .ejecting:
            self = .ejecting
        case .awaitingRemovalVerification:
            self = .awaitingRemovalVerification
        case .safeToRemove:
            self = .safeToRemove
        case .ejectFailed:
            self = .ejectFailed
        case .ejectBlocked:
            self = .ejectBlocked
        case .writeBlocked:
            self = .writeBlocked
        case .mediaInvalidated:
            self = .mediaInvalidated
        case .mediaUnavailable:
            self = .mediaUnavailable
        case .writeMutationQuiescencePending:
            self = .writeMutationQuiescencePending
        case .awaitingWriteMutationReconciliation:
            self = .awaitingWriteMutationReconciliation
        case .ejectMutationQuiescencePending:
            self = .ejectMutationQuiescencePending
        case .awaitingEjectMutationReconciliation:
            self = .awaitingEjectMutationReconciliation
        case .writeOperationFailed:
            self = .writeOperationFailed
        }
    }
}
