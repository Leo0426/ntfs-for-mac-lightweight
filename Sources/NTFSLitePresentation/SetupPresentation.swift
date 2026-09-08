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

public struct SetupRequirementPresentation: Equatable, Sendable {
    public let id: SetupRequirementID
    public let state: SetupRequirementState
    public let statusText: String
    public let title: String
    public let detail: String

    init(
        id: SetupRequirementID,
        state: SetupRequirementState,
        statusText: String,
        title: String,
        detail: String
    ) {
        self.id = id
        self.state = state
        self.statusText = statusText
        self.title = title
        self.detail = detail
    }
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
                title: "正在检查运行环境",
                detail: "正在重新读取系统、依赖和后端状态；完成前写入保持关闭。",
                requirements: requirementOrder.map(checkingRequirement),
                primaryAction: nil,
                secondaryActions: [],
                isReady: false,
                isBusy: true
            )
        }

        let issuesByRequirement = normalizedIssues(assessment.issues)
        let requirements = requirementOrder.map { id in
            requirement(id: id, issue: issuesByRequirement[id])
        }

        if assessment.isReady {
            return SetupPresentation(
                title: "首次设置已完成",
                detail: "运行环境符合当前安全要求；写入操作仍会在每次执行前重新检查。",
                requirements: requirements,
                primaryAction: .recheck,
                secondaryActions: [],
                isReady: true,
                isBusy: false
            )
        }

        return SetupPresentation(
            title: "首次设置未完成",
            detail: "有 \(issuesByRequirement.count) 项需要处理；完成后重新检查，在此之前写入保持关闭。",
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
        return SetupPresentation(
            title: base.title,
            detail: base.detail,
            requirements: requirements,
            primaryAction: base.primaryAction,
            secondaryActions: base.secondaryActions,
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
                statusText: "待处理",
                title: "配置 macFUSE 信任策略",
                detail: "此构建尚未配置受信任校验策略，不能据此判断为未安装；写入保持关闭。"
            )
        case let .failedClosed(failure):
            return SetupRequirementPresentation(
                id: .macFUSE,
                state: .actionRequired,
                statusText: "待处理",
                title: "macFUSE 可信校验未通过",
                detail: "固定失败码 \(macFUSEFailureCode(failure))。请核对批准策略、安装来源和文件权限；写入保持关闭。"
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
                statusText: "待处理",
                title: "配置 NTFS-3G 信任策略",
                detail: "此构建尚未配置受信任校验策略，不能据此判断为未安装；写入保持关闭。"
            )
        case let .failedClosed(failure):
            return SetupRequirementPresentation(
                id: .ntfs3G,
                state: .actionRequired,
                statusText: "待处理",
                title: "NTFS-3G 可信校验未通过",
                detail: "固定失败码 \(ntfs3GFailureCode(failure))。请核对批准目录、制品来源和文件权限；写入保持关闭。"
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
        case (.conflictScanIncomplete, _), (_, .conflictScanIncomplete):
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
        issue: SetupIssue?
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
        return SetupRequirementPresentation(
            id: id,
            state: .actionRequired,
            statusText: "待处理",
            title: content.title,
            detail: content.detail
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
                "启用 File System Extension",
                "扩展尚未启用；在系统设置中允许后重新检查。"
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
            return (
                "改用 FSKit 后端",
                "当前后端为 \(backendText(backend))；写入只允许使用 FSKit。"
            )
        case let .requiredAuthorizationUnavailable(status):
            switch status {
            case .granted:
                return ("重新检查必要授权", "授权事实不一致；写入保持关闭，请重新检查。")
            case .denied:
                return ("完成必要授权", "写入授权尚不可用；完成本机授权后重新检查。")
            case .unknown:
                return ("检查必要授权", "无法确认写入授权状态；确认前写入保持关闭。")
            }
        case .conflictScanIncomplete:
            return (
                "重新检查冲突驱动",
                "未能完成冲突驱动扫描；确认没有其他 NTFS 写入驱动前保持只读。"
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
