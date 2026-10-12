# 完成 Gate 4 正式应用验收

Status: ready-for-human
Labels: enhancement, ready-for-human
Assignee:
Blocked-by: 04-gate3-windows-integrity

## 当前实现

正式 App 已按 ADR 0010/0011 通过 WriteSession 和签名 helper 接通写入与标准整盘释放。旧的“等待 Gate 后才能实现”和唯一采用 Core coordinator 接线的任务描述已被该决策替代，不能继续作为待开发缺口。

## 剩余验收

- Gate 1–3 的完整证据及当前构建对应关系。
- 当前目标实例、声明、结果未知和处理中状态的人工作用验证；不暴露旧目标操作。
- 320 pt、外观、真实键盘与 VoiceOver 验收见 Issue 13。
- 完整自动与严格 Release 检查；可写/可拔出结果必须有新鲜系统事实证明。

有限本机实盘闭环不自动关闭完整 Gate。
