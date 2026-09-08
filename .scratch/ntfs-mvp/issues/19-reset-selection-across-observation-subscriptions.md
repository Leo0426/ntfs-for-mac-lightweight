# 在观察订阅切换时重置旧选择

Status: resolved
Labels: bug, resolved
Assignee:
Blocked-by:

## 问题

每次 `ReadOnlyAppStore.refresh()` 都会创建新的只读观察订阅和 inventory，而 inventory 的介质
代次从 1 重新计数。若替换介质复用相同 BSD 名、卷 UUID 和物理盘名，新订阅可能生成与旧订阅
完全相同的 `VolumeInstanceID`。仅按 dashboard 内是否仍存在该 ID 来协调选择，会把旧选择错误绑定
到替换介质。

同一订阅内的短暂 scanning 仍需保留选择身份，不能把每次临时空投影都当成介质替换。

## 验收

- 每次开始新的观察订阅都轮换一个 opaque、typed selection-reset epoch。
- `ReadOnlyAppStore.refresh()` 发布该 epoch；按钮刷新、通知刷新和睡醒路径均通过同一个方法轮换。
- View 发现 epoch 变化后回到概览，即使新 dashboard 具有相同 `VolumeInstanceID` 也不复用旧选择。
- 同一 epoch 内的 scanning dashboard 继续保留选择身份，详情只解析当前 dashboard。
- epoch 的底层值不显示、不进入诊断，也不持久化。
- 严格 Release CoreChecks、完整 warnings-as-errors Release 构建和只读边界检查通过。

## Resolution

2026-08-31：按公共展示接口完成 RED/GREEN。

- RED：新增 fixture，以相同 BSD 名、卷 UUID、物理盘名和 `MediaGeneration(1)` 构造跨订阅的
  同一 `VolumeInstanceID`；严格 Release 构建按预期因缺少 selection-reset epoch 和跨 epoch
  reconciliation 契约而失败。
- GREEN：`ReadOnlyObservationSession.beginRefresh()` 现在同时轮换 refresh token 和 opaque
  `ReadOnlySelectionResetEpoch`。Presentation 在 epoch 不同的情况下无条件返回概览；epoch 相同时
  继续使用原有稳定缺失规则，因此临时 scanning 保留选择。
- `ReadOnlyAppStore.refresh()` 每次发布新 epoch，`ReadOnlyMainWindow` 统一监听它并重置选择；手动
  刷新、通知刷新与 wake 后刷新没有独立旁路。
- epoch 只支持类型化相等比较，底层 UUID 为不可访问实现细节，未加入界面、诊断或持久化。
- 验证：严格 Release CoreChecks、完整 warnings-as-errors Release build 与
  `scripts/check-read-only-boundary.sh` 均通过；未执行任何真实磁盘变更。
