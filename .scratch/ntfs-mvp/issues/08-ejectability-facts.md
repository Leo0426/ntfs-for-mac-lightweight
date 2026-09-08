# 将物理盘可推出事实带入领域预检

Status: resolved
Labels: bug, resolved
Assignee:
Blocked-by:

## 问题

创建本 Issue 时，只读层读取 `isEjectable` 和 `isRemovable`，但领域快照没有保留，未来协调器
可能无法拒绝明确不可推出的外置设备。

## 验收

- 完整物理盘事实包含 ejectable/removable，缺失或矛盾时失败关闭。
- `safeEjectAvailability` 和最终预检均拒绝明确不可推出或未知的物理盘。
- 纯逻辑行为检查覆盖所有组合；不接真实推出执行。

## Resolution

2026-08-31：新增绑定 `DiskInstanceID` 的 `PhysicalDiskSafetySnapshot`，只读 inventory 只有在
ejectable/removable 完整且不矛盾时才交给协调器；未知、明确不可推出或代次不一致都会阻止
安全推出和最终预检。完整 Release 行为检查与只读边界检查已通过，未接入真实推出执行。
