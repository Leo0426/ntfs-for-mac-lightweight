# macOS NTFS 商用工具能力与轻量个人版路线调研

> 调研日期：2026-08-30；技术底座风险更新：2026-09-08（macFUSE 5.4.0 pre-release 复查）\
> 用途：为个人使用的轻量 NTFS for Mac 工具确定产品边界、UI、技术底座与稳定性门槛。\
> 文档边界：本文保存调研事实与验证依据；Gate 的编号、前置关系和当前状态只以[分阶段实施计划](../engineering/implementation-plan.md)为准，本文不另行编号或宣布通过。
> 后续产品决策以 [MVP PRD](../product/mvp-prd.md)、[UI 指南](../design/ui-guidelines.md)和
> [ADR 0004–0006](../adr/README.md)为准；本文保留的早期建议不得覆盖已经接受的 C 版、静态代码
> 身份、只读 candidate、当前连接声明与 Gate 2 具名冲突范围边界。

## 结论先行

1. **需求真实，但核心很窄。** Apple 明确说明，Mac 对 NTFS 可能可读但不可写；商用品真正解决的是“接入 NTFS 盘后，在 Finder 中像普通磁盘一样安全读写”。[Apple：外置盘无法写入时的说明](https://support.apple.com/en-ie/101830)
2. **成熟产品的共同能力不是“大而全”，而是透明挂载。** Paragon、Tuxera、iBoysoft 都覆盖读写、自动挂载和基本卷操作；差异主要在驱动实现、安装侵入性、磁盘管理附加功能和诊断支持，而不是文件管理 UI。
3. **个人轻量版不应先写一个新的 NTFS 驱动。** 当前产品采用 C 版单窗口和文字状态菜单入口，
   复用 `ntfs-3g` 的 NTFS 实现，并优先验证 macFUSE 5 的 FSKit 后端。macFUSE 官方称该后端在
   macOS 15.4 及以后纯用户态运行，不需要内核扩展或进入恢复模式；但官方也明确列出了挂载点、
   上下文、挂载选项和性能限制，所以它目前是**验证优先路线，不是已证明稳定的结论**。
   [macFUSE Getting Started](https://github.com/macfuse/macfuse/wiki/Getting-Started)；
   [macFUSE FUSE Backends](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)
4. **内核后端不进入个人轻量版。** macFUSE 的内核后端功能更完整、官方称性能更好，但 Apple silicon 上需要将启动安全策略改为 Reduced Security 并允许第三方内核扩展；这不符合“轻量、稳定、好用”的产品边界。[Apple：更改 Apple silicon 启动安全策略](https://support.apple.com/guide/mac-help/change-security-settings-startup-disk-a-mac-mchl768f7291/mac)
5. **稳定性必须通过“拒绝危险写入”获得。** NTFS 卷若处于 Windows 休眠、Fast Startup 或非正常卸载状态，默认只读或拒绝写入；MVP 不暴露 `recover`、`remove_hiberfile`、强制卸载、格式化或修复。`ntfs-3g` 官方手册说明，`recover` 会清除 Windows 日志且可能导致不一致，而 `remove_hiberfile` 会丢失保存的 Windows 会话。[NTFS-3G Manual](https://github.com/tuxera/ntfs-3g/wiki/Manual)
6. **UI 应以文字状态为主。** 菜单栏只显示汇总状态并打开 C 版主窗口；磁盘操作、首次设置、
   错误处理和诊断统一在窗口中完成。不要让颜色或图标成为唯一状态信息。

## 研究方法与证据等级

- 仅使用产品官网、官方帮助中心、Apple 文档、官方源码仓库和官方项目 wiki。
- **事实**：来源直接陈述的产品/API 行为。
- **厂商宣称**：厂商提供但没有独立、当前、同条件验证的性能或安全描述。
- **推断**：从多个事实得出的产品/工程判断，仍需本项目验证。
- **未知**：一手资料不足、互相矛盾，或只能通过原型/实机测试确定。
- 本文没有把厂商营销页的“原生速度”“绝对安全”“最快”当成已验证结论。

## 市场能力对照

| 能力 | Paragon NTFS for Mac | Microsoft NTFS for Mac by Tuxera | iBoysoft NTFS for Mac | Mounty / 免费边界 |
| --- | --- | --- | --- | --- |
| NTFS 完整读写 | **事实：有。** 创建、读取、修改、复制、删除。[产品页](https://www.paragon-software.com/home/ntfs-mac/) | **事实：有。** 打开、编辑、复制、移动、删除。[产品页](https://ntfsformac.tuxera.com/) | **事实：有。** Finder 中读写、复制、编辑、删除、移动。[在线帮助](https://iboysoft.com/ntfs-for-mac/online-help.html) | **事实：有条件。** Mounty 2 是 NTFS-3G + macFUSE 的 GUI，自身不实现 NTFS。[Mounty](https://mounty.app/) |
| 自动挂载 | **事实：有，可关闭。** [产品页](https://www.paragon-software.com/home/ntfs-mac/) | **事实：驱动默认启用并在后台接管 NTFS；可全局或按卷禁用。** [按卷禁用说明](https://macsupport.tuxera.com/hc/en-gb/articles/360021093699-How-can-I-disable-Microsoft-NTFS-for-Mac-by-Tuxera-without-uninstalling-just-for-a-selected-volume) | **事实：Advanced 模式自动挂载；Simple 模式每次手动挂载且无需扩展。** [模式说明](https://iboysoft.com/ntfs-for-mac/write-to-ntfs-drives-mac-without-kernel-extensions.html) | **事实：有自动挂载选项。** 版本历史记录了该能力及修复。[Mounty](https://mounty.app/) |
| 菜单栏 / 快速入口 | **事实：有轻量菜单栏和完整应用。** [产品页](https://www.paragon-software.com/home/ntfs-mac/) | **事实：有菜单栏入口，且可关闭菜单栏图标。** [帮助](https://macsupport.tuxera.com/hc/en-gb/articles/360021034500-How-can-I-disable-the-menu-bar-icon-of-Microsoft-NTFS-by-Tuxera) | **事实：有菜单栏入口和磁盘列表式主界面。** [在线帮助](https://iboysoft.com/ntfs-for-mac/online-help.html) | **事实：菜单栏是主界面，状态区分无盘、可重挂、处理中、已可写、失败。** [Mounty](https://mounty.app/) |
| 打开 Finder | **事实：挂载后直接出现在 Finder。** [产品页](https://www.paragon-software.com/home/ntfs-mac/) | **事实：以系统卷工作；可在 Disk Manager 或 Apple Disk Utility 中手动挂载。** [挂载排障](https://macsupport.tuxera.com/hc/en-gb/articles/360021071580-What-if-I-have-problems-mounting-a-disk-with-Microsoft-NTFS-by-Tuxera) | **事实：有 Open 操作，挂载后按普通磁盘使用。** [在线帮助](https://iboysoft.com/ntfs-for-mac/online-help.html) | **事实：菜单栏可将对应 Finder 窗口置前。** [Mounty](https://mounty.app/) |
| 挂载、卸载、推出 | **事实：应用提供 mount、unmount、verify；产品页未明确单列 eject。** [产品页](https://www.paragon-software.com/home/ntfs-mac/) | **事实：Disk Manager 支持手动挂载；系统级推出可由 Finder/Disk Utility 完成。** [挂载排障](https://macsupport.tuxera.com/hc/en-gb/articles/360021071580-What-if-I-have-problems-mounting-a-disk-with-Microsoft-NTFS-by-Tuxera) | **事实：有 open、mount、unmount、eject。** [在线帮助](https://iboysoft.com/ntfs-for-mac/online-help.html) | **事实：重点是从系统只读挂载重挂为可写；不是完整磁盘管理器。** [Mounty](https://mounty.app/) |
| 只读 / 按卷策略 | **事实：支持按卷只读、禁止自动挂载。** [产品页](https://www.paragon-software.com/home/ntfs-mac/) | **事实：可全局禁用或按卷禁用 Tuxera 驱动，回退给 Apple/其他驱动。** [按卷禁用说明](https://macsupport.tuxera.com/hc/en-gb/articles/360021093699-How-can-I-disable-Microsoft-NTFS-for-Mac-by-Tuxera-without-uninstalling-just-for-a-selected-volume) | **事实：Simple/Advanced 两种挂载模式；未找到明确的持久化按卷只读策略说明。** | **事实：可按卷选择是否重挂及自动挂载；高级按卷安全策略未文档化。** |
| 检查、修复、格式化 | **事实：有格式化、完整性检查和修复。** [产品页](https://www.paragon-software.com/home/ntfs-mac/) | **事实：Tuxera Disk Manager 可格式化、检查、修复；Apple Disk Utility 也可在安装后格式化 NTFS。** [产品页](https://ntfsformac.tuxera.com/)；[格式化说明](https://macsupport.tuxera.com/hc/en-gb/articles/360021093939-How-do-I-format-external-media-to-use-the-NTFS-file-system) | **事实：可检查、修复、擦除及格式化为 NTFS。** [在线帮助](https://iboysoft.com/ntfs-for-mac/online-help.html) | **事实：Mounty 不提供完整修复/格式化；官网将此类需求引向专业磁盘工具。** [Mounty](https://mounty.app/) |
| 诊断 | **事实：可切换 verbose 日志并保存日志包。** [Paragon 日志说明](https://paragon-software.zendesk.com/hc/en-us/articles/14100122445841-How-to-collect-Verbose-logs-in-Microsoft-NTFS-for-Mac-by-Paragon-Software) | **事实：可开启 debug log，记录驱动、挂载、格式化、探测信息。** [Tuxera 诊断说明](https://macsupport.tuxera.com/hc/en-gb/articles/360021094159-How-do-I-gather-useful-information-for-troubleshooting) | **事实：版本历史记录了自动收集崩溃日志；公开在线帮助未见同等完整的用户导出诊断流程。** [版本历史](https://iboysoft.com/ntfs-for-mac/upgrade-history.html) | **事实：有可见错误状态和帮助文档；未找到结构化日志导出。** |
| 当前兼容性快照 | **事实：** v17 build 17.0.364+ 支持 macOS 26 Tahoe；产品页列 Intel 与 Apple silicon M1–M4，M5 未明确。[产品页](https://www.paragon-software.com/home/ntfs-mac/)；[支持矩阵](https://paragon-software.zendesk.com/hc/en-us/articles/29003988155409-NTFS-For-Mac-Supported-OS-Versions) | **事实但有冲突：** 2026 版与产品页支持 Tahoe、Intel、Apple silicon；帮助页又把 Apple silicon“最后支持版本”写为 2025，目标机仍需实测。[发布记录](https://macsupport.tuxera.com/hc/en-gb/articles/4406039424146-Release-notes)；[系统要求](https://macsupport.tuxera.com/hc/en-gb/articles/360020979699-What-are-the-system-requirements) | **事实但实现不透明：** 支持 macOS 26、Intel、Apple silicon M1–M5；Simple 模式无需扩展，Advanced 自动挂载模式需扩展，但 Simple 的底层机制未公开。[产品页](https://iboysoft.com/ntfs-for-mac/)；[模式说明](https://iboysoft.com/ntfs-for-mac/write-to-ntfs-drives-mac-without-kernel-extensions.html) | **事实：** 官网列 macOS 10.9 到 26，最新版 2.4（2023-12）；Ventura 起依赖独立安装的 macFUSE 与 NTFS-3G。[Mounty](https://mounty.app/) |

### 从商用品中应吸收的模式

- **推断：透明性比功能数量重要。** 用户完成一次安装后，主要工作仍在 Finder；菜单栏只处理状态和例外。
- **推断：按卷限制策略很有价值。** Paragon 的“只读”和“不要自动挂载”、Tuxera 的按卷禁用、
  iBoysoft 的手动/自动两种模式都在解决“不是每个盘都应默认写入”。本项目只允许持久保存更保守
  的“始终只读”，不得持久保存 data-role 信任或自动可写资格。
- **推断：诊断是稳定产品的一部分。** Paragon 与 Tuxera 都把扩展日志作为正式支持路径；轻量版也应提供可复制的环境检查和固定字段诊断摘要，而不是只弹“挂载失败”或收集任意日志文本。
- **推断：格式化、修复和 Boot Camp 启动不是个人轻量版核心。** 这些功能扩大数据损坏面、权限边界和测试矩阵，应从 MVP 排除。

### 不能从商用品资料得出的结论

- Paragon 的“快 6 倍”来自厂商链接的旧硬件测试；Tuxera 的“接近 HFS+”、iBoysoft 的“接近原生”也都是厂商宣称。没有找到同一台当前 Mac、同一块盘、同一数据集上的可复现实测，因此**不能据此排序性能**。[Paragon 产品页](https://www.paragon-software.com/home/ntfs-mac/)；[Tuxera 产品页](https://ntfsformac.tuxera.com/)；[iBoysoft 产品页](https://iboysoft.com/ntfs-for-mac/)
- “安全”“可靠”“无损”均未发现公开形式化验证或当前独立审计。Tuxera 发布记录显示其曾修复可由恶意 NTFS 元数据触发的缓冲区溢出，这说明解析不可信磁盘元数据确实是安全边界，不能把营销词当保证。[Tuxera Release Notes](https://macsupport.tuxera.com/hc/en-gb/articles/4406039424146-Release-notes)

## 免费方案的边界

### macOS 原生只读

- **事实：** Apple 表述为 Mac 对 NTFS “可能可读，但不可写”，Disk Utility 不支持 NTFS。[Apple 支持](https://support.apple.com/en-ie/101830)
- **结论：** 这是最安全、零安装的兜底。轻量版失败时必须保留原生只读访问，不应把“未获得可写”表现成“磁盘不可用”。

### Mounty

- **事实：** Mounty 是免费菜单栏前端。Ventura 起不再使用 Apple 隐藏写入路径，而是调用 NTFS-3G + macFUSE；官网安装说明依赖第三方 Homebrew tap 的 `ntfs-3g-mac`。[Mounty](https://mounty.app/)
- **事实：** Mounty 站点明确按“as is”无担保提供，并禁止未授权镜像或再分发。
- **推断：** 它验证了“菜单栏 + 一个主要动作”足以覆盖偶发个人使用，但其多组件安装、权限提示、第三方打包链和有限诊断正是本项目要改善的部分。
- **未知：** 官网当前说明仍按 macFUSE 内核路径描述安装，没有说明是否已验证 macFUSE 5 FSKit 后端。

### exFAT 作为产品外替代

- **事实：** Apple 将 ExFAT 作为大于 32 GB、需与 Windows 共用的格式选项。[Apple Disk Utility](https://support.apple.com/en-gb/guide/disk-utility/dsku19ed921c/mac)
- **结论：** 若用户完全控制磁盘且不要求 NTFS，应在帮助中说明“备份后改用 ExFAT”这一零驱动选择；格式化会清空数据，应用本身不应在 MVP 中执行它。

## Apple 平台约束与可用技术

### FSKit：真正对应文件系统的现代 API

- **事实：** FSKit 用于在用户态实现文件系统，通过 app extension 交付，并可兼容 Mac App Store；它接入 Disk Arbitration、NetFS 和 `mount(8)`。[Apple FSKit](https://developer.apple.com/documentation/FSKit)
- **事实：** 当前 FSKit 只支持较简单的 `FSUnaryFileSystem` 流程；Apple 举例说明 HFS、FAT、ExFAT、NTFS 都属于“一资源、一卷”的典型形态。[Apple FSKit](https://developer.apple.com/documentation/FSKit)
- **事实：** 文件系统扩展声明 `com.apple.developer.fskit.fsmodule` entitlement。[Apple entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fskit.fsmodule)
- **事实：** 2026 年 FSKit 又引入 handler 协议替代部分 operations 协议，并增加数据缓存接口，说明 API 仍在演进。[FSKit updates](https://developer.apple.com/documentation/updates/fskit)
- **推断：** 直接把 `libntfs-3g` 接到 FSKit 在架构上合理，但需要自行实现完整节点生命周期、并发、缓存、错误映射、挂载/卸载与 NTFS 语义适配，工作量远超 GUI；不适合第一版。

### DriverKit 与通用 System Extensions：不是 NTFS 文件系统替代品

- **事实：** DriverKit 面向 USB、HID、网卡、串口、PCI、音频等设备驱动；System Extensions 主要承载 DriverKit、Network Extension、Endpoint Security 等低层服务。[Apple DriverKit](https://developer.apple.com/documentation/driverkit)；[Apple System Extensions](https://developer.apple.com/documentation/systemextensions)
- **结论：** 对“让一个已有块设备呈现 NTFS 卷”而言，FSKit 才是直接 API；DriverKit 不应作为本项目 NTFS 层的方案。

### 旧式内核扩展、安全策略与重启

- **事实：** Apple 建议尽量用用户态 system extension/DriverKit；若仍安装 kext，macOS 11 以后安装过程需要重启，用户还需要显式更改安全设置。[Apple：drivers, system extensions and kexts](https://developer.apple.com/documentation/systemextensions/implementing-drivers-system-extensions-and-kexts)
- **事实：** Apple silicon 安装 legacy kext 前必须切换到 Reduced Security，并允许用户管理来自已识别开发者的内核扩展。[Apple 支持](https://support.apple.com/guide/mac-help/change-security-settings-startup-disk-a-mac-mchl768f7291/mac)
- **事实：** Tuxera 2026 部署文档仍安装并验证 kernel extension；Paragon 当前公开安装文档也将方案描述为 KEXT-based。[Tuxera 部署](https://macsupport.tuxera.com/hc/en-gb/articles/360021071460-How-do-I-license-and-deploy-NTFS-for-Mac-in-an-organization-or-for-multiple-users)；[Paragon 安装](https://kb.paragon-software.com/article/4482)
- **事实：** Paragon 官方知识库明确给出 kext identifier `com.paragon-software.filesystems.ntfs`；它可进入当前冲突检测 allowlist。[Paragon KB](https://kb.paragon-software.com/article/2883)
- **事实更新：** 2026-08-31 已通过三家厂商当前官方制品和厂商文档核对 Paragon、Tuxera、
  iBoysoft 的精确 kext identifier 与 installed footprint；结果只关闭具名制品候选范围，不代表
  穷举全市场。具名范围模型和只读 footprint 探针已实现，但当前生产策略仍保持
  `activeScope == nil` 且环境基线未批准；因此依旧 incomplete，且 Gate 2 未通过。见
  [Setup 冲突驱动候选目录](setup-conflict-catalog.md)。
- **结论：** “无需用户降低安全策略”应成为本项目默认路径的硬要求。

### 签名、公证与沙盒

- **事实：** App Store 外分发的 Developer ID 软件应公证；Apple 公证会扫描恶意组件和签名问题，并由 Gatekeeper 验证。新的或更新的 kext 必须公证。[Apple Notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- **事实：** System Extension 要求有效签名、匹配 entitlement，并通过 App Store 分发或公证。[Apple System Extensions](https://developer.apple.com/documentation/systemextensions)
- **事实：** Apple 的 Disk Arbitration 指南指出，沙盒应用虽可接收磁盘出现/消失通知，但若没有对应 security-scoped bookmark，能做的操作有限。[Disk Arbitration Programming Guide](https://developer.apple.com/library/archive/documentation/DriversKernelHardware/Conceptual/DiskArbitrationProgGuide/Introduction/Introduction.html)
- **未知：** 采用“macFUSE FSKit 后端 + NTFS-3G 进程”时，App Sandbox、原始块设备授权和自动接管系统只读挂载的最终组合，需要用签名原型验证；不能仅凭 FSKit 可进 Mac App Store就推断整个产品可沙盒化。

## macFUSE 与 NTFS-3G

### macFUSE 5

- **事实：** macFUSE 让普通用户态进程实现文件系统，当前仓库列出支持 macOS 12 到 27、Intel 与 Apple silicon。[macFUSE repository](https://github.com/macfuse/macfuse)
- **事实：** macFUSE 5 有两个后端：默认 VFS/kext 后端，以及通过 `-o backend=fskit` 选择的 FSKit 后端。[FUSE Backends](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)
- **事实：** FSKit 后端需 macOS 15.4 及以后，不需要 kext 或恢复模式安全设置；内核后端功能更全、官方称性能更好，但需要允许 kext。[Getting Started](https://github.com/macfuse/macfuse/wiki/Getting-Started)
- **事实：** FSKit 后端当前只支持 `/Volumes` 下挂载；文件总以读写方式打开；FUSE notification、`fuse_context_t` 和许多内核处理的挂载选项尚未实现；官方称性能尚不及内核后端。[FUSE Backends](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)
- **事实：** 当前仓库只公开部分用户态组件源码，其他组件包括内核扩展为闭源；将 macFUSE 与商业软件捆绑需要付费许可。[Open Source Status](https://github.com/macfuse/macfuse/wiki/Open-Source-Status)
- **未知：** 当前上游 NTFS-3G 在 macFUSE FSKit 后端下的全部操作和卸载/休眠稳定性没有官方兼容矩阵。

#### 2026-08-31 当前版本风险快照

- **事实：** 官方 release 页当前仍把 **macFUSE 5.3.3** 标为最新版本；该版发布于 2026-07-04。它是本项目当前的最低检测基线，不是“可以在真实数据盘投入使用”的批准版本。[macFUSE releases](https://github.com/macfuse/macfuse/releases)
- **事实：** 5.3.3 有一个仍开放的 sshfs 回归报告：挂载可能不可浏览，正常终止可能无法卸载并留下只能重启清理的 mount 记录。它不是 NTFS-3G 的直接复现，但证明同一 libfuse/macFUSE 生命周期路径仍可能出现严重回归，因此本项目必须单独验证退出、卸载和残留清理。[macFUSE #1180](https://github.com/macfuse/macfuse/issues/1180)
- **事实：** 两个 FSKit 模块 `io.macfuse.app.fsmodule.macfuse-local` 与 `io.macfuse.app.fsmodule.macfuse` 都曾复现“首次执行文件返回 EIO”的问题；该问题已关闭并列入 **5.4.0** milestone。[macFUSE #1181](https://github.com/macfuse/macfuse/issues/1181)
- **事实：** 5.3.3 的 FSKit 模块曾可因合法的零字节短读崩溃，导致整个卷持续返回 EIO，直到手动卸载；该问题也已关闭并列入 **5.4.0** milestone。[macFUSE #1188](https://github.com/macfuse/macfuse/issues/1188)
- **结论：** 当前发布列表尚无 5.4.0，这是一项必须带入[分阶段实施计划 Gate 2](../engineering/implementation-plan.md#gate-2磁盘镜像上的挂载引擎)的阻塞性证据。后续即使 5.4.0 发布，也只能先作为新的候选固定版本，在一次性镜像上完成内容、卸载、崩溃和 Windows 复核矩阵后，再由实施计划判断是否满足 Gate；本文不单独更新 Gate 状态。

##### 2026-09-01 复查（无变化）

- **事实：** GitHub Releases API 复查，macFUSE 官方 `latest` 仍为 **5.3.3（2026-07-04）**，无 5.4.0 或更新正式版；5.3.0–5.3.2 标记 pre-release。
- **事实：** #1188 于 2026-08-10、#1181 于 2026-08-30 已 closed，两者 milestone 均为 **5.4.0**；#1180（sshfs 卸载残留）仍 open。因此数据面回归已在源码修复但没有进入任何已发布版本。
- **事实：** `macfuse-5.3.3.dmg` SHA-256 `7a0b7b66c0e7f8932707d1215dc9cf486e178d097ae0a2dcdf17d8530566aa15`，15,802,030 字节。DMG 内代码签名 identity 本轮未核对。
- **结论：** 依赖阻塞状态与 2026-08-31 完全一致，出处细节与版本监视触发器记入[依赖供应链记录](../operations/dependency-supply-chain.md#2026-09-01-候选制品出处快照)。

##### 2026-09-08 复查（5.4.0 已发布，仍 pre-release）

- **事实：** macFUSE **5.4.0** 于 2026-09-07 发布，GitHub Releases API 标记
  `prerelease = true`；官方 `latest` 稳定版仍为 5.3.3。
- **事实：** 5.4.0 release note 的「`FSModule`（`FSKit` Backend）」小节明确列出并归属
  #1181、#1187、#1188 三项修复；对应 issue 分别于 2026-08-30 / 08-25 / 08-10 closed，
  milestone 均为 5.4.0。**#1187（1–14 字节 `write(2)` 被零填充、静默数据损坏）是本文
  之前未单独记录的第三项 FSKit 数据面回归。**
- **事实：** `macfuse-5.4.0.dmg` 的 GitHub asset digest 为 SHA-256
  `861814f0ac7fa8f6547ea40cdd49a36ac84bcc7d34f38a1fa74e8cf68b0401c5`，16,512,456 字节；
  本轮未下载核对，也未核对 DMG 内代码签名 identity。
- **事实：** 5.4.0 的 FSKit 后端改用 Xcode 27.0 / macOS 27 SDK 构建，新增 macOS 27
  FSKit 卷操作 API 并保留对更早 macOS 的兼容；`MFMount.framework` 声明其 API 未来仍可能变化。
- **事实：** #1180（sshfs 卸载残留）仍 open、无 milestone。
- **结论：** 版本监视触发器要求「非 pre-release 的 5.4.0+ 且 release note 确认修复」，
  当前只满足后半条；Gate 2 依赖批准仍被阻塞。等 5.4.0（或更新版）转正式版后，作为
  新的精确候选走 DMG 代码签名核对与 Gate 2 镜像矩阵。出处细节记入
  [依赖供应链记录](../operations/dependency-supply-chain.md#2026-09-08-候选制品出处快照)。

### NTFS-3G

- **事实：** 官方仓库将 NTFS-3G 定义为跨 Linux、FreeBSD、macOS 等平台的用户态 NTFS 读写实现；支持基本文件/目录操作、硬链接、流、稀疏与压缩文件、扩展属性和权限等。[NTFS-3G README](https://github.com/tuxera/ntfs-3g/blob/edge/README)
- **事实：** 截至本调研，官方最新 release 为 **2026.7.7 安全发布**；它修复了多项处理恶意或损坏文件系统时的越界访问、缓冲区溢出和堆内存破坏问题。2026.2.25 是同年的稳定功能发布，项目仍在维护，同时也证明 NTFS 元数据必须视为不可信输入。[NTFS-3G releases](https://github.com/tuxera/ntfs-3g/releases)
- **事实更新（2026-09-01 复查）：** 官方 `latest` 仍为 **2026.7.7（2026-07-15）**。源码归档 `https://tuxera.com/opensource/ntfs-3g_ntfsprogs-2026.7.7.tgz` 的 SHA-256 为 `d67b769025d32860549d35c2147e45024d172f81c540d750390ce3602c059dab`，git tag 指向 commit `d327833ec1d5eb1358b6f2c37139f10a3460944d`；该版共修复 9 项 CVE（CVE-2026-42616 等），全部与解析恶意/损坏文件系统有关。详见[依赖供应链记录](../operations/dependency-supply-chain.md#2026-09-01-候选制品出处快照)。
- **事实：** NTFS 驱动、工具和 `libntfs-3g` 为 GPL v2 或以后；`fuse-lite` 为 LGPL v2。[NTFS-3G README](https://github.com/tuxera/ntfs-3g/blob/edge/README)
- **事实：** 官方手册说明：休眠卷会拒绝可写挂载并强制只读；`remove_hiberfile` 会丢失 Windows 休眠会话；`recover` 会清 Windows 日志并可能引发不一致，而且当前是默认选项；`norecover` 则拒绝挂载未正常卸载的卷。[NTFS-3G Manual](https://github.com/tuxera/ntfs-3g/wiki/Manual)
- **结论：** MVP 必须显式覆盖上游偏宽松的默认值：使用 `norecover`，绝不使用 `remove_hiberfile`，并在脏卷或休眠卷上只提供只读与修复指引。

### 许可影响

- **个人本机使用：** 私下运行或修改开源组件与“向他人分发”是不同场景；本文不发现需要为纯本机原型购买商业驱动许可。
- **分发：** 若把 NTFS-3G 二进制或修改版随应用交付，需要履行 GPL 对相应源码和许可告知的义务；若捆绑 macFUSE，也必须核对其二进制再分发条款。商业分发还触发 macFUSE 明确的商业许可要求。
- **Mounty：** 官网禁止未授权再分发，因此不能把 Mounty 本体直接打进安装包。[Mounty](https://mounty.app/)
- **说明：** 这是工程风险提示，不是法律意见；公开发布前应单独完成依赖许可证审查。

## 技术路线比较

| 路线 | 用户体验 | 工程量 | 已知代价 | 建议 |
| --- | --- | --- | --- | --- |
| A. NTFS-3G + macFUSE 5 FSKit backend | 无 kext、无 Reduced Security；原生 `/Volumes` | 中 | macOS 15.4+；功能/性能限制；NTFS-3G 全量兼容未知 | **首选 1 周技术验证** |
| B. NTFS-3G + macFUSE kernel backend | 功能最全，官方称性能更好 | 中 | Apple silicon 需 Reduced Security、批准 kext、重启；内核面风险更高 | **本产品拒绝** |
| C. `libntfs-3g` 直接接 FSKit | 最原生，可绕开 macFUSE 运行时 | 很高 | 自行承担全部文件系统适配、缓存和兼容性；GPL 分发义务 | **长期方向，不进 MVP** |
| D. 替换系统 `mount_ntfs`、关闭 SIP 或依赖 Apple 隐藏写入 | 表面自动 | 高风险 | 修改系统组件、升级脆弱、安全边界差；Mounty 也已在 Ventura 后放弃旧路径 | **拒绝** |

### 推荐架构

```text
状态菜单入口 + C 版主窗口（SwiftUI / AppKit）
  ├─ ReadOnly candidate 展示（零 mutation 资格）
  ├─ 当前连接 Data Volume Declaration resolver
  ├─ VolumeCoordinator
  │    ├─ Disk Arbitration 事件与挂载/卸载/推出
  │    ├─ 每个物理磁盘串行状态机
  │    └─ MountEngine 接口
  │         ├─ NTFS-3G + macFUSE FSKit（默认候选）
  │         └─ 不支持 kext；FSKit Gate 失败则停止发布并重新评估
  ├─ 窄权限 helper / XPC（只接受结构化磁盘操作）
  └─ Diagnostics（环境、版本、结果码、固定字段白名单）
```

- **事实：** Disk Arbitration 可监听磁盘出现、变化、消失，以及执行 mount、unmount、eject；这些操作均有异步回调。[Apple DiskArbitration.h](https://developer.apple.com/documentation/diskarbitration/diskarbitration-h)
- **推断：** UI 不应解析命令行文本决定状态；底层结果要映射成结构化状态和稳定错误码。
- **推断：** helper 不接受任意 shell 字符串、裸磁盘标识或读写模式，只接受协调器签发的四种固定
  语义动作和完整卷/物理盘实例；路径和参数不能由 UI 或 helper 消息拼接。
- **推断：** 按物理磁盘串行操作，避免“自动挂载、用户点击、系统弹出”同时争夺同一设备。
- **推断：** 每次启动都从系统实际挂载表重建状态，不信任上次退出前缓存，以便从崩溃、强拔盘或升级后恢复。

## 产品范围

### P0：第一版必须有

1. 检测外接 NTFS 卷；正式 UI 只显示卷名、运行期物理盘序号、用途确认状态和当前
   “只读/已有可写挂载/未挂载”，不显示原始设备名或挂载路径。
2. 外置用途默认 unknown；只读 candidate 可见但无变更资格。只有当前连接固定声明与 fresh
   candidate、精确 sibling 和系统事实一致后，健康卷才可进入“启用写入”。
3. 脏卷、休眠卷、内部或其他通用 `protected` 卷默认拒绝写入；给出可执行的 Windows 处理说明，
   不声称系统能精确识别 Boot Camp。
4. 标准卸载与安全推出；忙碌时不强制，明确显示“仍有应用正在使用”。
5. 首次设置检查：macOS 版本、CPU 架构、macFUSE/NTFS-3G 版本、后端、签名/权限、冲突驱动。
6. 每次切换为可写都由用户明确触发；MVP 不保存自动可写策略或 data-role 声明。
7. 结构化错误：缺依赖、冲突驱动、卷不干净、Windows 休眠、设备忙、权限失败、引擎退出、超时。
8. 可复制、可导出的固定字段诊断摘要；不提供任意日志文本收集通道。

### P1：稳定后再加

- 登录时启动。
- 插盘、挂载失败、可安全移除的系统通知。
- 每卷“始终只读”偏好；不得用“每次询问”持久记录 data-role，且不提供自动可写。
- FSKit 兼容性与升级告警；不提供内核后端或 Reduced Security 回退。
- 版本检查与兼容性告警；不静默替换底层驱动。

### 明确不进 MVP

- NTFS 格式化、分区、擦除、文件系统修复。
- 删除休眠文件、自动清日志、强制恢复、默认强制卸载。
- Boot Camp 启动盘切换、内部 NTFS 系统盘写入。
- BitLocker、磁盘加密、数据恢复。
- 自建文件管理器、Spotlight 管理、测速排行榜。
- 自动修改 `/sbin/mount_ntfs`、关闭 SIP 或替用户切换启动安全策略。

## UI 指导

### 信息架构

- **选择 C 版后，单窗口是主界面。** 左侧显示磁盘与设置分类，右侧一次解释一个目标；菜单栏只保留当前文字状态、刷新、打开窗口和退出。
- **设置向导只在首次运行或环境失效时出现。** 正常情况下不增加第二套大型控制面板。
- **详细信息与诊断复用主窗口。** 危险动作和长文本不塞进菜单栏，也不复制成另一套状态逻辑。
- **所有状态都有文字。** 颜色和图标只能辅助，不能单独表达“可写、只读、危险、处理中”。

### 菜单栏草图

```text
NTFS 轻量助手
检测到 1 个 NTFS 卷，1 个用途未确认
[打开 NTFS 轻量助手]
[重新读取]
退出
```

风险状态也只给汇总并引导进入主窗口，不在菜单栏复制磁盘动作：

```text
NTFS 轻量助手
有 1 个卷需要处理
[打开 NTFS 轻量助手]
```

### 交互规则

1. 主按钮使用动作文字，例如“启用写入”“重试挂载”“安全推出”，不要只写“继续”。
2. 处理中显示具体阶段：“正在卸载系统只读卷”“正在启用写入”“正在同步并推出”。
3. Disk Arbitration 命令成功只触发复核；只有新的完整系统观察确认整块物理盘已消失后才显示“可以拔出”。
4. 标准卸载失败时显示占用原因；不自动终止应用，不把“强制推出”放在主路径。
5. 每次启用写入都要求用户明确点击，并提交当前连接固定语义声明；不提供“今后自动启用写入”，
   声明在重插、重订阅、拓扑变化、应用重启或一次消费后失效。
6. 设置中显示唯一允许的后端 `FSKit`；检测到内核扩展或冲突驱动时阻止写入并给出移除说明。
7. 日志导出前预览固定字段；诊断模型从不接收卷名、路径、文件名、文件内容或 stderr，不能依赖
   事后脱敏。

## 稳定性设计

### 强制不变量

- 一块 Physical Disk 同一时刻最多有一个变更任务；所有 sibling 共享租约。
- 未确认完整 Volume/Disk Instance、Media Generation、精确 sibling、NTFS、挂载状态和当前请求
  的一次性声明前不执行写入流程；外置位置本身不证明 data。
- 休眠、Fast Startup、dirty flag、无法判断健康状态时一律不写。
- 默认 mount 参数显式使用 `norecover`；不把 NTFS-3G 当前 `recover` 默认带入产品。
- 不自动使用 `allow_other`；仅让当前用户访问，除非有明确需求和单独安全评审。
- 不对内部或其他 `protected` 卷启用写入。
- 不在仍挂载时杀死 NTFS-3G 进程；先正常卸载，失败则保持错误状态。
- 不把“命令返回 0”直接等同“可安全拔出”；以实际挂载表和 Disk Arbitration 回调复核。

### 挂载流程

```text
检测磁盘
  -> 核对完整外置 NTFS candidate 与精确 sibling 拓扑
  -> 用户提交当前连接固定 data/not-Windows-system 声明
  -> resolver 以 fresh candidate 与完整系统事实核对本次请求
  -> 检查冲突驱动、后端和权限
  -> 判断 dirty / hibernated / 已挂载状态
  -> 正常卸载 Apple 只读挂载
  -> 以安全参数启动 NTFS-3G
  -> 复核实际挂载点、文件系统类型和只读/可写标志
  -> 更新 UI
```

Tuxera 官方说明多个 NTFS 驱动会互相冲突，因此冲突检测应是写挂载前置条件，而不是失败后的排障建议。[Tuxera 冲突说明](https://macsupport.tuxera.com/hc/en-gb/articles/360021071760-Help-I-am-getting-the-error-message-Too-many-layers-in-remote-path)

### 推出流程

```text
冻结该卷的新操作
  -> 请求整块物理盘标准 unmount（不使用 force）
  -> 读取完整 sibling inventory，确认所有子卷均未挂载
  -> 请求 eject 整块物理磁盘
  -> 重新读取完整物理盘状态，确认介质已消失
  -> 显示“可以拔出”
```

Apple 将强制卸载定义为“即使仍有活动文件也卸载”，因此它不适合作为默认按钮。[DADiskUnmountOptions](https://developer.apple.com/documentation/diskarbitration/dadiskunmountoptions)

### 诊断最小字段

- 应用版本/构建、macOS 版本和 CPU 架构。
- 经过可信读取器确认的 macFUSE、NTFS-3G 版本、实际后端、File System Extension 状态，以及固定 Setup 问题码和冲突数量；不记录驱动原名。
- inventory 完整性、物理盘/卷数量和固定观察问题码。
- 未来变更诊断只记录本次运行内的数字别名、介质代次、封闭状态/原因/阶段/结果码、布尔事实、时间/耗时和数值退出状态。
- 不记录卷标、用户名、BSD 名、磁盘或卷 UUID、任何路径、文件名、文件内容或任何 stderr 文本；不存在“先收集再脱敏”的自由文本通道。

## 验证计划与发布门槛

本节保留调研产生的验证依据，不定义仓库 Gate。实际分配、前置和当前状态见[分阶段实施计划](../engineering/implementation-plan.md)。

### 技术底座验证依据

使用一次性 NTFS 磁盘镜像和可牺牲物理盘，固定 NTFS-3G 与 macFUSE 版本，验证：

- `backend=fskit` 在 macOS 15.4+ 的真实挂载类型。
- 创建、覆盖、追加、rename、delete、目录遍历、Unicode、长文件名、稀疏/压缩文件、扩展属性。
- `fsync` 后标准卸载，在 Windows 上运行 `chkdsk` 并做内容哈希比对。
- dirty、hibernated、Fast Startup 状态是否可靠拒绝可写。
- 连续挂载/卸载 100 次、睡眠/唤醒、多卷并发和应用崩溃后恢复。

**停止条件：** 任一测试出现无法解释的数据不一致、卷无法在 Windows 干净检查、或 FSKit 后端不能可靠卸载，则不进入挂载、卸载、推出或写入 UI 入口开发。

### 状态机和错误 UX 验证依据

- 单元测试覆盖每个状态和重复事件：出现、消失、系统先挂载、用户重复点击、超时、进程退出。
- 集成测试确保不会并发操作同一物理盘。
- 所有错误都映射为稳定错误码、用户可理解文字和下一步；诊断不接收或记录原始 shell/stderr 文本。
- 强拔盘、忙碌文件、USB hub 断连、睡眠中拔盘后，重新启动应用可从系统真实状态恢复。

### 实机验证矩阵

- macOS 15.4 的最后安全更新、macOS 26 的最后稳定更新；Apple silicon 为主。
- 若承诺 Intel，则单独实测，不能只依赖依赖项页面的兼容宣称。
- USB HDD、USB SSD/NVMe、U 盘/SD 卡；GPT 与 MBR；单卷和多分区。
- 1 个超大文件、10 万小文件、Finder 拖放、覆盖、废纸篓、应用直接编辑保存。
- 对相同数据集记录吞吐、CPU、内存和卸载耗时；结果仅与本项目历史基线比较，不复述商用营销数据。

### 发布硬门槛

- 默认路径不要求 Reduced Security、关闭 SIP 或替换系统文件。
- dirty/hibernated 卷的可写阻断测试 100% 通过。
- 每次成功推出后系统挂载表无残留，应用不提前提示拔盘。
- 测试数据在 macOS 写入、Windows `chkdsk` 后哈希一致。
- 诊断只包含固定字段白名单，且不含卷标、用户名、BSD 名、磁盘或卷 UUID、路径、文件名、文件内容或任何 stderr 文本。
- 卸载应用后没有残留启动项、helper 或驱动；依赖若为用户独立安装，要明确保留或单独卸载。

## 建议的第一阶段开发决策

本节是调研阶段形成的历史推进建议；当前完成度与下一任务以实施计划和 MAP 为准。

1. 最低系统先定为 **macOS 15.4**，只支持 Apple silicon；这是使用 macFUSE FSKit 后端、避免 kext 的最小合理范围。
2. 纯 `MountEngine` 契约、只读 C 版 App 与自动 UI 映射已实现；真实 adapter 仍由 Gate 1–3 阻塞。
3. 从 NTFS-3G 官方 release 为每个候选分别固定**精确版本、源码归档摘要、构建环境和最终产物摘要**；2026.7.7 当前只是一项未批准候选，任何更新版本都必须重新建立独立候选记录并完成 Gate，不能因版本号更高自动接受。不要把第三方 Homebrew tap 当唯一供应链。
4. 第一阶段要求用户单独安装官方 macFUSE，应用只检测，不静默下载安装；是否捆绑留到许可证和公证验证之后。
5. 当前只读产品是 C 版主窗口加文字状态菜单；挂载、卸载、推出和写入入口只有在
   [分阶段实施计划](../engineering/implementation-plan.md)规定的 Gate 1–3 全部通过后才能加入。
   FSKit 路线若未满足对应 Gate，则停止变更能力开发并重新评估，不回退到 kernel backend。
6. 第一版只做经当前连接声明和 fresh 事实共同核对的外置数据盘；内部/受保护卷、用途 unknown
   candidate、修复和格式化保持禁用。

## 未决风险

1. **NTFS-3G × macFUSE FSKit 兼容性：** 官方资料分别支持该架构，但没有当前端到端认证；必须实测。
2. **FSKit 后端成熟度：** 官方明确存在性能与语义限制；2026 年 API 仍有演进。
3. **权限与沙盒：** Disk Arbitration、原始块设备、自动接管只读挂载与 App Sandbox 的组合尚未证明。
4. **供应链：** Mounty 推荐的 NTFS-3G macOS 包来自第三方 Homebrew tap；稳定版应自行固定、构建、签名和记录来源。
5. **许可：** NTFS-3G GPL 与 macFUSE 再分发条款会影响打包方式；个人自用原型和公开分发要分别设计。
6. **当前商用品资料矛盾：** Paragon 的 Tahoe 产品页与版本支持矩阵、iBoysoft 的“无需 kernel extension”与 Advanced 模式说明不完全一致，不能据此反推其当前内部实现。
7. **性能未知：** 没有可直接采用的当前横向基准；FSKit 后端是否足够个人大文件/小文件工作负载只能实测。
8. **恶意/损坏卷安全：** NTFS 解析处理不可信磁盘元数据，必须把模糊测试、崩溃隔离和版本升级纳入长期维护。
9. **人为用途判断：** Apple 系统事实不能可靠区分普通外置数据盘与外置 Windows 系统盘；一次性
   声明能阻止自动误分类和旧判断复用，但不能消除用户误认。若不能接受该风险，产品必须永久只读。

## 一手来源清单

### Apple

- [If your Mac can’t save files to an external drive](https://support.apple.com/en-ie/101830)
- [FSKit](https://developer.apple.com/documentation/FSKit)
- [FSKit updates](https://developer.apple.com/documentation/updates/fskit)
- [FSKit module entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fskit.fsmodule)
- [DriverKit](https://developer.apple.com/documentation/driverkit)
- [System Extensions](https://developer.apple.com/documentation/systemextensions)
- [Implementing drivers, system extensions, and kexts](https://developer.apple.com/documentation/systemextensions/implementing-drivers-system-extensions-and-kexts)
- [Change startup-disk security settings on Apple silicon](https://support.apple.com/guide/mac-help/change-security-settings-startup-disk-a-mac-mchl768f7291/mac)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Disk Arbitration](https://developer.apple.com/documentation/diskarbitration)
- [Disk Arbitration Programming Guide](https://developer.apple.com/library/archive/documentation/DriversKernelHardware/Conceptual/DiskArbitrationProgGuide/Introduction/Introduction.html)

### 开源技术底座

- [macFUSE repository](https://github.com/macfuse/macfuse)
- [macFUSE Getting Started](https://github.com/macfuse/macfuse/wiki/Getting-Started)
- [macFUSE FUSE Backends](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)
- [macFUSE Open Source Status](https://github.com/macfuse/macfuse/wiki/Open-Source-Status)
- [NTFS-3G repository](https://github.com/tuxera/ntfs-3g)
- [NTFS-3G releases](https://github.com/tuxera/ntfs-3g/releases)
- [NTFS-3G README and licenses](https://github.com/tuxera/ntfs-3g/blob/edge/README)
- [NTFS-3G Manual](https://github.com/tuxera/ntfs-3g/wiki/Manual)

### 产品

- [Paragon Microsoft NTFS for Mac](https://www.paragon-software.com/home/ntfs-mac/)
- [Paragon supported OS versions](https://kb.paragon-software.com/article/571)
- [Paragon installation](https://kb.paragon-software.com/article/4482)
- [Paragon verbose logs](https://kb.paragon-software.com/article/8138)
- [Microsoft NTFS for Mac by Tuxera](https://ntfsformac.tuxera.com/)
- [Tuxera system requirements](https://macsupport.tuxera.com/hc/en-gb/articles/360020979699-What-are-the-system-requirements)
- [Tuxera release notes](https://macsupport.tuxera.com/hc/en-gb/articles/4406039424146-Release-notes)
- [Tuxera diagnostics](https://macsupport.tuxera.com/hc/en-gb/articles/360021094159-How-do-I-gather-useful-information-for-troubleshooting)
- [iBoysoft NTFS for Mac](https://iboysoft.com/ntfs-for-mac/)
- [iBoysoft online help](https://iboysoft.com/ntfs-for-mac/online-help.html)
- [iBoysoft release history](https://iboysoft.com/ntfs-for-mac/upgrade-history.html)
- [Mounty for NTFS](https://mounty.app/)
