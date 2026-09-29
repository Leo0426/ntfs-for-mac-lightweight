# SMAppService + XPC 签名可行性 tracer

Status: resolved
Labels: enhancement, resolved
Assignee: Claude
Blocked-by: 01

## 范围

最小纵向切片：App 注册 `SMAppService.daemon`，用户在系统设置批准后，App 经 NSXPCConnection
向 helper 发送一个 ADR 0002 协议的探测请求（不执行任何磁盘动作），helper 以 root 返回固定
结果码。双方设置代码签名要求（同 Team ID、固定 bundle identifier）。使用本机 Apple Development
证书签名。

## 验收

- 本机实证：注册、批准、连接、请求、响应、注销全流程；记录系统设置中的显示与状态值。
- 非本 Team 签名的客户端连接被 helper 拒绝（本机复现或以替身二进制验证）。
- 一手来源记录 `SMAppService` / XPC 代码签名要求 API 与日期；未验证项写明。
- 失败时（例如 Development 签名不被接受）记录现象并在 MAP 中提出替代方案，不降低安全要求。

## Resolution

2026-09-29：`HelperRequestProcessor` 与 `HelperServiceIdentity` 先写行为检查（RED：类型不存在；随后
发现共享 `processLifetime` 准入已被容量检查填满，改为包内 `isolatedForChecks()` 注入）后转绿。
新增 `NTFSLiteHelper`（root daemon：NSXPCListener + `setConnectionCodeSigningRequirement`，未接执行器，
已准入请求固定返回 `executionFailed`）、临时 `NTFSLiteHelperTracer` 与
`AppResources/com.leolu.ntfslite.helper.plist`（Label/BundleProgram/MachServices/AssociatedBundleIdentifiers）。
`scripts/build-helper-tracer-app.sh` 以本机 Apple Development 身份（Team `NP3U2GYHWL`）签名，Hardened Runtime。

本机实证（macOS 27.0）：`register` → `requiresApproval`，自动打开登录项设置；用户批准后 `enabled`，
helper 以 root 运行；首个请求 `resultCode 20`，重放 `resultCode 14`；ad-hoc 签名与同 Team 不同标识符的
替身客户端均被断开（NSXPC 4097）；`unregister` → `notRegistered`，helper 停止。Apple Development
证书足以在本机注册与运行，分发仍需 Developer ID 与公证。

一手来源（2026-09-29 查阅）：Apple 文档 `SMAppService.daemon(plistName:)`（plist 位于
`Contents/Library/LaunchDaemons`，macOS 13+）与 `NSXPCListener.setConnectionCodeSigningRequirement(_:)`
（macOS 13+）。未验证：App 移动路径后的 BTM 记录迁移、系统升级后的批准保留。
