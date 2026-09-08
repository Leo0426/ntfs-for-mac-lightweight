# 证明完整观测覆盖范围

Status: resolved
Labels: bug, resolved
Assignee:
Blocked-by:

## 问题

Disk Arbitration 的短暂静默不能证明初始枚举已经覆盖所有磁盘。创建本 Issue 时，代码已把
静默收敛降级为 `enumerationCoverageUnverified`，但仍缺独立全量枚举与 mount table 稳定采样。

## 验收

- 独立只读全量来源能与事件流原子核对；未知或变化中保持 incomplete。
- mount table 只有在未截断且稳定采样一致时才作为完整事实。
- 不新增磁盘变更 API 或通用进程入口。

## 评论

2026-08-31：已修复无 BSD 身份事件、缺父盘子卷和静默即完整的问题。

## Resolution

2026-08-31：新增独立 IOKit `IOMedia` 精确枚举，只有连续稳定快照与 Disk Arbitration
集合完全一致时才升级覆盖范围；mount table 也只接受未截断且连续两次规范化记录完全一致
的快照。未知、超时、迭代器失效或变化中的结果继续失败关闭。完整 Release 行为检查与只读
边界检查已通过。本 Resolution 只关闭 Agent 代码范围，Issue 02 的外置盘实物 Gate 仍未完成。
