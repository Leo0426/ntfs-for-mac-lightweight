# 可牺牲 U 盘上的正式应用实物验收

Status: ready-for-human
Labels: enhancement, ready-for-human
Assignee:
Blocked-by: 03, 04, 07, 08

## 范围

在已授权的可牺牲 U 盘（XMUP22YM）上，通过正式应用完成：插入 → 启用写入 → Finder 写入并
校验一个文件 → 安全推出 → 重新插入 → 原生只读读回校验。保存证据；不得使用其他盘。

## 验收

- 每步系统事实与界面状态一致；证据写入 `.scratch/formal-write/evidence/`。
- 失败保留现场，不强制卸载。

## 评论

2026-09-29 首次 App 验收：启用写入成功（helper 16:35:47 挂载），但 Finder 侧栏显示挂载点名
`NTFSLite-<随机>` 而非 `NTFSLAB`，用户误以为 U 盘消失并重新插拔（16:40:41 移除、16:40:52 重现），
留下设备已消失的 FSKit 挂载与驱动。以用户身份标准 `umount` 清理成功（rc=0，驱动退出）。
修正：挂载点改为 `/Volumes/<安全卷名>`（非法或超长卷名回退 `NTFS`，占用时加序号），因 FSKit 下
Finder 以挂载点目录名显示卷（`volname=` 实测无效）；新增拔盘后残留清理：整盘不存在时安全推出会
标准卸载自有驱动仍持有已消失设备的挂载并等待退出；helper 空闲 120 秒退出以便更新生效。
此前排查中使用 zsh 内建 `log` 导致日志查询为空，已改用 `/usr/bin/log`，相关“无日志”结论作废。
