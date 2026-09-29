# helper：目标复核、健康检查与可写挂载

Status: resolved
Labels: enhancement, resolved
Assignee: Claude
Blocked-by: 02

## 范围

helper 内的 `mountWritable` 执行器，把 `usb_lab.py` 已验证的流程改写为 Swift：
fresh 系统事实复核（外置/可移除/物理整盘、NTFS 分区、请求身份一致）→ 原生只读卷标准卸载 →
固定 `ntfs-3g.probe --readwrite`（no-recovery）→ 以独立会话启动固定摘要驱动
（`rw,no_def_opts,silent,backend=fskit,norecover,no_detach,local`）到新随机挂载点 →
验证可写 FSKit 挂载、4 KiB 虚拟来源、驱动持有目标分区（libproc，而非 lsof）→ 返回结果。

## 验收

- 执行器决策逻辑以注入的系统事实做行为检查：每个失败关闭条件有红测试。
- 驱动启动前核对 bundle 内制品摘要与签名；启动后驱动存活于独立会话。
- 失败时：已卸载原生卷而挂载失败，返回“需重新读取事实”，不强制、不重试。
- 在一次性镜像（附加为块设备）上通过 helper 完成真实挂载与卸载。

## Resolution

2026-09-29：纯逻辑 `WritableMountExecutor`（`NTFSLiteHelperExecution`）先以假系统写行为检查（RED：模块不存在），
覆盖成功顺序与 13 个失败关闭条件后转绿；变更前失败返回 `executionFailed`，原生卸载后失败返回
`postconditionFailed`，退出状态为固定阶段编号。helper 真实实现：Disk Arbitration 事实与标准卸载、
原始字符设备启动扇区绑定、App 包内固定签名（Team + 标识符）驱动与探针、`posix_spawn` +
`POSIX_SPAWN_SETSID`、`getfsstat` + `MNT_EXT_FSKIT`、libproc 核对驱动 uid/gid 与持有分区。
FSKit 挂载拒绝 root，UUID 读取、可写检查与标准卸载改由 helper 自身的 `--as-mount-user` 子进程在
永久降权到 501/20 后执行（`pthread_setugid_np` 已弃用，未采用）。

可牺牲 U 盘（XMUP22YM，disk6s2）实测暴露并修正三处：`DADiskCopyWholeDisk` 结果在闭包后被释放导致
BSD 名乱码（失败关闭为 targetMismatch，改用 `withExtendedLifetime`）；root 读 UUID 被拒
（identityUnavailable）；DA 对占位盘报告 `Virtual Interface` 而非 diskutil 的 `Disk Image`
（mountNotVerified）。修正后 `mount` 返回 0，FSKit 可写挂载、驱动 501/20 持有 `/dev/disk6s2`。
原计划的“一次性镜像附加为块设备”无法由普通用户以 ntfs-3g 挂载，且生产范围排除虚拟盘，
改在已授权 U 盘上验收。`scripts/check.sh` 通过。
