# UI：启用写入与安全推出

Status: ready-for-agent
Labels: enhancement, ready-for-agent
Assignee:
Blocked-by: 06

## 范围

详情页按钮“启用写入”“安全推出”，仅在 `VolumePresentation` 允许时可用；启用写入先弹出数据卷
声明确认（说明风险与验证边界）；进行中、成功、失败、需要重新读取的状态文字与辅助功能公告；
菜单栏入口同步。

## 验收

- 展示映射行为检查覆盖全部相关 `VolumeState`；按钮不可用时给出原因。
- 键盘、VoiceOver 标签与深浅色可用（人工项另记）。
