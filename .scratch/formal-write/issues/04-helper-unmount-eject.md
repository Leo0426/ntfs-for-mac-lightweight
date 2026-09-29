# helper：标准卸载与推出整盘

Status: resolved
Labels: enhancement, resolved
Assignee: Claude
Blocked-by: 03

## 范围

`unmountVolume`、`unmountDisk`、`ejectDisk` 三个固定动作：Disk Arbitration 标准卸载/推出，
FSKit 可写挂载的标准卸载（以挂载用户身份，等待驱动退出），卸载后移除空挂载点。
不使用 force；超时继续等待并返回“静止未确认”。

## 验收

- 行为检查覆盖：卸载被占用（busy）返回原因、不强制；驱动未退出保持租约；推出前同盘所有卷已卸载。
- 一次性镜像上真实卸载/推出通过；最终系统事实复核整盘消失。

## Resolution

2026-09-29：纯逻辑 `DiskReleaseExecutor` 先写行为检查（RED）后转绿：自有 FSKit 挂载标准卸载 → 等驱动
自行退出 → 删除空挂载点；原生挂载走 DA 标准卸载；歧义挂载、忙、驱动未退出、仍有挂载、推出被拒、
推出后未消失均失败关闭；虚拟/内部盘不在范围。helper 识别自有挂载需同时满足：固定驱动路径、持有
目标分区、argv 与固定参数一致、挂载表存在对应 macfuse/fskit 条目；任何其他持有该分区的 `ntfs-3g`
进程使状态未知并拒绝报告已释放。

U 盘实测：helper 挂载后写入 1 MiB 文件 → `unmount` 返回 0、驱动退出、挂载点删除 → 原生只读重挂载
SHA-256 一致；再次挂载后 `eject` 被拒（27 stillMounted）→ 写入 4 KiB 文件 → `unmount-disk` 0 →
`eject` 0，`/dev/disk6` 消失。第二个文件的重插读回待用户重新插盘后核对
（SHA-256 `e9e4750aff6ca43fc18bba448855e8eee6d6406fdee14220037153e0aafce426`）。
