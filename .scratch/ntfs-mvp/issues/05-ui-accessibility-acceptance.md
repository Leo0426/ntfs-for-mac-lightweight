# 补齐 C 版 UI 自动映射与可访问性检查

Status: resolved
Labels: enhancement, resolved
Assignee:
Blocked-by:

## 验收

- 自动检查覆盖只读壳和未来 `VolumePresentation` 的固定状态、主操作与禁用规则。
- 长卷名、多分区、连续刷新和选择项消失均有确定的展示映射，不依赖旧目标。
- 状态阶段、Setup 动作和复制/清除结果提供稳定文字与辅助功能标签/公告。
- 自动检查不能宣称 320 pt、深浅色、高对比、键盘或 VoiceOver 已经人工通过。

## 评论

2026-08-31：正式页已补物理盘分组、设备摘要、标题语义和 Setup 动作。人工视觉、键盘与
VoiceOver 证据已分流到 `13-ui-release-human-evidence`。

## Resolution

2026-08-31：已用公共展示接口的 Release 行为检查固定全部 24 个
`VolumeState` 的主/次动作、busy 禁用和同盘 busy 矩阵；固定长卷名、多分区的
分组与排序；验证连续扫描只保留选择身份、详情只解析当前 dashboard，稳定确认
消失后回到概览，不使用旧目标。Setup 的下一步/重新检查/结果与诊断的
复制/清除均使用 `NTFSLitePresentation` 中固定的可见文字和同值辅助功能公告。

本 Issue 只解决可重复自动验收，不宣称 320 pt、深浅色、高对比、键盘或 VoiceOver
已经人工通过；这些真实 UI 证据仍只由 Issue 13 验收。
