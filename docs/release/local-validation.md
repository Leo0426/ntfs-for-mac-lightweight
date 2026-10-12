# 本机验证与剩余限制

更新日期：2026-10-12。正式代码版本为 0.1.18（19），提交 `d44bbcd`。

## 已取得的证据

2026-10-12 `scripts/check-release.sh` 完整通过：严格 Release、Core 与实际 App controller、隔离诊断归档、Dock 窗口恢复、系统边界、102 项隔离实验测试、签名 App/helper/driver/seed/daemon/pkg 离线核验及 14 项安装器测试。

2026-10-10，同一版本在用户授权的可牺牲 NTFSLAB 上完成正式 App 启用写入、4,194,560 字节写入/fsync、新描述符读回 SHA-256 一致、删除本轮文件并 fsync，以及标准整盘卸载与推出。三个实际请求均返回 succeeded、verified；驱动退出，原物理设备节点、IOMedia 与挂载消失，界面显示已安全推出。此轮没有做 0.1.18 重插读回。

此前独立实验已完成 128 MiB 一次性镜像的文件语义、标准卸载、重挂载独立读回；可牺牲 USB 的实验覆盖 4 GiB + 1 字节文件、22 个保留文件及 6 个删除项的重挂载验证。历史匿名清单仍保留在 [.scratch/write-delete-validation/evidence](../../.scratch/write-delete-validation/evidence/)，不能据此推断当前设备或文件状态。

## 尚未验证或未解决

- Windows `chkdsk` 与跨系统数据一致性、100 次完整生命周期、长期使用及完整异常矩阵尚未完成。
- 320 pt、键盘、VoiceOver 和完整外观人工验收仍待完成。
- 镜像标准卸载曾发生内核等待；重启后本机闭环恢复，未证明第三方/内核挂起根因已消除。
- 未提供未知 runtime 残留自动清理、跨 App 重启会话绑定恢复或完全消除 BSD 路径快速拔插竞态的保证。
- 本机签名包验证不等于 Developer ID、公证或公开分发资格。

Gate 状态仍由[实施计划](../engineering/implementation-plan.md)定义；有限成功不改变 Gate 1–5。待办入口见[未完成验收](../../.scratch/ntfs-mvp/MAP.md)。调试日志、代码快照和本机诊断保留本地，不作为公开 Gate 证据。
