# 删除平行且未接生产路径的 MediaGenerationTracker

Status: resolved
Labels: enhancement, resolved
Assignee:
Blocked-by:

## 问题

`NTFSLiteSystem` 公开了一个 `MediaGenerationTracker` actor，但生产观察链从未使用它；真实介质
代次由 `ReadOnlyDiskInventory` 维护。这个平行 public API 只有一条孤立 fixture，会让未来调用方误以为
存在两个有效的 generation source of truth。

## 验收

- 删除未被生产代码使用的公共 `MediaGenerationTracker`。
- 删除只验证该孤立类型的 fixture 与调用。
- 保留并运行真实 inventory 的 generation、重插、整盘消失、同盘共享代次与 rebuild fixtures。

## Resolution (2026-08-31)

- 已从 `NTFSLiteSystem` 删除平行 public tracker，并删除对应孤立 fixture。
- 仓库符号检查确认不再存在 `MediaGenerationTracker` 引用。
- `ReadOnlyDiskInventory` 相关代次 fixture 继续存在并随 `NTFSLiteCoreChecks` 构建和运行。

本改动只收敛 API 和测试来源，不改变当前磁盘观察行为，也未执行任何磁盘变更。
