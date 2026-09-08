# 固定选择暂存与导航焦点回落契约

Status: resolved
Labels: bug, resolved
Assignee: Codex
Blocked-by:

## 问题

现有选择协调会在同一 observation subscription 的 scanning 阶段保留暂时缺失的卷身份，但
SwiftUI 的 Picker、侧栏和详情共用这一个 binding。卷控件被条件分支移除、stable absence、
selection-reset epoch 变化或窗口跨过 560 pt 布局阈值时，当前展示项和键盘焦点缺少显式契约。
这可能让 Picker 绑定不存在的 tag，或把焦点交给框架隐式猜测。

## 验收

- 展示层明确区分 retained selection 与必须存在于当前 dashboard 的 presented selection。
- 同 epoch scanning 缺失卷时 retained 保持原卷，presented 回概览；卷仍存在时二者均保持原卷。
- stable/limited 缺失与 selection-reset epoch 变化都清除 retained；即使新 dashboard 复用相同
  `VolumeInstanceID` 也回概览。
- 宽版已聚焦的任意失效卷项回到当前 presented selection；窄版 Picker 在选择回落时保持焦点。
- wide/compact 只在导航区原本持有焦点时转移焦点；nil 或导航区外焦点不被抢夺。
- scanning 后卷重新出现时恢复展示选择，但不从概览主动抢回焦点。
- epoch→dashboard、dashboard→epoch 两种回调顺序及非选中卷焦点失效都有自动回归检查。
- 严格 Release、正式 App 构建、只读边界和本地验包通过；不执行磁盘变更。
- 自动契约不替代真实 Tab、Shift-Tab、Return、Space、焦点环和 VoiceOver 人工验收。

## 评论

2026-08-31：RED 编译检查先证明展示层没有 presented-selection 接口；第二轮 RED 证明没有
结构化导航布局/焦点协调接口。后续反例又发现“焦点位于未选中卷 B，而 B 从 dashboard 消失”
必须按焦点项自身是否存在判断，不能只比较当前 selection。

## Resolution

2026-08-31：新增 `ReadOnlySelectionPresenter.presentedSelection`，保留现有
`reconciledSelection` 负责 retained selection 的生命周期；当前 dashboard 缺少保留卷时只把
presented selection 回落到概览。正式 SwiftUI 的 Picker、侧栏、详情、选择状态和辅助功能公告
统一消费 presented selection，因此 scanning 可以记住卷身份而不再绑定不存在的控件。

新增结构化 `ReadOnlyNavigationLayout`、`ReadOnlyNavigationFocus` 与纯
`ReadOnlyNavigationFocusPresenter`。宽版焦点项不存在时回到当前展示项；compact Picker 在选择
回落时保持焦点；wide/compact 仅转移既有导航焦点，nil 或导航区外焦点不被抢夺。行为检查覆盖
临时/稳定缺项、仍存在卷、非选中焦点卷消失、返回卷不抢焦点、双向布局切换、epoch 与 dashboard
两种回调顺序，以及新订阅复用同一卷 ID 的 selection/focus 回落。

独立当前状态审计确认上述回调顺序均收敛且源码 blocker 为 0；仓库无 Git 元数据，因此这不是
diff review。SwiftUI 条件分支拆装时的真实 FocusState 提交顺序、Tab/Shift-Tab、Return、Space、
焦点环和 VoiceOver 光标继续由 Issue 13 人工验收，不能由纯逻辑检查关闭。

严格 Release CoreChecks、完整 warnings-as-errors 构建、只读源码/依赖边界、本地 App 正向验包
和 5 组篡改包负向 fixture 全部通过。本地 ad-hoc App 版本为 `0.1.0 (1)`，主程序 SHA-256 为
`2d1443965fbe5fa5bb4b1531b83c4e148bfe63452e4d0df4095de3784272772e`，Info.plist SHA-256 为
`e07cb1b851df777828f55717fd6cee87110a36bd6b95ee108c7c72428894fc6f`；它不构成 Developer ID、
公证、Gate 5 或人工 UI 证据。全程未执行挂载、卸载、推出、修复、格式化或写盘。
