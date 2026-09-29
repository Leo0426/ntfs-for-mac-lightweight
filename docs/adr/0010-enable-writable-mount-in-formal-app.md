---
status: accepted
---

# 在正式应用中接入可写挂载与安全推出

2026-09-29 用户明确决定：不再以 Gate 1–3 全部通过作为正式应用加入写入能力的前置条件，
直接把已在可牺牲 U 盘上验证过的 macOS 本机写入路径接入正式应用。第一版范围为外置 NTFS
数据卷的“启用写入（可写挂载）”与“安全推出（标准卸载并推出整盘）”。特权操作使用
`SMAppService` 注册的 launchd daemon helper，经 XPC 传递 ADR 0002 的结构化一次性协议；
应用与 helper 使用用户的 Apple 开发者签名身份互相校验。

该决定依据 [USB 本机闭环结果](../../.scratch/write-delete-validation/USB-RESULT.md)：
macOS 27.0 + macFUSE 5.4.0 FSKit local + 固定摘要 NTFS-3G 2026.7.7 永久降权驱动，在真实 U 盘
上完成可写挂载、33 项写删、4 GiB + 1 字节数据集、重挂载独立读回与标准卸载。

## Considered Options

- 维持原规则，先完成 Gate 1–3：拒绝。用户选择先获得可用的个人工具，Gate 证据继续独立积累。
- 新建独立实验版 App：拒绝。用户选择直接改正式应用，避免维护两套界面。
- 每次操作通过管理员弹窗启动脚本：拒绝。本机已观察到该启动环境对原始设备返回 `EPERM`，
  且会把提权入口变成通用脚本执行。
- `SMAppService` daemon + XPC + ADR 0002 协议：采用。只暴露四种固定语义动作，调用方与 helper
  双向代码签名要求，operation ID 一次性消费。

## Consequences

- 正式应用依赖图允许进入 `NTFSLiteHelperProtocol` 与 `NTFSLiteMutationPreparation`；
  只读边界检查改为核对新的允许集合，仍禁止 UI 拼接命令、路径或挂载参数，仍禁止强制卸载、
  `recover`、`remove_hiberfile`、内核扩展后端与降低系统安全性。
- Gate 1–5 的定义与状态不因本 ADR 改变；实施计划中“Gate 通过前不加入写入按钮”的约束被本
  ADR 取代。界面必须说明写入能力基于有限的实物验证，Windows 复核与长期矩阵尚未完成。
- 只允许用户显式声明的外置 NTFS 数据卷；内部盘、受保护角色、身份不完整、矛盾或健康检查
  失败的卷继续失败关闭。每次启用写入前重新读取系统事实，声明一次性消费。
- 可写挂载沿用实验验证过的固定参数 `rw,no_def_opts,silent,backend=fskit,norecover,no_detach,local`
  与 FSKit 绑定判定：挂载来源为 4 KiB 虚拟盘，且 helper 启动的驱动进程持有目标分区。
- 驱动的降权身份在构建时固定为单一本机用户（当前 uid 501 / gid 20）；多用户支持需要新的决定。
- 第一版使用 Apple Development 证书本机签名；分发给他人需要 Developer ID Application 证书、
  Hardened Runtime 与公证，属于 Gate 5 范围。
- ADR 0009 的独立实验工具保留，用于回归与新候选验证。
