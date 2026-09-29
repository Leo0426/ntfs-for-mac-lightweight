# App：helper 状态进入 Setup，XPC 作为 MountEngine executor

Status: ready-for-agent
Labels: enhancement, ready-for-agent
Assignee:
Blocked-by: 02

## 范围

App 端：`SMAppService` 状态（未注册/需批准/已启用/不可用）映射为 Setup 条件与下一步动作；
XPC 客户端实现 `MountEngineAdapter.Executor`，把已领取的 `MutationCommand` 经
`HelperRequestCompiler` 编码发送，结果映射为 `MountEngineTermination`。连接中断、超时视为
“终止未确认”，不重发。生产可信策略（macFUSE 身份、驱动摘要）固定到 ADR 0010 的版本。

## 验收

- Setup 行为检查覆盖 helper 各状态；断线/超时/重放拒绝映射正确。
- Setup 在本机实际显示 Ready（依赖、helper、授权均满足时）。
