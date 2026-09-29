# 可牺牲 USB：本机闭环通过

Date: 2026-09-29
Status: localChecksPassed / usb-physical / windows-pending

用户授权的可牺牲 U 盘（XMUP22YM，124,623,257,600 字节，GPT + NTFS 数据分区
124,411,445,248 字节）在 macOS 27.0（26A428）、macFUSE 5.4.0 FSKit local 与固定摘要的
NTFS-3G 2026.7.7 永久降权 v2 驱动下完成完整 USB 闭环。运行 `usb-run-cp3auc6d`，约 37 分钟。

| 阶段 | 实际结果 |
| --- | --- |
| 目标与预检 | 固定回执、整盘/分区/EFI 拓扑、依赖签名、v2 驱动摘要与文件检查身份切换通过 |
| 原生卸载 | `nativeUnmountVerified`；启动扇区绑定与 no-recovery 健康检查通过 |
| 可写挂载 | `writableMountVerified`；来源为 FSKit 4 KiB 虚拟盘，lsof 证明本轮 uid 501 驱动持有物理分区 |
| 小数据集 | `cleanupVerified`，33 项写删检查与清理 |
| 数据集 | `fileChecksPassed`，34 项，含 4 GiB + 1 字节文件 |
| 持久化 | 标准卸载、新挂载点重挂载，独立进程核对 22 个保留文件与 6 个删除项：`remountReadbackVerified` |
| 收尾 | 标准卸载 `unmountVerified`、`localChecksPassed`；无驱动进程、残留挂载或本轮挂载点目录 |

[规范清单](evidence/usb-manifest.json) 与 [结果摘要](evidence/usb-result.json) 保留本轮证据；
完整日志在已忽略的 `.build/write-validation/usb-run-cp3auc6d/`。测试目录
`ntfslite-check-5d386201ffa24d50905dd05ec50004d6` 保留在 U 盘上供 Windows 复核。

本轮修正的 macOS 27 问题：FSKit 虚拟挂载来源、`no_def_opts` 取消默认 `silent` 导致的
`EOPNOTSUPP`、卸载后保留挂载点，以及终端关闭挂断驱动。详见 [PLAN](PLAN.md)。

未覆盖：Windows 复核（`windowsVerified=false`）、整盘推出与可拔出确认（`safeToRemoveVerified=false`）、
异常断连、并发、睡醒、磁盘满、稀疏/压缩文件与 Gate 1–3 完整矩阵。正式应用能力与 Gate 状态不变。
