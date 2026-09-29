# 写入会话接线（ADR 0011）

Status: ready-for-agent
Labels: enhancement, ready-for-agent
Assignee:
Blocked-by: 05

## 范围

按 ADR 0011：`NTFSLiteWriteSession` 轻量写入会话（每盘互斥、显式确认、一次性 operation ID、
固定动作、超时/断线视为状态未知不重发），App Store 在操作结束后重新观察系统。Core
`VolumeCoordinator` 多步工作流暂不接入。

## 验收

- 行为检查：未确认拒绝；同盘互斥；超时/断线为状态未知；结果码映射为固定文字；结束后请求重新观察。
- App 依赖边界检查通过。
