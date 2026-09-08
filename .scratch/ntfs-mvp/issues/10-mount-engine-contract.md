# 定义不执行真实磁盘变更的 MountEngine 契约

Status: resolved
Labels: enhancement, resolved
Assignee:
Blocked-by:

## 问题

PRD 把 `MountEngine` 定义为隐藏 NTFS-3G、macFUSE 和挂载参数的深模块，但当前只有协调器的
受限执行闭包，没有可独立验证的命名契约。真实执行不应与 Gate 2 的外部证据混在一个任务里。

## 验收

- 契约只接受协调器已领取的固定语义 mutation 和完整卷/物理盘实例，不接受 shell、路径或参数文本。
- 结果区分直接进程退出、超时/取消后的 quiescence、终止未确认和需重新读取的系统证据。
- fake engine 证明一次性调用、旧实例/重放拒绝以及只有新 Complete Observation 能确认最终状态。
- 不新增 `Process`、XPC、helper 安装或任何真实 mount、unmount、eject 调用。
- 真实 adapter、FD-bound 启动与一次性镜像验证继续由 Issue 03 阻塞。

## Resolution

- `NTFSLiteCore` 已加入 package-only `MountEngine`；唯一输入为包含完整实例的四种
  `MutationCommand`，不提供命令文本、路径或参数入口。
- `MountEngineResult` 明确携带直接退出、超时后已确认静止、取消后已确认静止或终止未确认，
  并由命令类型固定推导 fresh volume / whole-disk evidence requirement。
- `VolumeCoordinator` 的 engine 入口复用原最终预检与一次性领取；本 Issue 完成时兼容闭包入口
  曾保持不变，后续已由 Issue 20 收紧为必须显式返回 `MountEngineTermination`，不再由
  `Void` 推断 quiescence。fake engine 已覆盖精确当前 effect 单次执行、旧实例/旧 operation/replay
  零额外调用。
- termination unconfirmed 保留正在执行标记与 Whole-Disk Lease；成功、失败或静止回调不能绕过，
  inventory rebuild 与同盘新变更继续被拒绝。
- 完整 Debug/Release 行为检查、只读边界检查与 warnings-as-errors Release 构建通过。

真实 adapter、FD-bound 启动、helper IPC/安装和磁盘镜像证据均未实现，继续由 Issue 03 与
Gate 1–3 阻塞；本 Resolution 不表示任何真实磁盘变更已获批准。
