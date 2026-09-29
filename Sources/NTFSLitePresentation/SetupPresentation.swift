import Foundation
import NTFSLiteCore
import NTFSLiteSystem

public enum SetupRequirementID: Equatable, Hashable, Sendable {
    case operatingSystem
    case architecture
    case macFUSE
    case fileSystemExtension
    case ntfs3G
    case backend
    case authorization
    case conflictingDrivers
}

public enum SetupRequirementState: Equatable, Sendable {
    case satisfied
    case actionRequired
    case checking
}

/// This only hides a misleading registration action from development bundles.
/// The helper must independently verify installation ownership, permissions and signature.
public enum HelperEnablementUI {
    public static func shouldOfferRegistration(for appBundleURL: URL) -> Bool {
        appBundleURL.isFileURL
            && appBundleURL.standardizedFileURL.path
                == "/Library/PrivilegedHelperTools/NTFSLite.app"
    }
}

public struct SetupRequirementPresentation: Equatable, Sendable {
    public let id: SetupRequirementID
    public let state: SetupRequirementState
    public let statusText: String
    public let title: String
    public let detail: String
    public let observedConflictCount: Int?
    public let conflictScanIncomplete: Bool

    init(
        id: SetupRequirementID,
        state: SetupRequirementState,
        statusText: String,
        title: String,
        detail: String,
        observedConflictCount: Int? = nil,
        conflictScanIncomplete: Bool = false
    ) {
        self.id = id
        self.state = state
        self.statusText = statusText
        self.title = title
        self.detail = detail
        self.observedConflictCount = observedConflictCount
        self.conflictScanIncomplete = conflictScanIncomplete
    }
}

public enum SetupRequirementGroupID: Equatable, Hashable, Sendable {
    case systemCompatibility
    case writeComponents
    case fsKitSupport
    case otherChecks
}

public struct SetupRequirementGroupPresentation: Equatable, Sendable {
    public let id: SetupRequirementGroupID
    public let title: String
    public let detail: String
    public let state: SetupRequirementState
    public let statusText: String
    public let requirements: [SetupRequirementPresentation]
}

public enum SetupPresentationAction: Equatable, Sendable {
    case continueSetup
    case recheck
    case copyDiagnostics

    public var title: String {
        switch self {
        case .continueSetup:
            "继续设置"
        case .recheck:
            "重新检查"
        case .copyDiagnostics:
            "复制诊断摘要"
        }
    }
}

public struct SetupPresentation: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let requirements: [SetupRequirementPresentation]
    public let primaryAction: SetupPresentationAction?
    public let secondaryActions: [SetupPresentationAction]
    public let isReady: Bool
    public let isBusy: Bool

    public var groups: [SetupRequirementGroupPresentation] {
        [
            group(
                id: .systemCompatibility,
                title: "系统兼容",
                detail: "macOS 版本与处理器架构。",
                ids: [.operatingSystem, .architecture]
            ),
            group(
                id: .writeComponents,
                title: "写入组件",
                detail: "macFUSE 与应用内 NTFS-3G 的独立校验。",
                ids: [.macFUSE, .ntfs3G]
            ),
            group(
                id: .fsKitSupport,
                title: "FSKit 支持",
                detail: "文件系统扩展与 FSKit 后端。",
                ids: [.fileSystemExtension, .backend]
            ),
            group(
                id: .otherChecks,
                title: "其他诊断",
                detail: "授权与已知驱动冲突的独立检查。",
                ids: [.authorization, .conflictingDrivers]
            ),
        ]
    }

    init(
        title: String,
        detail: String,
        requirements: [SetupRequirementPresentation],
        primaryAction: SetupPresentationAction?,
        secondaryActions: [SetupPresentationAction],
        isReady: Bool,
        isBusy: Bool
    ) {
        self.title = title
        self.detail = detail
        self.requirements = requirements
        self.primaryAction = primaryAction
        self.secondaryActions = secondaryActions
        self.isReady = isReady
        self.isBusy = isBusy
    }

    private func group(
        id: SetupRequirementGroupID,
        title: String,
        detail: String,
        ids: [SetupRequirementID]
    ) -> SetupRequirementGroupPresentation {
        let members = ids.compactMap { id in
            requirements.first { $0.id == id }
        }
        let state: SetupRequirementState
        if members.contains(where: { $0.state == .actionRequired }) {
            state = .actionRequired
        } else if members.count != ids.count || members.contains(where: { $0.state == .checking }) {
            state = .checking
        } else {
            state = .satisfied
        }
        let conflictRequirement = id == .otherChecks
            ? members.first { $0.id == .conflictingDrivers }
            : nil
        let observedConflictCount = conflictRequirement?.observedConflictCount
        let statusText: String = if observedConflictCount != nil {
            "发现冲突"
        } else { switch state {
        case .satisfied: "已满足"
        case .actionRequired: "待确认"
        case .checking: "检查中"
        } }
        let groupDetail: String
        if let observedConflictCount {
            let countText = observedConflictCount == 0
                ? "至少 1 个"
                : "\(observedConflictCount) 个"
            groupDetail = conflictRequirement?.conflictScanIncomplete == true
                ? "发现\(countText)已知冲突驱动；此次扫描仍未完成，结果只覆盖已检查范围。展开查看详情。"
                : "发现\(countText)已知冲突驱动；展开查看详情及扫描范围。"
        } else if id == .writeComponents
                    && members.contains(where: { $0.statusText == "未配置" }) {
            let pendingTitles = members
                .filter { $0.state == .actionRequired }
                .map(\.title)
                .joined(separator: "；")
            groupDetail = "\(pendingTitles)。展开查看详情。"
        } else {
            groupDetail = detail
        }
        return SetupRequirementGroupPresentation(
            id: id,
            title: title,
            detail: groupDetail,
            state: state,
            statusText: statusText,
            requirements: members
        )
    }
}

public enum SetupPresenter {
    private static let requirementOrder: [SetupRequirementID] = [
        .operatingSystem,
        .architecture,
        .macFUSE,
        .fileSystemExtension,
        .ntfs3G,
        .backend,
        .authorization,
        .conflictingDrivers,
    ]

    public static func presentation(
        for assessment: SetupAssessment,
        isRefreshing: Bool
    ) -> SetupPresentation {
        if isRefreshing {
            return SetupPresentation(
                title: "正在进行只读环境检查",
                detail: "正在重新读取系统、依赖和后端状态；此页只读取系统状态，写入时帮助程序会另行核对目标磁盘及挂载结果。",
                requirements: requirementOrder.map(checkingRequirement),
                primaryAction: nil,
                secondaryActions: [],
                isReady: false,
                isBusy: true
            )
        }

        let issuesByRequirement = normalizedIssues(assessment.issues)
        let conflictScanIncomplete = assessment.issues.contains { issue in
            if case .conflictScanIncomplete = issue { return true }
            return false
        }
        let requirements = requirementOrder.map { id in
            requirement(
                id: id,
                issue: issuesByRequirement[id],
                conflictScanIncomplete: conflictScanIncomplete
            )
        }

        if assessment.isReady {
            return SetupPresentation(
                title: "只读环境检查完成",
                detail: "当前检查项目均已满足；写入时帮助程序会重新核对目标磁盘及挂载结果。",
                requirements: requirements,
                primaryAction: .recheck,
                secondaryActions: [],
                isReady: true,
                isBusy: false
            )
        }

        return SetupPresentation(
            title: "只读环境检查有待确认",
            detail: "部分检查有待确认；请按类别查看详情。写入时帮助程序会另行核对目标磁盘及挂载结果。",
            requirements: requirements,
            primaryAction: .continueSetup,
            secondaryActions: [.copyDiagnostics],
            isReady: false,
            isBusy: false
        )
    }

    public static func presentation(
        for report: SystemSetupReport,
        isRefreshing: Bool
    ) -> SetupPresentation {
        let base = presentation(
            for: SetupChecker.assess(report.reconciledFacts),
            isRefreshing: isRefreshing
        )
        guard !isRefreshing else {
            return base
        }

        let requirements = base.requirements.map { requirement in
            switch requirement.id {
            case .macFUSE:
                dependencyRequirement(
                    requirement,
                    evidence: report.macFUSEEvidence
                )
            case .ntfs3G:
                dependencyRequirement(
                    requirement,
                    evidence: report.ntfs3GEvidence
                )
            default:
                requirement
            }
        }
        let buildTrustPolicyMissing = report.macFUSEEvidence == .notConfigured
            || report.ntfs3GEvidence == .notConfigured
        return SetupPresentation(
            title: buildTrustPolicyMissing
                ? "独立可信报告未配置"
                : base.title,
            detail: buildTrustPolicyMissing
                ? "此页尚未配置独立的依赖可信报告，不能据此判断依赖是否缺失，也不决定帮助程序的写入资格。帮助程序每次操作会另行核验目标磁盘与挂载条件；其他检查结果可重新读取。"
                : base.detail,
            requirements: requirements,
            primaryAction: buildTrustPolicyMissing ? .recheck : base.primaryAction,
            secondaryActions: buildTrustPolicyMissing ? [.copyDiagnostics] : base.secondaryActions,
            isReady: base.isReady,
            isBusy: base.isBusy
        )
    }

    private static func dependencyRequirement(
        _ requirement: SetupRequirementPresentation,
        evidence: MacFUSESetupEvidence
    ) -> SetupRequirementPresentation {
        switch evidence {
        case .trusted:
            return requirement
        case .notConfigured:
            return SetupRequirementPresentation(
                id: .macFUSE,
                state: .actionRequired,
                statusText: "未配置",
                title: "macFUSE 独立可信报告未配置",
                detail: "此页尚未配置受信任校验策略，不能据此判断 macFUSE 是否已安装。帮助程序在操作时另行核验挂载条件。"
            )
        case let .failedClosed(failure):
            return SetupRequirementPresentation(
                id: .macFUSE,
                state: .actionRequired,
                statusText: "待处理",
                title: "macFUSE 可信校验未通过",
                detail: "固定失败码 \(macFUSEFailureCode(failure))。请核对批准策略、安装来源和文件权限；此项检查未通过。"
            )
        }
    }

    private static func macFUSEFailureCode(
        _ failure: TrustedMacFUSEReadFailure
    ) -> String {
        switch failure {
        case let .bundle(bundleFailure):
            bundleFailureCode(bundleFailure)
        case let .codeSignature(signatureFailure):
            codeSignatureFailureCode(signatureFailure)
        }
    }

    private static func codeSignatureFailureCode(
        _ failure: TrustedCodeSignatureReadFailure
    ) -> String {
        switch failure {
        case .invalidPolicy:
            "MACFUSE_SIGNATURE_INVALID_POLICY"
        case .requirementInvalid:
            "MACFUSE_REQUIREMENT_INVALID"
        case .staticCodeUnavailable:
            "MACFUSE_STATIC_CODE_UNAVAILABLE"
        case .signatureInvalid:
            "MACFUSE_SIGNATURE_INVALID"
        case .signingInformationUnavailable:
            "MACFUSE_SIGNING_INFO_UNAVAILABLE"
        case .teamIdentifierMissing:
            "MACFUSE_TEAM_ID_MISSING"
        case .codeDirectoryHashMissing:
            "MACFUSE_CDHASH_MISSING"
        case .securedInfoPlistMissing:
            "MACFUSE_SECURED_PLIST_MISSING"
        case .securedBundleIdentifierMissing:
            "MACFUSE_SECURED_BUNDLE_ID_MISSING"
        case .securedBundleVersionMissing:
            "MACFUSE_SECURED_BUNDLE_VERSION_MISSING"
        case .securedBundleVersionInvalid:
            "MACFUSE_SECURED_BUNDLE_VERSION_INVALID"
        case .teamIdentifierMismatch:
            "MACFUSE_TEAM_ID_MISMATCH"
        case .codeDirectoryHashMismatch:
            "MACFUSE_CDHASH_MISMATCH"
        case .securedBundleIdentifierMismatch:
            "MACFUSE_SECURED_BUNDLE_ID_MISMATCH"
        case .securedBundleVersionMismatch:
            "MACFUSE_SECURED_BUNDLE_VERSION_MISMATCH"
        }
    }

    private static func dependencyRequirement(
        _ requirement: SetupRequirementPresentation,
        evidence: NTFS3GSetupEvidence
    ) -> SetupRequirementPresentation {
        switch evidence {
        case .trusted:
            return requirement
        case .notConfigured:
            return SetupRequirementPresentation(
                id: .ntfs3G,
                state: .actionRequired,
                statusText: "未配置",
                title: "NTFS-3G 独立可信报告未配置",
                detail: "此页尚未配置受信任校验策略，不能据此判断 NTFS-3G 是否已安装。帮助程序在操作时另行核验固定驱动与挂载条件。"
            )
        case let .failedClosed(failure):
            return SetupRequirementPresentation(
                id: .ntfs3G,
                state: .actionRequired,
                statusText: "待处理",
                title: "NTFS-3G 可信校验未通过",
                detail: "固定失败码 \(ntfs3GFailureCode(failure))。请核对批准目录、制品来源和文件权限；此项检查未通过。"
            )
        }
    }

    private static func bundleFailureCode(
        _ failure: TrustedBundleVersionReadFailure
    ) -> String {
        switch failure {
        case .invalidPolicy:
            "BUNDLE_INVALID_POLICY"
        case .invalidAbsoluteBundlePath:
            "BUNDLE_INVALID_PATH"
        case .pathComponentUnavailable:
            "BUNDLE_PATH_UNAVAILABLE"
        case .pathComponentIsSymbolicLink:
            "BUNDLE_PATH_SYMBOLIC_LINK"
        case .pathComponentIsNotDirectory:
            "BUNDLE_PATH_NOT_DIRECTORY"
        case .ownerMismatch:
            "BUNDLE_OWNER_MISMATCH"
        case .unsafeWritePermissions:
            "BUNDLE_UNSAFE_PERMISSIONS"
        case .infoPlistUnavailable:
            "BUNDLE_METADATA_UNAVAILABLE"
        case .infoPlistIsSymbolicLink:
            "BUNDLE_METADATA_SYMBOLIC_LINK"
        case .infoPlistIsNotRegularFile:
            "BUNDLE_METADATA_NOT_FILE"
        case .infoPlistTooLarge:
            "BUNDLE_METADATA_TOO_LARGE"
        case .infoPlistReadFailed:
            "BUNDLE_METADATA_READ_FAILED"
        case .invalidPropertyList:
            "BUNDLE_METADATA_INVALID"
        case .bundleIdentifierMismatch:
            "BUNDLE_IDENTIFIER_MISMATCH"
        case .versionMissing:
            "BUNDLE_VERSION_MISSING"
        case .invalidSemanticVersion:
            "BUNDLE_VERSION_INVALID"
        case .versionNotApproved:
            "BUNDLE_VERSION_NOT_APPROVED"
        }
    }

    private static func ntfs3GFailureCode(
        _ failure: TrustedNTFS3GArtifactFailure
    ) -> String {
        switch failure {
        case .invalidVersionCatalog:
            "NTFS3G_VERSION_CATALOG"
        case let .executable(failure):
            executableFailureCode(failure)
        }
    }

    private static func executableFailureCode(
        _ failure: TrustedExecutableVerificationFailure
    ) -> String {
        switch failure {
        case .invalidPolicy:
            "NTFS3G_EXECUTABLE_INVALID_POLICY"
        case .invalidAbsolutePath:
            "NTFS3G_EXECUTABLE_INVALID_PATH"
        case .basenameMismatch:
            "NTFS3G_EXECUTABLE_BASENAME_MISMATCH"
        case .pathComponentUnavailable:
            "NTFS3G_EXECUTABLE_PATH_UNAVAILABLE"
        case .pathComponentIsSymbolicLink:
            "NTFS3G_EXECUTABLE_PATH_SYMBOLIC_LINK"
        case .pathComponentIsNotDirectory:
            "NTFS3G_EXECUTABLE_PATH_NOT_DIRECTORY"
        case .executableUnavailable:
            "NTFS3G_EXECUTABLE_UNAVAILABLE"
        case .executableIsSymbolicLink:
            "NTFS3G_EXECUTABLE_SYMBOLIC_LINK"
        case .executableIsNotRegularFile:
            "NTFS3G_EXECUTABLE_NOT_FILE"
        case .ownerMismatch:
            "NTFS3G_EXECUTABLE_OWNER_MISMATCH"
        case .privilegeEscalationBitsPresent:
            "NTFS3G_EXECUTABLE_PRIVILEGE_BITS"
        case .unsafeWritePermissions:
            "NTFS3G_EXECUTABLE_UNSAFE_PERMISSIONS"
        case .executablePermissionMissing:
            "NTFS3G_EXECUTABLE_PERMISSION_MISSING"
        case .executableTooLarge:
            "NTFS3G_EXECUTABLE_TOO_LARGE"
        case .executableReadFailed:
            "NTFS3G_EXECUTABLE_READ_FAILED"
        case .executableChangedDuringRead:
            "NTFS3G_EXECUTABLE_CHANGED"
        case .executableGrewDuringRead:
            "NTFS3G_EXECUTABLE_GREW"
        case .cryptographicHashUnavailable:
            "NTFS3G_EXECUTABLE_HASH_UNAVAILABLE"
        case .digestNotAllowed:
            "NTFS3G_EXECUTABLE_DIGEST_NOT_ALLOWED"
        }
    }

    private static func requirementID(for issue: SetupIssue) -> SetupRequirementID {
        switch issue {
        case .unsupportedOperatingSystem:
            .operatingSystem
        case .unsupportedArchitecture:
            .architecture
        case .macFUSEMissing, .macFUSETooOld:
            .macFUSE
        case .fileSystemExtensionDisabled:
            .fileSystemExtension
        case .ntfs3GMissing, .ntfs3GTooOld:
            .ntfs3G
        case .unsafeBackend:
            .backend
        case .requiredAuthorizationUnavailable:
            .authorization
        case .conflictScanIncomplete, .conflictingDrivers:
            .conflictingDrivers
        }
    }

    private static func normalizedIssues(
        _ issues: [SetupIssue]
    ) -> [SetupRequirementID: SetupIssue] {
        var result: [SetupRequirementID: SetupIssue] = [:]
        for issue in issues {
            let id = requirementID(for: issue)
            guard let current = result[id] else {
                result[id] = issue
                continue
            }
            result[id] = preferredIssue(current, issue)
        }
        return result
    }

    private static func preferredIssue(_ lhs: SetupIssue, _ rhs: SetupIssue) -> SetupIssue {
        switch (lhs, rhs) {
        case let (
            .unsupportedOperatingSystem(lhsMinimum, lhsObserved),
            .unsupportedOperatingSystem(rhsMinimum, rhsObserved)
        ):
            if lhsObserved != rhsObserved {
                return lhsObserved < rhsObserved ? lhs : rhs
            }
            return lhsMinimum < rhsMinimum ? rhs : lhs
        case let (.unsupportedArchitecture(lhsValue), .unsupportedArchitecture(rhsValue)):
            return architectureRank(lhsValue) <= architectureRank(rhsValue) ? lhs : rhs
        case (.macFUSEMissing, _), (_, .macFUSEMissing):
            return .macFUSEMissing
        case let (
            .macFUSETooOld(lhsMinimum, lhsObserved),
            .macFUSETooOld(rhsMinimum, rhsObserved)
        ):
            if lhsObserved != rhsObserved {
                return lhsObserved < rhsObserved ? lhs : rhs
            }
            return lhsMinimum < rhsMinimum ? rhs : lhs
        case (.fileSystemExtensionDisabled, .fileSystemExtensionDisabled):
            return .fileSystemExtensionDisabled
        case (.ntfs3GMissing, _), (_, .ntfs3GMissing):
            return .ntfs3GMissing
        case let (
            .ntfs3GTooOld(lhsMinimum, lhsObserved),
            .ntfs3GTooOld(rhsMinimum, rhsObserved)
        ):
            if lhsObserved != rhsObserved {
                return lhsObserved < rhsObserved ? lhs : rhs
            }
            return lhsMinimum < rhsMinimum ? rhs : lhs
        case let (.unsafeBackend(lhsValue), .unsafeBackend(rhsValue)):
            return backendRank(lhsValue) <= backendRank(rhsValue) ? lhs : rhs
        case let (
            .requiredAuthorizationUnavailable(lhsValue),
            .requiredAuthorizationUnavailable(rhsValue)
        ):
            return authorizationRank(lhsValue) <= authorizationRank(rhsValue) ? lhs : rhs
        case let (.conflictScanIncomplete, .conflictingDrivers(drivers)),
             let (.conflictingDrivers(drivers), .conflictScanIncomplete):
            return .conflictingDrivers(drivers)
        case (.conflictScanIncomplete, .conflictScanIncomplete):
            return .conflictScanIncomplete
        case let (.conflictingDrivers(lhsValues), .conflictingDrivers(rhsValues)):
            return .conflictingDrivers(lhsValues + rhsValues)
        default:
            return lhs
        }
    }

    private static func checkingRequirement(
        id: SetupRequirementID
    ) -> SetupRequirementPresentation {
        let content = satisfiedContent(for: id)
        return SetupRequirementPresentation(
            id: id,
            state: .checking,
            statusText: "检查中",
            title: content.title,
            detail: "正在重新读取这项系统事实。"
        )
    }

    private static func requirement(
        id: SetupRequirementID,
        issue: SetupIssue?,
        conflictScanIncomplete: Bool
    ) -> SetupRequirementPresentation {
        guard let issue else {
            let content = satisfiedContent(for: id)
            return SetupRequirementPresentation(
                id: id,
                state: .satisfied,
                statusText: "已满足",
                title: content.title,
                detail: content.detail
            )
        }

        let content = actionRequiredContent(for: issue)
        let observedConflictCount: Int?
        if case let .conflictingDrivers(drivers) = issue {
            observedConflictCount = uniqueDriverCount(drivers)
        } else {
            observedConflictCount = nil
        }
        let detail = observedConflictCount != nil && conflictScanIncomplete
            ? content.detail + "此次扫描仍未完成。"
            : content.detail
        return SetupRequirementPresentation(
            id: id,
            state: .actionRequired,
            statusText: "待处理",
            title: content.title,
            detail: detail,
            observedConflictCount: observedConflictCount,
            conflictScanIncomplete: observedConflictCount != nil && conflictScanIncomplete
        )
    }

    private static func satisfiedContent(
        for id: SetupRequirementID
    ) -> (title: String, detail: String) {
        switch id {
        case .operatingSystem:
            ("macOS 15.4 或更高版本", "系统版本符合最低要求。")
        case .architecture:
            ("Apple Silicon", "处理器架构符合要求。")
        case .macFUSE:
            ("官方 macFUSE", "已安装受支持版本。")
        case .fileSystemExtension:
            ("File System Extension", "文件系统扩展已启用。")
        case .ntfs3G:
            ("受支持的 NTFS-3G", "已安装受支持版本。")
        case .backend:
            ("FSKit 安全后端", "正在使用唯一允许的用户态后端。")
        case .authorization:
            ("必要写入授权", "写入授权通道可用。")
        case .conflictingDrivers:
            ("批准范围内无冲突", "已完成批准范围内的检查，未发现冲突。")
        }
    }

    private static func actionRequiredContent(
        for issue: SetupIssue
    ) -> (title: String, detail: String) {
        switch issue {
        case let .unsupportedOperatingSystem(minimum, observed):
            return (
                "升级 macOS",
                "当前为 \(versionText(observed))，最低需要 \(versionText(minimum))；升级系统后重新检查。"
            )
        case let .unsupportedArchitecture(architecture):
            return (
                "需要 Apple Silicon",
                "当前架构为 \(architectureText(architecture))；这个个人版本不支持该 Mac。"
            )
        case .macFUSEMissing:
            return (
                "确认官方 macFUSE",
                "未能确认受信任的 macFUSE 版本。若尚未安装，请从官方来源安装；若已经安装，请重新检查或复制诊断摘要。"
            )
        case let .macFUSETooOld(minimum, observed):
            return (
                "更新官方 macFUSE",
                "当前为 \(versionText(observed))，最低需要 \(versionText(minimum))；更新后重新检查。"
            )
        case .fileSystemExtensionDisabled:
            return (
                "FSKit 扩展状态待确认",
                "只读检查无法确认扩展状态，这不等于扩展未启用。帮助程序会在卸载原生卷前复核；无法确认时保持只读挂载。"
            )
        case .ntfs3GMissing:
            return (
                "确认受支持的 NTFS-3G",
                "未能确认固定安全版本。若尚未安装，请使用受支持来源；若已经安装，请重新检查或复制诊断摘要。"
            )
        case let .ntfs3GTooOld(minimum, observed):
            return (
                "更新 NTFS-3G",
                "当前为 \(versionText(observed))，最低需要 \(versionText(minimum))；更新后重新检查。"
            )
        case let .unsafeBackend(backend):
            if backend == .unknown {
                return (
                    "确认 FSKit 后端",
                    "只读检查无法确认当前后端。帮助程序会在磁盘操作前核对固定的 FSKit 挂载方案。"
                )
            }
            return (
                "改用 FSKit 后端",
                "当前后端为 \(backendText(backend))；写入只允许使用 FSKit。"
            )
        case let .requiredAuthorizationUnavailable(status):
            switch status {
            case .granted:
                return ("重新检查必要授权", "授权事实不一致；请重新检查。")
            case .denied:
                return ("完成必要授权", "写入授权尚不可用；完成本机授权后重新检查。")
            case .unknown:
                return ("检查必要授权", "无法确认写入授权状态；请重新检查。")
            }
        case .conflictScanIncomplete:
            return (
                "重新检查冲突驱动",
                "未能完成冲突驱动扫描，当前无法确认无冲突；请检查后重新读取。"
            )
        case let .conflictingDrivers(drivers):
            let count = uniqueDriverCount(drivers)
            let countText = count == 0 ? "至少 1 个" : "\(count) 个"
            return (
                "停用冲突写入驱动",
                "检测到 \(countText)其他 NTFS 写入驱动；停用后重新检查。"
            )
        }
    }

    private static func versionText(_ version: SemanticVersion) -> String {
        "\(version.major).\(version.minor).\(version.patch)"
    }

    private static func architectureText(_ architecture: RuntimeArchitecture) -> String {
        switch architecture {
        case .appleSilicon:
            "Apple Silicon"
        case .intel:
            "Intel"
        case .unknown:
            "未知"
        }
    }

    private static func architectureRank(_ architecture: RuntimeArchitecture) -> Int {
        switch architecture {
        case .unknown:
            0
        case .intel:
            1
        case .appleSilicon:
            2
        }
    }

    private static func backendText(_ backend: ObservedMountBackend) -> String {
        switch backend {
        case .fsKit:
            "FSKit"
        case .kernelExtension:
            "内核扩展"
        case .unknown:
            "未知"
        }
    }

    private static func backendRank(_ backend: ObservedMountBackend) -> Int {
        switch backend {
        case .unknown:
            0
        case .kernelExtension:
            1
        case .fsKit:
            2
        }
    }

    private static func authorizationRank(_ status: SetupAuthorizationStatus) -> Int {
        switch status {
        case .unknown:
            0
        case .denied:
            1
        case .granted:
            2
        }
    }

    private static func uniqueDriverCount(_ drivers: [String]) -> Int {
        let normalized = drivers.compactMap { rawValue -> String? in
            let withoutControls = rawValue.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0)
            }
            let cleaned = String(String.UnicodeScalarView(withoutControls))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                return nil
            }
            let basename = cleaned
                .split(whereSeparator: { $0 == "/" || $0 == "\\" })
                .last
                .map(String.init) ?? cleaned
            let normalizedBasename = basename.lowercased()
            return normalizedBasename.isEmpty ? nil : normalizedBasename
        }
        return Set(normalized).count
    }
}
