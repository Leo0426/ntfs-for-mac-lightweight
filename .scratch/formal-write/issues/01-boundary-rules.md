# 规则与依赖边界更新

Status: resolved
Labels: enhancement, resolved
Assignee: Claude
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

## Resolution

2026-09-29：先加 3 个边界样例（展示层/系统层进入 mutation 应被拒绝、正式应用接入 helper 应被允许），
RED 复现旧规则只以 App 为根而给出错误原因；GREEN 把 mutation-free 根改为 Gate 证据工具链与
Core/System/Presentation/Diagnostics，App 作为组合根放行。源码扫描拆为两层：禁用策略
（remove_hiberfile、allow_other、kext、recover、强制卸载/推出）在全部产品源码禁止；真实磁盘变更
API 仅允许 `Sources/NTFSLiteHelper`。手动注入违规文件确认两条扫描分别失败关闭、helper 内
`posix_spawn` 放行。实施计划三处与 ADR 0010 冲突的约束已更新，Gate 状态不变。
`scripts/check.sh` 通过。
