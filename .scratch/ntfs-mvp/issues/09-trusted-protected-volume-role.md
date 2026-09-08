# 建立受保护卷可信角色证据

Status: resolved
Labels: bug, resolved
Assignee:
Blocked-by:

## 问题

历史 Gate 1 文案曾要求识别内部卷与 Boot Camp。移除按用户可修改卷名推断 Boot Camp 的
启发式后，Apple 公开事实不能产生可信的精确 Boot Camp 角色；把所有外置卷默认成 `data`
同样不能满足失败关闭边界。本 Issue 因而把目标收敛为可信通用 `protected` 与 `unknown`。

## 验收

- 只采用 Apple 一手资料确认的只读系统事实表达可信 `protected` 或 `unknown`；`data` 只允许由
  另一个明确可信来源提供，不从外置位置、卷名或分区文字自动产生。
- 卷名、BSD 名模式和其他用户可修改文字不得成为可信角色证据。
- 缺失、矛盾或平台未定义的角色保持 unknown/incomplete，不能进入写入或整盘推出资格。
- 纯 fixture 覆盖可信受保护、可信 data、未知和矛盾事实；不执行真实磁盘变更。
- 如果没有足够的一手来源可靠区分 Boot Camp，记录该限制并让内部 NTFS 继续按受保护卷处理，
  不伪造精确角色。

## 评论

本 Issue 只建立失败关闭的领域事实和只读映射；专用硬件对照仍由 Issue 02 完成。

## Resolution

2026-08-31：Apple 公开 Disk Arbitration / IOKit 事实没有提供稳定的 Boot Camp/Windows
system-role 标识；研究证据记录于 `docs/research/apple-protected-volume-role-evidence.md`。
实现新增类型化 `VolumeRoleEvidence`：可信内部位置映射为通用 `protected`，不声称精确 Boot Camp；
外部卷默认 `unknown`，unknown/conflicting 均保持 incomplete，不能投影 coordinator inventory。
`trustedData` 只保留为历史领域接口和纯 fixture，当前生产路径不会产生，也不把
后续人类声明转换成该 System Evidence。正式路径由 Issue 17 的当前连接一次性
`DataRoleApproval` 与 Gate 4 重新读取的 candidate、完整 sibling 和系统事实分别核对；
approval 不生成 `VolumeSnapshot`。
Core 对任何通用 `protected` 角色都使用独立固定原因拒绝写入和整盘推出，不依赖 location，
并在最终整盘预检中把受保护 sibling 继续作为失败关闭条件。

Release 行为检查、只读边界检查和严格 Release 构建均通过；未执行任何挂载、卸载、推出或其他
真实磁盘变更。专用测试盘对照仍由 Gate 1 / Issue 02 阻塞；声明与新鲜系统事实的
正式接线由 Gate 4 / Issue 12 阻塞，Issue 02 不会产生 `trustedData`。
