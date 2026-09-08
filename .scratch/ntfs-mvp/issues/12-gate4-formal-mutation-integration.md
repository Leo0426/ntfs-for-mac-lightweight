# 完成 Gate 4 正式变更集成

Status: ready-for-agent
Labels: enhancement, ready-for-agent
Assignee:
Blocked-by: 04-gate3-windows-integrity, 05-ui-accessibility-acceptance, 10-mount-engine-contract, 11-exact-macfuse-trust-policy, 15-macfuse-signing-evidence-policy, 17-current-connection-data-declaration, 18-candidate-scoped-conflict-footprint-probe

## 问题

正式 App 当前只消费只读 dashboard。实施计划要求 Gate 1–3 全部通过后，才允许把 observer、
`VolumeCoordinator`、`MountEngine` 和只消费 `VolumePresentation` 的 C 版 UI 接起来。

## 验收

- Gate 1–3 的 Evidence-ID 均已通过且依赖/执行器未发生漂移后才开始实现。
- observer 把 unknown-role 外置 NTFS 只交给只读 candidate presenter；candidate 永不直接进入
  协调器。写入入口必须把当前连接固定声明与 fresh candidate、完整 sibling/系统事实分别核对，
  不能把声明升格成 `VolumeSnapshot` 或 System Evidence。
- 正式 mutation UI 只消费 `VolumePresentation`；只读部分继续消费
  `ReadOnlyDashboardPresentation`。用户动作携带完整 `VolumeInstanceID`，只能提交固定声明，
  不生成操作 ID、System Evidence、命令、路径或挂载参数。
- `MountEngine` 只能从协调器的一次性执行边界调用；超时、取消和介质事件继续持有 Whole-Disk Lease，
  直到进程 quiescence 与新的完整系统证据完成收敛。
- “已验证可写”和“已验证可以拔出”只来自系统事实复核；正式构建不包含原型切换器。
- 重新运行全部自动检查、严格 Release 构建和只读/变更依赖边界检查。

## 评论

本 Issue 虽由 Agent 实现，但当前被 Gate 1–3 阻塞，不能提前领取，也不能在用户数据盘试验。
