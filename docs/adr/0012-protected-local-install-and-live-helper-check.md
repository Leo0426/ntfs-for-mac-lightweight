---
status: accepted
---

# 首次安装使用受保护 pkg，并以实时 XPC 核验 helper

ADR 0011 固定了 helper 的启动位置，却只产出用户可写的 `.build/NTFSLite.app`。
`SMAppService.status == enabled` 只表示系统允许服务运行，不能证明当前 helper 可连接或其部署树仍可信。
用户希望在正式应用中完成启用流程，并在可牺牲介质上验证写入。

决定：本机首次安装由 macOS Installer 执行固定 payload 的 pkg，安装完整签名 App 到
`/Library/PrivilegedHelperTools/NTFSLite.app`。安装包不注册服务，也不执行任何磁盘操作；受保护
App 的 Setup 页面明确由用户点击注册 `SMAppService`，管理员在系统设置批准。App 仅在系统状态
为 `enabled` 且对固定签名 helper 的只读 XPC challenge 收到精确响应后开放磁盘操作按钮；
helper 每次仍按 ADR 0011 独立核对部署树、目标盘及变更条件。challenge 不接触磁盘，也不替代
任一磁盘安全证据。

安装包只处理首次安装；若受保护 App 已存在，安装前检查拒绝覆盖。更新运行中的 helper 或驱动
可能中断写入且留下未确认状态，因此更新、旧 v1 服务清理和卸载须另行设计，不能靠重复安装
此包完成。安装失败时保留原有状态；不得自动卸载、推出或删除用户卷内容。

本地 pkg 仅用 Apple Development 签名 App 构建，pkg 本身没有 Developer ID Installer 签名。
安装入口须先由 root 把 pkg 复制到普通用户不可写的暂存位置，再对**该副本**核验固定 payload、
安装脚本调用、BOM 与 App 签名；Installer 只能消费同一副本。验证用户可写 `.build` 路径后
直接打开包，会留下验证与安装之间的替换窗口。

## 依据和未验证项（2026-09-30）

- Apple 的 `SMAppService.daemon(plistName:)` 要求 plist 在 App 的
  `Contents/Library/LaunchDaemons`；当前 `BundleProgram` 指向包内 helper。
  [Apple API](https://developer.apple.com/documentation/servicemanagement/smappservice/daemon%28plistname%3A%29)、
  [Apple DTS 示例](https://developer.apple.com/forums/thread/802443)。
- 本机 Xcode SDK 27 的 `SMAppService.h` 写明：包含 LaunchDaemon 的 App 必须公证；App 建议
  位于 `/Applications`，且开机登录前可访问；修改 daemon/plist 后须重新注册，替换可执行文件
  建议先注销并等待异步完成。当前固定的 `/Library/PrivilegedHelperTools/NTFSLite.app` 是本项目
  选择的受保护路径，Apple 未明确保证该位置可注册，必须在现机实证。
  [Apple DTS 对重新注册的说明](https://developer.apple.com/forums/thread/783539)、
  [Apple 安装包示例](https://developer.apple.com/documentation/ServiceManagement/updating-your-app-package-installer-to-use-the-new-service-management-api)。
- 本机仅有 Apple Development 代码签名身份，未有 Developer ID Application/Installer。
  2026-09-29 旧 tracer 在 macOS 27.0 上用 Apple Development 成功完成注册、批准、root XPC
  和注销，但那不是当前受保护路径与当前 App 的验收，也不证明可公证或可分发。
  外部分发须另行完成 Developer ID、Hardened Runtime、公证及目标系统验证。
  [Apple 证书说明](https://developer.apple.com/help/account/certificates/certificates-overview)、
  [Apple 公证说明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。
- 2026-09-30 本机首次安装成功，安装后的固定路径、root:wheel、权限、ACL、完整文件清单与
  签名检查通过。已安装 App 的“运行环境”显示“帮助程序连接或状态无法确认”，没有注册按钮；
  系统后台任务记录和 launchd 都没有 v2 服务，日志报告 v2 `record not found`。Apple 将
  `SMAppService.Status.notFound` 定义为框架找不到服务的错误；仅凭界面不能最终断言状态枚举，
  已在代码中为此状态设计显式诊断和由用户触发的注册尝试，注册结果仍待实测。
  [Apple 状态定义](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum)。
- 本机安装件是 `0.1.0 (1)`；修复构建提升至 `0.1.1 (2)`。首次安装包仍拒绝覆盖旧件，
  因此在尝试注册前须走独立的受保护更新与新旧文件摘要复核，不能以版本号或安装命令成功
  代替后验。Apple 建议通过 Installer 更新签名代码，避免原位写入旧可执行文件。
  [Apple 更新指南](https://developer.apple.com/documentation/security/updating-mac-software)。
- 本机旧 v1 daemon 在系统后台任务记录中仍为 `enabled, allowed`，虽然当前 launchd system 域
  找不到 v1/v2 服务且没有观察到 helper 进程。瞬时未运行不能证明旧服务已注销，故现在不能
  安全覆盖受保护 App。更新前须由受信组件注销旧 v1 并等待系统完成，确认不再有活动 helper、
  未完成写入会话及不可解释的后台任务状态；若任何事实未知则停止。对已注册 daemon 的代码
  变更也须先注销，不能仅替换文件。
  [Apple DTS 对注销与更新的说明](https://developer.apple.com/forums/thread/783539)。
- 尚须实测当前 App 的 `SMAppService` 注册结果、管理员批准、root helper 启动和 XPC 连接；
  可牺牲盘上的写入、删除、标准整盘推出及 Windows 复核分别记录。
  ADR 0011 的快速拔插 BSD 名复用竞态、跨 Team FSKit 可见性及重启后会话恢复仍未解决。

## 其他方案

- 从 App 中以 `Process`、shell 或提权复制 `.build` 包：违反 App 的固定探针与特权边界。
- 直接安装 launchd plist：绕过当前 `SMAppService` 的用户批准与 bundle 管理模型。
- 把 `.build` 目录放宽为可执行 helper：普通用户可替换代码，不可接受。
