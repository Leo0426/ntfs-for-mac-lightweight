# 区分跨物理盘同名卷的辅助功能选择标签

Status: resolved
Labels: bug, resolved
Assignee: Codex
Blocked-by:

## 问题

Issue 25 已保证同一物理盘内的卷标题唯一，但两块不同物理盘仍可以各自包含一个同名卷。宽版
侧栏视觉上由“物理磁盘 N”分组，按钮本身却只使用卷标题；不能静态保证 VoiceOver 在进入按钮时
一定重复朗读分组标题。窄版 Picker 已显示物理盘文字，但没有与侧栏共享固定的辅助功能标签契约。

## 验收

- 展示层通过公共接口从完整 dashboard 和 selection 生成固定选择标签。
- 卷选择标签按“物理磁盘 N，卷标题”组织；不同物理盘上的同名卷得到不同标签。
- 概览、运行环境与诊断摘要保持固定文字；失效卷选择沿用现有概览回落语义。
- 宽版侧栏按钮和窄版 Picker 的卷选项统一消费该接口。
- 标签只包含隐私安全的展示标题，不包含 UUID、BSD 名、路径或持久身份。
- 严格 Release、正式 App 构建、只读边界和本地验包通过。
- 自动检查不能宣称真实 VoiceOver 分组、焦点或阅读顺序已经人工通过。

## 评论

2026-08-31：Issue 25 独立复核留下该非阻断项。RED 编译检查证明展示层尚无统一选择标签接口。

## Resolution

2026-08-31：新增 `ReadOnlyAccessibilityPresenter.selectionLabel`，只通过当前 dashboard 的公共
展示模型解析 selection。卷标签固定为“物理磁盘 N，卷标题”，概览、运行环境和诊断摘要使用
固定文字，失效卷选择沿用现有“概览”回落。宽版侧栏把标签施加到完整 Button，窄版 Picker
把同一标签施加到带 selection tag 的卷选项 Text。

行为检查覆盖两块物理盘上的同名卷、UUID/BSD poison、三个固定非卷标签和失效选择回落。
独立静态审计确认接线、确定性和隐私边界均无 blocker；仓库没有 Git 元数据，因此该结论是
Issue 验收范围内的当前代码切片审计，不是 diff review。真实 Picker→NSMenu、焦点和 VoiceOver
阅读顺序仍只由 Issue 13 人工验收。

严格 Release CoreChecks、完整 warnings-as-errors 构建、只读源码/依赖边界、本地 App 正向验包
和 5 组篡改包负向 fixture 全部通过。本地 ad-hoc App 版本为 `0.1.0 (1)`，主程序 SHA-256 为
`fefc192ee0c3013112000ada9167ab9826765ac78d5db3fc50294eea9782840d`；它不构成 Developer ID、
公证、Gate 5 或人工 UI 证据。全程未执行挂载、卸载、推出、修复、格式化或写盘。
