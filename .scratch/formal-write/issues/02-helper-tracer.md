# SMAppService + XPC 签名可行性 tracer

Status: ready-for-agent
Labels: enhancement, ready-for-agent
Assignee:
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
