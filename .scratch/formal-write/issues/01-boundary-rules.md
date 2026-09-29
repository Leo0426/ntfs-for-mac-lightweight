# 规则与依赖边界更新

Status: ready-for-agent
Labels: enhancement, ready-for-agent
Assignee:
Blocked-by:

## 范围

按 ADR 0010 更新实施计划与只读边界检查：正式 App 可依赖 `NTFSLiteHelperProtocol`、
`NTFSLiteMutationPreparation`；新增 helper 可执行 target 作为独立 root。App 进程仍不得新增
`Process` 或磁盘变更 API，特权执行只在 helper 内。

## 验收

- `scripts/check-read-only-boundary.sh` 与 `verify-read-only-package-boundary.swift` 改为核对
  新允许集合；负向用例仍拒绝 App 直接依赖证据工具链或在 App 源码中调用变更 API。
- 实施计划记录 ADR 0010 取代“Gate 前不加写入按钮”，Gate 状态文字不变。
- 严格 Release 与现有检查通过。
