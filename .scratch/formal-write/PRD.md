# 正式应用：外置 NTFS 可写挂载与安全推出

Status: ready-for-agent
Date: 2026-09-29
决策：[ADR 0010](../../docs/adr/0010-enable-writable-mount-in-formal-app.md)

## 问题

正式应用目前只读：能识别外置 NTFS 卷，但用户仍需要其他工具才能写入。独立实验工具已在
可牺牲 U 盘上证明 macOS 27 + macFUSE 5.4.0 FSKit + 固定 NTFS-3G 驱动的写入闭环，但它需要
终端、sudo 和固定目标，不能日常使用。

## 目标

用户在正式应用中选中外置 NTFS 卷，确认它是数据卷后点击“启用写入”，卷以可写方式挂载到
Finder；用完点击“安全推出”，卷标准卸载并推出整盘，界面确认可以拔出。

## 用户流程

1. 首次使用：Setup 页检查 macFUSE、驱动与 helper；helper 未注册时提供“安装帮助程序”，
   用户在系统设置“登录项”中批准。
2. 插入外置 NTFS 盘：列表显示只读卷（系统原生只读挂载）。
3. 选中卷 → “启用写入” → 确认对话框（数据卷声明：不是 Windows 系统/启动卷，说明风险与
   验证边界）→ 进度 → 显示“可写”。
4. 使用 Finder 读写。
5. “安全推出” → 标准卸载并推出整盘 → 显示“可以拔出”。失败时显示原因并保留状态，不强制。

## 范围

- 包含：外置、可移除、USB/Thunderbolt 物理盘上的 NTFS 数据卷；可写挂载、标准卸载、推出整盘；
  helper 注册状态；失败原因与诊断。
- 不含：内部盘、Boot Camp、格式化、修复（chkdsk/recover）、休眠卷处理、多用户、分发签名与公证、
  自动在插入时启用写入。

## 安全要求（均失败关闭）

- UI 只提交完整 `VolumeInstanceID` 与一次性数据卷声明；不拼接命令、路径或参数。
- 每次操作前 helper 重新读取系统事实：整盘外置/可移除/物理、分区为 NTFS、健康检查（no-recovery）
  通过、与请求身份一致。
- helper 只接受 ADR 0002 四种固定动作；XPC 双向代码签名要求；operation ID 一次性。
- 可写挂载验证：唯一挂载点、macfuse/fskit/local/nodev/nosuid 可写，来源为 FSKit 4 KiB 虚拟盘，
  helper 启动的驱动持有目标分区；驱动独立会话，不因 App 或终端退出被挂断。
- 不使用强制卸载、recover、remove_hiberfile、内核后端；超时不等于失败或成功，保持租约。

## 验收

- 自动检查：协议、执行器决策、协调器接线、展示映射均有行为检查；严格 Release 与边界检查通过。
- 实物：在已授权的可牺牲 U 盘上通过正式应用完成“启用写入 → Finder 写入文件 → 安全推出 →
  重新插入读回”，保存证据。不得在其他盘上测试。

## 未验证与风险

- Gate 1–3 未通过；Windows 复核与长期矩阵未完成，界面需说明。
- Apple Development 签名下 `SMAppService` daemon 的注册与批准流程需本机实证。
- 驱动降权身份构建时固定为 uid 501 / gid 20。
