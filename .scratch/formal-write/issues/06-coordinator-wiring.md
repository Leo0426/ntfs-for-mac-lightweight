# 写入会话接线（ADR 0011）

Status: resolved
Labels: enhancement, resolved
Assignee: Claude
Blocked-by: 05

## 范围

按 ADR 0011：`NTFSLiteWriteSession` 轻量写入会话（每盘互斥、显式确认、一次性 operation ID、
固定动作、超时/断线视为状态未知不重发），App Store 在操作结束后重新观察系统。Core
`VolumeCoordinator` 多步工作流暂不接入。

## 验收

- 行为检查：未确认拒绝；同盘互斥；超时/断线为状态未知；结果码映射为固定文字；结束后请求重新观察。
- App 依赖边界检查通过。

## Resolution

2026-09-29：按 ADR 0011 新增 `NTFSLiteWriteSession`：未确认拒绝、同盘互斥、每次新 operation ID、
仅固定动作、超时/断线/无效响应为状态未知不重发、`executionFailed` 与 `postconditionFailed` 分别映射为
“未更改”与“需重新读取”，结果码映射为固定中文说明。行为检查先红后绿。操作结束后 Store 重新观察。
