# Closure mutation adapter 必须返回显式 termination

Status: resolved
Labels: bug, resolved
Assignee:
Blocked-by:

## 问题

`VolumeCoordinator.executeMutation(... invoke:)` 的 closure 过去返回 `Void`，协调器会在 closure
返回后无条件把底层 mutation 当作已经确认静止。调用方即使产生了
`MountEngineTermination.terminationUnconfirmed`，也可能因为返回值被 Void 上下文丢弃而错误打开
quiescence callback gate。

## 验收

- closure adapter 必须返回 typed `MountEngineTermination`，不能由 `Void` 自动推断静止。
- 协调器只根据 `hasConfirmedQuiescence` 结算 invocation。
- `MountEngine` typed overload 及其完整 result/fresh-evidence 契约保持不变。
- confirmed cancellation 只能进入 fresh reconciliation；unknown termination 必须拒绝 quiescence
  callback，并且两者都不能直接释放 Whole-Disk Lease 或允许 sibling mutation 重入。

## Resolution (2026-08-31)

- closure adapter 现在强制返回 `MountEngineTermination`，所有既有 fixture 都显式返回真实的
  termination 语义。
- `settleMutationInvocation` 只接收 termination 的 `hasConfirmedQuiescence`，不再存在
  “closure 返回即等于静止”的捷径。
- 公共行为 fixture 覆盖 `.cancelledAfterConfirmedQuiescence` 和 `.terminationUnconfirmed`：前者只
  进入 fresh reconciliation，后者继续关闭 callback gate；两者都保持同盘 mutation 不可重入。

验证只使用纯逻辑 coordinator fixture，没有连接 helper、执行系统命令或改变磁盘状态。
