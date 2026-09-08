# 展示角色未知的外置 NTFS 只读候选

Status: resolved
Labels: bug, resolved
Assignee:
Blocked-by:

## 问题

生产 Disk Arbitration 路径正确地把外置 NTFS 角色保留为 unknown，但当前 presenter 只消费
`VolumeSnapshot`，导致正式只读 C 版界面连安全的观察结果也不显示。可见性与变更资格必须拆开。

## 验收

- System mapper 只在卷身份、父盘、介质代次、文件系统、位置和挂载事实均完整，且唯一角色问题
  为 `unknownVolumeRole` 时生成独立 `ReadOnlyVolumeCandidate`。
- candidate 不是 `VolumeSnapshot`，不能进入 `coordinatorInventory`，也不能提供写入或整盘推出。
- 正式 read-only presenter 显示 candidate 的卷名、只读/可写/未挂载事实和“用途未确认”说明；
  不从 raw evidence 在 Presentation 层重建身份。
- 其他缺失、矛盾、重复、路径不可信或 mount table 不稳定的记录仍不生成 candidate。
- fixture 覆盖 unknown 外置 NTFS 可见但零 mutation 资格、可信 snapshot 正常显示、错误事实不可见、
  重插/选择消失不绑定旧候选。
- 不执行任何真实磁盘变更。

## 评论

角色授权由 ADR 0005 和 Issue 17 单独处理；本 Issue 只恢复安全的只读可见性。

## Resolution

2026-08-31 已按 ADR 0005 完成：

- Core 新增与 `VolumeSnapshot` 分离的 `ReadOnlyVolumeCandidate`，只携带当前连接已核对的
  身份、父盘、介质代次、NTFS、外置位置和挂载访问事实，不携带角色或任何变更能力。
- System mapper 仅在唯一问题为 `unknownVolumeRole` 时生成 candidate；父子位置冲突、整盘身份
  冲突、枚举覆盖不完整、未解析 sibling 拓扑、mount table 不稳定及其他额外事实错误都会移除它。
- 正式 read-only dashboard 展示 candidate 及“用途未确认”；已有可写挂载只标为
  “已有可写挂载、未验证”。candidate 始终不能进入 `coordinatorInventory`，且
  `writeControlsAvailable` 始终为 `false`。
- 测试覆盖 candidate 可见但零 mutation 资格、可信 snapshot、错误事实、重插后的旧选择失效，
  并以 RED/GREEN 验证各失败关闭条件。
- Issue 17 的当前连接数据卷声明未在本 Issue 实现；未执行任何真实磁盘变更。
