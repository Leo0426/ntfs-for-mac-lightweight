/// Presentation state for the protected helper. Only a successful signed XPC health check
/// can set `enabled`; a system registration status alone never grants disk operations.
public enum HelperServiceState: Equatable, Sendable {
    case enabled
    case checkingConnection
    case requiresApproval
    case notRegistered
    case notFound
    case requiresProtectedInstallation
    case unavailable

    public var canAttemptRegistration: Bool {
        self == .notRegistered || self == .notFound
    }

    public var text: String {
        switch self {
        case .enabled: "帮助程序已启用，签名 XPC 连接已验证。磁盘写入仍需逐次安全核对。"
        case .checkingConnection: "系统已批准帮助程序，正在验证签名 XPC 连接。"
        case .requiresApproval: "帮助程序等待批准：请在“系统设置 → 通用 → 登录项与扩展”中允许。"
        case .notRegistered: "帮助程序尚未启用。启用后可由它执行固定的挂载与推出操作。"
        case .notFound: "系统未找到帮助程序服务（SMAppService: notFound）。可以尝试注册；当前不提供磁盘操作。"
        case .requiresProtectedInstallation: "当前应用未从受保护位置启动。请先安装本机安装包，再打开已安装的应用启用帮助程序。"
        case .unavailable: "帮助程序连接或状态无法确认，当前不提供磁盘操作。请重新检查。"
        }
    }
}

public enum HelperRegistrationDiagnostic {
    public static func suffix(domain: String, code: Int) -> String {
        let bytes = domain.utf8
        let safeDomain = !bytes.isEmpty && bytes.count <= 96 && bytes.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte)
                || (48...57).contains(byte) || byte == 46 || byte == 45 || byte == 95
        } ? domain : "unknown"
        return "（错误域：\(safeDomain)，代码：\(code)）"
    }
}
