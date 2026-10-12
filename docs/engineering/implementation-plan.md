# NTFS for Mac Lightweight — 分阶段实施计划

本文件是仓库中 **Gate 编号、定义、前置关系和当前状态的唯一来源**。PRD、调研、README 与 ADR 只能引用这里的 Gate，不得另行编号、改写状态或宣称通过；只有取得本文件要求的实物证据后才能更新“当前 Gate 状态”。

## 当前实现与验证

正式应用通过 `NTFSLiteWriteSession`、签名 XPC 和特权 helper 提供写入、标准卸载与整盘推出；Core 协调器与 MountEngineAdapter 保留为纯逻辑契约，正式路线依据 ADR 0010/0011。观察、Setup、诊断、Dock 恢复和执行生命周期已有回归检查。完整边界见 [CONTEXT](../../CONTEXT.md) 与 [ADR 索引](../adr/README.md)，实际允许依赖由 `scripts/check-read-only-boundary.sh` 核验，避免在此复制易漂移的依赖图。

当前本机验证与已知限制见[本机验证记录](../release/local-validation.md)。开发与验证中的真实磁盘操作仅限一次性镜像及用户授权的可牺牲盘。

## 当前 Gate 状态

以下均未宣布通过；ADR 0010 允许正式应用先接入写入，不改变原 Gate 定义与前置关系。

- **Gate 1：未通过。** 独立匿名取证工具已实现，历史 artifact 为 incomplete、0/100。仍缺专用外置盘 100 次插拔、逐轮系统事实对照、多分区、睡醒、重启与声明生命周期人工签署。保留[首次证据](../../.scratch/ntfs-mvp/evidence/G1-5354DF11B2C047289A1862B41EAC2300.md)和[后续证据](../../.scratch/ntfs-mvp/evidence/G1-599DFC215DBB4D6CBA982D72F91CBF50.md)。
- **Gate 2：未通过。** 固定本机依赖、helper 和一次性镜像正常生命周期已有有限实证；完整 dirty、休眠、超时、崩溃与残留矩阵及执行路径竞态仍未验收。候选版本与签名依据见[供应链记录](../operations/dependency-supply-chain.md)，不把早期版本判断作为当前事实。
- **Gate 3：未通过。** 可牺牲 USB 本机闭环已有有限证据；Windows、chkdsk、100 次生命周期和完整文件/异常矩阵仍缺。
- **Gate 4：正式写入已接入，完整 Gate 验收未完成。** 实现路线见 ADR 0011；320 pt、外观、键盘与 VoiceOver 人工验收仍缺，且 Gate 1–3 原前置未通过。
- **Gate 5：未进入。** 签名本机包和安装器检查已通过；Developer ID、公证、两周使用及前置 Gate 未完成。

待办集中在[未完成验收](../../.scratch/ntfs-mvp/MAP.md)。已结案工单可从 Git 历史追溯。

## Gate 1：只读系统观察

目标：不挂载、不卸载、不写磁盘，只证明能够稳定识别系统事实。

交付：

- 使用 Disk Arbitration 监听磁盘出现、描述变化和消失。
- 读取物理盘、子卷、BSD 名、卷 UUID、文件系统、内部或外置、挂载点和读写标志。
- 为每次插入生成新的介质代次；同 BSD 名重新出现也必须是新实例。
- 可信内部位置自动映射为通用 `protected`；外置 NTFS 的系统用途保持 unknown，不按卷名或位置
  猜测 Boot Camp/data。其余事实完整时只生成无变更资格的只读候选。
- 读取真实 mount table，核对 source device、规范路径、符号链接和后端。
- 将无法取得的字段标为 incomplete 或 unknown，不伪造默认值。

验证：

- 插拔同一设备 100 次，代次单调变化且无幽灵卷。
- 证据会话只绑定这一块匿名 target，不能聚合不同外置 candidate；常驻内置盘可以持续存在，
  但不进入 target 的未确认连接计数或阻塞结算。
- 第 1 轮前先取得 target 的 verified absence baseline。若采集启动时 target 已插入，必须先确认
  该连接消失；它只用于绑定 target，不能计作第 1 轮。
- 每轮 `systemInventoryComparison` 与 `mountTableComparison` 都在该轮 verified target present
  之后、verified absence 之前完成。unverified pending 不结算 absence，也不允许提交逐轮对照；
  等后续 verified candidate 恢复后再对照，最终只由 verified absence 结算。
- 多分区磁盘的父子关系正确。
- 睡眠、唤醒和应用重启后 inventory 与 `diskutil`、mount table 一致。
- 外置 unknown NTFS 候选可见并明确显示“用途未确认”，但 `coordinatorInventory` 为空；重插、
  唤醒重订阅、应用重启和 sibling 拓扑变化都不能复用旧选择或旧声明。
- 不产生任何 unmount、mount 或 eject 调用。
- 可用 `NTFSLiteGate1EvidenceTool` 生成匿名 canonical artifact 并独立校验摘要与语义；工具返回
  `readyForHumanReview` 还要求 canonical observations 最后一帧 coverage verified；verifier 从 frames
  独立重算，无 failure code 但最后一帧 unverified 只能 incomplete。该 verdict 仍只表示结构条件
  齐备，必须人工复核本节全部实物证据后才能更新 Gate 状态。
- 显式 `seal` 不取消观察任务：先排空 Disk Arbitration 串行队列，在 `drainBoundary` 之后完成
  最终 settle 与独立 IOKit enumeration，并让最终 observation、capture terminal 与 recorder seal
  保持 FIFO 顺序；自然 source end 或最终 observation 未验证时 artifact 永久 `failedClosed`。

停止条件：

- 无法可靠区分物理盘和卷。
- 卷 UUID、BSD 名或代次可能在重插后错误复用。
- 无法确认 mount source 或后端。

## Gate 2：磁盘镜像上的挂载引擎

目标：只使用一次性 NTFS 镜像验证 FSKit 路线和固定安全策略。

交付：

- Setup adapter 检测 macOS 15.4+、Apple Silicon、macFUSE、NTFS-3G 与 File System Extension。
  当前冲突目录候选范围只精确绑定 macOS 15.4.0 / Apple Silicon；其他系统版本在
  有新的具名调研证据前必须报 scope mismatch，不得把平台最低版本当成范围兼容证据。
- macFUSE 只在所选精确版本的同一批准条目中，requirement、Team ID、CodeDirectory identity
  和同一 `SecStaticCode` 的 secured Info.plist identifier/version 全部匹配时形成可信依赖证据；
  目录不完整、identity 跨版本复用、签名漂移或 Security 读取失败都保持未就绪。
- 冲突检测绑定具名、带目标平台和制品摘要的有限候选范围，同时核对 loaded identifier、固定
  installed footprint 与环境基线；不能把 allowlist 未命中解释为已穷举全市场。
- Setup adapter 只接受经固定 SHA-256 allowlist 和完整“哈希 → 版本”目录验证的 NTFS-3G 制品；读取版本不得执行该程序，未配置生产目录或核对失败时保持未知。
- 挂载调用编译器只能接收可信制品解析器产生的不可伪造能力，并在编译时重新验证；真实执行器必须在启动前再次关闭路径 TOCTOU，不能仅信任字符串路径或较早的哈希结果。
- MountEngine 只支持 `fsKitCurrentUserNoRecovery`。
- 已有可信 snapshot 的路径在每次变更前 fresh-resolve 完整 `VolumeSnapshot` 或完整
  sibling snapshots，并核对其 `VolumeInstanceID` / `DiskInstanceID`。unknown-role 外置 NTFS
  路径则必须分别核对 fresh candidate、当前连接一次性 `DataRoleApproval` 与完整系统/sibling
  事实；approval 不得升格成 `VolumeSnapshot` 或 System Evidence。
- 为卸载、检查、挂载、推出和验证设置总超时；检查超时可进入终态，已领取的写入或推出变更超时、取消时必须等待真实进程退出并取得对应完整系统事实后才释放整盘租约。
- 结构化记录操作、阶段、本次运行内目标数字别名、固定退出类别与耗时；不记录原始目标身份或 stderr 文本。

验证：

- 健康镜像：只读 → 卸载 → fresh snapshot → 可写挂载 → fresh mount verification。
- dirty、休眠、未知健康状态全部拒绝写入。
- 写挂载 effect 生成后若卷被其他工具重挂载或安全事实改变，最终预检必须执行零次系统变更并进入明确失败态。
- eject effect 生成后若任一子卷重挂载，最终预检必须执行零次系统推出并列出仍挂载的卷。
- 推出命令回调与介质移除事件任意乱序时，只有当前 operation 接纳的完整整盘 absence 观察可产生 `safeToRemove`；重复移除事件不得抹掉已验证结果，旧 present 观察不得复活已移除介质。
- 重复 child ID、缺失发起卷或不完整 inventory 均不得授权整盘变更；完整 present 事实必须同步每个仍存在 sibling，避免租约释放后暴露旧的 writable/read-only 状态。
- 整盘卸载或最终推出回调即使明确报告 busy，也先进入完整物理盘 reconciliation；正常成功路径的后续观察不完整时继续读取，完整事实前不释放租约或恢复 sibling 动作。
- 效果生成后替换镜像实例，一次性执行门禁记录零次系统变更且原效果不可重放。
- 错误后端、source device、只读标志、symlink 和不完整观察均不得进入 `writable`。
- 取消、超时、进程崩溃后没有遗留“已验证可写”状态；旧进程未退出或新观测不完整时，写入、推出与 inventory rebuild 全部保持锁定。

停止条件：

- 需要 kext、Reduced Security、关闭 SIP 或替换系统文件。
- FSKit 后端无法可靠卸载。
- 任一镜像出现无法解释的元数据或内容变化。

## Gate 3：可牺牲物理盘

目标：在没有唯一数据副本的专用测试盘上验证真实生命周期。

准备：

- 至少一块专用 SSD 或 U 盘；所有测试数据另有副本。
- Windows 测试机或虚拟机，用于完整关机、Fast Startup、休眠与 `chkdsk`。
- 固定 macFUSE、NTFS-3G 版本、源码来源和校验和。

验证矩阵：

- 创建、覆盖、追加、重命名、删除。
- 4 GB 以上大文件、海量小文件、Unicode、长文件名、稀疏与压缩文件。
- 磁盘满、权限错误、Finder 与 Spotlight 并发访问。
- 多分区整盘推出、设备忙、睡眠唤醒和中途断开。
- 连续挂载与卸载至少 100 次。
- 每轮回 Windows 运行 `chkdsk`，并比较内容哈希。

停止条件：

- Windows 检查出现新增错误。
- 内容哈希不一致。
- 应用曾在未验证时显示可写或可以拔出。
- 任何失败路径触发 force、recover 或 `remove_hiberfile`。

## Gate 4：SwiftUI 菜单栏入口与 C 版主窗口

前置：Gate 1–3 全部通过。

交付：

- 菜单栏状态入口只提供常驻状态、刷新和打开主窗口，不复制磁盘变更操作。
- C 版主窗口使用“左侧磁盘或设置分类 + 右侧状态详情”，一次只展开一个目标和一个主操作。
- 首次设置、磁盘状态、处理指引和脱敏诊断复用同一窗口结构。
- 只消费 `VolumePresentation`；不在 View 中推导安全规则。
- 文字状态优先，支持 VoiceOver、键盘、深色和高对比度。
- 处理中禁用重复动作；最终成功只来自系统事实复核。

验证：

- UI 指南中的全部状态都有预览与自动映射检查。
- 正式构建不包含 A/B 变体或原型切换器。
- 320 pt 宽度无横向滚动。
- 无图标、无颜色时仍能理解状态与下一步。
- 休眠、dirty、健康 unknown 和已有未验证可写挂载不显示“启用写入”；用途 unknown 的只读
  candidate 在声明与 fresh 事实解析前也不显示写入或推出。
- `mediaInvalidated` 不提供基于旧目标的重试或推出。

## Gate 5：个人日常使用候选

交付：

- 固定依赖版本与供应链记录。
- helper 最小权限、Hardened Runtime、签名与本机验证。
- 本地诊断保留策略和一键清除。
- 升级前兼容检查与手动回滚说明。

进入条件：

- 至少两周个人非关键数据使用无数据不一致。
- 100 次生命周期测试与 Windows 复核全部通过。
- 所有已知失败都能安全停止或回到系统只读状态。

即使通过，也不自动扩大为公开分发。公开发布需要重新评估 GPL、macFUSE 再分发许可、签名、公证、支持矩阵和更新责任。
