---
status: accepted
---

# 由 helper 原子执行“启用写入”，App 以轻量写入会话接线

ADR 0010 接入写入能力时发现：Core `VolumeCoordinator` 的启用写入是多步流程（App 请求卸载 →
App 读取含健康状态的安全快照 → App 请求可写挂载）。健康检查需要以 root 读取原始设备，App 进程
无法取得，该流程无法在正式应用中推进。helper 的 `mountReadWrite` 已在 root 下原子完成身份核对、
启动扇区绑定、原生卸载、no-recovery 健康检查、驱动启动与 FSKit 挂载核验，并已在可牺牲 U 盘上
验证（2026-09-29，issue 03/04）。

决定：正式应用通过 `NTFSLiteWriteSession` 轻量写入会话接线——每块物理盘同一时刻一个操作、用户
显式确认后才发起、每次请求新的一次性 operation ID、只发送 ADR 0002 固定动作、超时/断线/无效响应
视为状态未知且不重发、结束后重新观察系统。“安全推出”依次请求 `unmountDisk` 与 `ejectDisk`。
Core `VolumeCoordinator` 的多步写入工作流暂不接入正式应用。

## Considered Options

- 为 helper 增加“健康检查”动作以满足 Core 多步流程：拒绝。ADR 0002 只允许四种固定变更动作，
  且拆分会在卸载与挂载之间留下由 App 协调的窗口。
- 让 App 以 root 读取设备：拒绝，违背最小权限与 helper 边界。
- 轻量写入会话 + helper 原子执行：采用。安全核对集中在 root helper，一次请求内完成且可验证。

## Consequences

- App 不能在请求之间“缓存”资格；helper 每次重新读取全部系统事实，App 侧的判断只决定按钮是否可用。
- 可写状态在 App 内按本次会话记录；App 重启后可写 FSKit 挂载仍可通过“安全推出”由 helper 按
  驱动持有关系识别并释放，但界面不能直接把占位来源映射回卷，需要后续改进。
- Core 多步工作流与其行为检查保留，未来若 helper 协议演进可重新评估。
