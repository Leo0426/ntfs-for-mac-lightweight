# App：helper 状态进入 Setup，XPC 作为 MountEngine executor

Status: resolved
Labels: enhancement, resolved
Assignee: Claude
Blocked-by: 02

## 范围

App 端：`SMAppService` 状态（未注册/需批准/已启用/不可用）映射为 Setup 条件与下一步动作；
XPC 客户端实现 `MountEngineAdapter.Executor`，把已领取的 `MutationCommand` 经
`HelperRequestCompiler` 编码发送，结果映射为 `MountEngineTermination`。连接中断、超时视为
“终止未确认”，不重发。生产可信策略（macFUSE 身份、驱动摘要）固定到 ADR 0010 的版本。

## 验收

- Setup 行为检查覆盖 helper 各状态；断线/超时/重放拒绝映射正确。
- Setup 在本机实际显示 Ready（依赖、helper、授权均满足时）。

## Resolution

2026-09-29：App 端 `HelperXPCTransport`（固定 mach service、helper 签名要求；连接无法建立为“未送达”，
送达后中断或 180 秒超时为“结果未知”）与 `WriteController`（`SMAppService` 状态映射为已启用/等待批准/
未安装/不可用，“安装帮助程序”注册并打开登录项设置）。Setup 生产策略未改动：写入入口以 helper
状态为准，helper 每次请求重新核验依赖签名与系统事实（ADR 0011）。
