# 一次性 NTFS 镜像：本机闭环通过

Date: 2026-09-09
Status: localChecksPassed / disposable-image-only

128 MiB 一次性 NTFS 镜像已完成真实 FSKit 可写挂载、文件操作、标准卸载、重挂载独立读回、
清理及最终标准卸载。系统为 macOS 26.6.2（25G83），macFUSE 5.4.0 / NTFS-3G 2026.7.7。

| 核对项 | 实际结果 |
| --- | --- |
| 依赖与镜像 | NTFS-3G/probe/mkntfs 摘要匹配回执；正式 macFUSE 应用、扩展和库严格签名匹配；镜像为当前用户独占的 128 MiB 常规文件，启动扇区为 NTFS，probe 退出 0 |
| 真实挂载 | `/sbin/mount` 两次完整快照一致，出现 `macfuse`、`fskit` 且无 read-only；根目录设备号与父目录不同、statvfs 可写；ntfs-3g 进程确实持有该镜像 |
| 文件语义 | 34 项检查通过，包含空文件、1–16 字节、Unicode/空格、长短覆盖、追加、重命名/替换、文件/目录删除、非空目录拒绝及 1 MiB 文件 |
| 持久化 | 标准卸载返回成功，挂载表确认消失且原驱动退出；同一镜像通过 fresh 预检后重挂载，得到新的挂载来源与设备号；独立 Python 进程核对 22 个保留文件及 6 个删除项 |
| 清理与退出 | 只清理本轮清单中的测试文件，目录确实移除；标准卸载后挂载表无实验卷，驱动已退出 |

[规范清单](evidence/image-manifest.json) 与 [结果摘要](evidence/image-result.json) 保留本轮
证据。清单是清理前的历史预期，不能用它声称文件当前仍存在。详细本机日志保留在已忽略的
`.build/write-validation/` 中，镜像本身也保留；未对物理 USB 格式化或写入。

该结果只证明本次 macOS 一次性镜像闭环。4 GiB 文件、USB 实物、Windows、异常断连、
并发/睡醒/磁盘满及 Gate 1–3 完整矩阵均未在此结果中通过。`windowsVerified=false`、
`usbVerified=false`，正式应用能力和 Gate 状态不变。
