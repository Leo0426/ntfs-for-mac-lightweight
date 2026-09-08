# NTFS for Mac Lightweight — 分阶段实施计划

本文件是仓库中 **Gate 编号、定义、前置关系和当前状态的唯一来源**。PRD、调研、README 与 ADR 只能引用这里的 Gate，不得另行编号、改写状态或宣称通过；只有取得本文件要求的实物证据后才能更新“当前 Gate 状态”。

## 当前基线

已完成：

- 商业产品与平台技术调研。
- MVP 范围和 UI 状态规范。
- UI 方向已选择 C 版“磁盘列表 + 状态详情”；菜单栏仅作为常驻入口。
- 纯 Swift 写入与安全推出状态机。
- 每块物理盘单操作 actor、内部操作 ID、介质代次与一次性执行授权。
- package-only `MountEngine` 深模块契约：只接受协调器领取的四种固定语义 `MutationCommand`
  与完整卷/物理盘实例；结果区分直接退出、超时后已确认静止、取消后已确认静止和终止未确认，
  并携带必须重新读取的卷或整盘证据范围。engine 入口与兼容闭包共用最终预检和一次性消费；
  兼容闭包也必须显式返回 `MountEngineTermination`，不能由 `Void` 自动推断静止；
  终止未确认继续持有整盘租约且不能被成功或静止回调绕过。当前没有真实执行 adapter。
- `NTFSLiteMutationPreparation` 内的 `MountEngineAdapter` 骨架：承担 adapter 的**纯逻辑**一半——
  `MountEngineActionPlanner` 把已领取命令分类为具名 `MountEngineAction`（可写挂载把编译推迟到
  执行边界，避免可信制品证据在“已规划”与“已启动”之间失效），`MountEngineTerminationMapper`
  只从 positive reap 或已触发的 Disk Arbitration 回调断言静止，deadline / 取消 / 已发信号都不
  推断子进程已停止。真正的启动与等待通过注入的 `Executor` 提供；本模块**不含**任何基于
  `Process` 或 Disk Arbitration 的 executor（属未来带 FD 绑定启动边界、且过 Gate 的 target），
  `MountEngineAdapter.executionUnavailable` 对每个命令都失败关闭为 `.terminationUnconfirmed`。
- 实时 Setup 门禁、整盘 sibling 保护、超时后的进程收敛与重新观测状态。
- 首次设置条件评估与 `SetupPresenter` 文字映射：固定顺序、刷新 fail-closed、明确下一步和冲突驱动脱敏。
- 一次性 C 版 SwiftUI 场景原型：纯内存 fixture，覆盖全部 24 个 `VolumeState`、多物理盘分组和同盘 busy；它不等同于 Gate 4 正式 UI。
- 公共接口行为检查框架与严格 Release 构建流程。
- `NTFSLiteSystem` 只读系统层：Disk Arbitration 出现、描述变化与消失事件流，明确
  `VolumeNetwork=true` 的范围外网络卷排除，连续稳定的真实 mount table 读取，以及独立 IOKit
  `IOMedia` 精确枚举。网络标记只接受 CFBoolean；未知类型不会被乐观排除。
- 只读系统证据映射与整盘 inventory：核对物理盘/子卷关系、来源设备、挂载读写标志、后端、规范路径和符号链接；缺失或矛盾证据不生成可信 `VolumeSnapshot`。
- 受保护角色与只读候选分流：可信内部位置只建立通用 `protected` 边界，不声称精确识别
  Boot Camp；外置 NTFS 的系统用途默认保持 unknown。只有其余身份、拓扑和挂载事实全部完整时
  才生成独立 `ReadOnlyVolumeCandidate` 供界面显示，候选不能进入 mutation inventory。
- 当前连接数据卷声明的纯 Core 契约：固定语义绑定 session/revision、完整卷/整盘实例、精确
  sibling 集合与一次性 nonce；重插、克隆、重订阅、应用重启、拓扑变化、受保护/矛盾/不完整
  事实和重放均失败关闭。`DataRoleApproval` 不可公开构造，也不是 System Evidence 或变更资格。
- 只读 observer 的初始枚举收敛与变更去抖：callback 静默只形成 Observation Settlement；只有连续稳定的独立 IOKit 快照与 Disk Arbitration 集合完全一致时才升级为精确覆盖。超时、集合变化、空回调未获独立证明或其他不完整证据都会发布固定问题码而非伪造默认值。
- 物理盘代次规则：同盘多个子卷和重复 callback 共享代次，只有确认整盘消失后再次出现才轮换。
  `ReadOnlyDiskInventory` 是唯一 source of truth，未接生产路径的平行 `MediaGenerationTracker` 已删除。
- Setup 系统事实的第一阶段适配：读取当前系统与架构、规范化注入的依赖版本事实，并在授权、扩展、依赖、实际后端或冲突扫描未被证明时失败关闭；mapper 不再默认宣称 FSKit。正式 App 直接消费 typed report，UI 会区分“未配置策略”和各可信读取器的固定失败码，授权由可注入 typed provider 提供。
- 固定语义只读命令探针、严格输出解析，以及当前 Mac 上的只读 Disk Arbitration、IOKit、mount table 和 Setup smoke checks；输出超限、超时、取消、继承管道和终止未确认都在固定墙钟上界内失败关闭。
- 正式本地只读 C 版应用：AppKit 文字状态菜单入口、按物理盘分组的单窗口 SwiftUI C 布局、实时只读 observer、Setup 窗口内下一步/重新检查/复制诊断、刷新和窄窗口适配；界面没有磁盘变更操作。
- C 版只读 UI 自动映射基线：Release 行为检查覆盖全部 24 个 `VolumeState` 的固定动作与 busy 禁用矩阵、长卷名与多分区确定分组/排序、多卷物理盘的唯一隐私安全 sibling 序号、用户卷名碰撞反例、跨物理盘同名卷的“物理磁盘 N，卷标题”选择标签、按完整选择身份触发的辅助功能事件、连续刷新不重用旧目标、保留/展示选择分离、失效导航焦点回落和宽窄布局焦点转移，以及 Setup/诊断可见文字与辅助功能公告同值。
- 结构化诊断：固定字段白名单、运行期数字别名、稳定 JSON、条目/编码字节/时间三重内存上限、一键清除和运行标识轮换；本地快照使用原子替换、generation 准入与 `0600` 权限，读取时限制 owner、普通文件、schema、canonical bytes、稳定文件身份、target 语义、大小和时间，拒绝清除后的旧保存、损坏、过期、未来时间、符号链接和不安全权限。清除只有在可信存档实际移除后才报告成功。原始卷名、用户名、任何路径、磁盘或卷 UUID、BSD 名和任何标准错误文本都不进入模型。
- 严格 Setup 输出解析与固定语义只读探针；未知记录、截断、非零退出和不完整冲突目录全部失败关闭。
- Gate 2 冲突检测的 typed 候选范围：精确绑定 macOS 15.4.0 / Apple Silicon、证据日期、
  三个候选制品的版本/摘要、loaded identifier 与固定 installed footprint；无 `Process` 的只读
  provider 区分 absent、presentConflict 与 incomplete。生产 `activeScope` 和环境基线仍未批准。
- 纯逻辑 NTFS 健康协议解析器和安全挂载调用编译器；它们只接受固定输入协议和 `rw,backend=fskit,norecover` 策略，不执行命令。
- helper v1 纯协议与单一原子准入边界：固定四种动作、完整卷/磁盘实例身份、4 KiB 原始消息上限、严格 JSON/嵌套重复键拒绝、schema/身份/action 核对、operation ID 原子消费、不可伪造的成功值和最小数值响应；decoder 与重放集合为模块私有，调用方不能拆开准入步骤。尚无 IPC/XPC、提权、安装、命令执行器或真实磁盘变更。
- 可信 macFUSE 读取器：逐层拒绝符号链接并核对 owner、写权限、大小、bundle ID 与严格版本；
  每个批准版本必须对应唯一 requirement、Team ID 和 CodeDirectory identity，目录键必须与
  版本 allowlist 完全一致。Security framework 从同一个已验证 `SecStaticCode` 读取 secured
  Info.plist identifier/version，并与文件系统事实及所选版本条目一致后才报告可信。实时 Setup
  未配置经一手资料批准的完整目录时不报告可信版本。
- 可信 NTFS-3G 制品解析器：从同一个已打开文件描述符核对普通文件、owner、执行权限、不可被组/其他用户写入、大小与固定 SHA-256 allowlist，再以完整的“哈希 → 语义版本”目录解析版本；不执行工具，目录缺失、目录与 allowlist 不一致或文件发生变化时失败关闭。安全挂载编译器只接受协议模块内部构造的可信制品能力，绑定路径、哈希、字节数和版本，并在编译时重验。
- package 只读边界：变更请求和挂载调用编译器位于独立产品 `NTFSLiteMutationPreparation`；正式 `NTFSLiteReadOnlyApp` 的依赖图不包含它或 `NTFSLiteHelperProtocol`。唯一的 `Process` 运行器位于非产品 `NTFSLiteReadOnlyProbing` target，只支持固定语义、固定输出保存容量与墙钟上界的只读 Setup 探针。
- 独立 Gate 1 证据工具链：`NTFSLiteGateEvidence` 把 typed inventory 观察和封闭操作者检查点投影为
  匿名、有界的 schema 2 bundle；Evidence-ID 只接受 `G1-` 加 32 位大写十六进制的无语义值。
  首个完整 candidate 绑定单一匿名 target，100 轮不能聚合不同物理盘；常驻内置盘不进入 target
  未确认连接计数。只有先有 verified absence baseline，且该轮从 verified candidate 出现连续到
  verified absence 才结算 cycle；启动时已插盘的首次连接不计数。两项逐轮 comparison 必须位于
  该轮 present/absence 窗口内，unverified pending 只暂停对照和结算。介质代次异常、时间倒退、
  多 target/拓扑矛盾或容量超限均永久失败关闭。100-cycle、多分区、全部逐轮对照和场景检查点
  满足后，仍只有 canonical observations 最后一帧 `coverage=verified` 才可产生
  `readyForHumanReview`；无 failure code 但最后一帧 unverified 只能 `incomplete`，类型中不存在
  `pass`。
- 本地 `NTFSLiteGate1EvidenceTool` 可从正式只读 observer 采集并封存 sorted-key canonical JSON，
  把状态/摘要与 artifact 分离到标准错误和标准输出；`verify` 会核对 SHA-256、严格 JSON、schema、
  canonical bytes、派生字段与事件重放。证据和 helper 共同复用中立的 `NTFSLiteStrictJSON` 语法
  边界，但彼此没有依赖；正式 App 也不依赖证据模块或 CLI。采集必须收到显式 `seal` 才输出
  artifact；封存不会取消 observation task，而是先在 Disk Arbitration 专用串行队列 stop-and-drain，
  在 `drainBoundary` 后强制完成最终 settle 与独立 IOKit enumeration，并让最终 observation 与
  capture terminal 通过同一 FIFO 后才排入 recorder seal。自然 source end 或未验证的最终
  observation 都永久失败关闭。命令输入 EOF 或读取失败会在封存前退出且不输出 canonical bytes。
  verifier 不信任 bundle 自报 verdict，会从 canonical observations 独立重算最后一帧 coverage 与
  其他派生条件。
- 正式只读 Store 的订阅代次与恢复：连续刷新使用不可溢出的随机 token，旧任务结果和旧事件源终止均不能覆盖当前订阅；当前事件源正常结束或抛错都降级为 unavailable，系统唤醒会重新订阅。observer 的 source-finished、settlement 和 event 进入同一串行输入状态机。手动、通知和系统唤醒触发的每次新订阅都同时轮换 opaque selection-reset epoch，即使新订阅复用相同 BSD 名、UUID 和 generation=1，旧选择也必须回到概览；同一 epoch 的 scanning 只保留 retained selection，详情、选择控件和公告消费的 presented selection 必须存在于当前 dashboard，否则回概览。导航焦点只在原本位于导航区时随失效展示项或 wide/compact 布局协调。
- 本地行为检查、严格 Release warnings-as-errors 构建与可重复的只读边界检查脚本；检查包含 helper 重复键/并发/容量、诊断存档权限/清除/语义完整性、非法观察身份、未识别事件、枚举覆盖未验证、旧刷新迟到、source 终止和零去抖首事件回归，并验证正式 App 依赖图不进入 mutation/helper target、固定 Setup 探针之外没有 `Process` 或磁盘变更 API。检查数量只以一次完整成功运行的实际输出为准。
- 本地交付地图、Gate 证据运行手册、依赖供应链记录模板，以及使用固定包 allowlist、特殊文件拒绝、Mach-O/Info.plist 平台核对、签名/哈希验证和五组负向 fixture 的只读 App 构建和回滚流程；这些流程交付物不等于依赖已批准或 Gate 已通过。
- `AGENTS.md` 已将 Codex 设为主要开发代理，并固化测试驱动与硬件 Gate 前不变更真实磁盘的规则。

尚未实现：

- 把当前连接的一次性 Data Volume Declaration 与 fresh 候选、精确 sibling 拓扑和正式写入请求
  接线；外置位置不会自动升级为 data，声明也不能伪装成 System Evidence。
- macFUSE、NTFS-3G 真实调用。
- helper 的真实 IPC/安装、签名、权限与公证。
- 能把已验证制品文件描述符一路绑定到实际启动，或提供等价失败关闭保证的执行器；当前编译结果虽然带执行前重验 Gate，仍明确保留最后一次路径解析的 TOCTOU，因此不得接真实执行。
- 只读 observer 到可变更 `VolumeCoordinator`、`MountEngine` 和只消费 `VolumePresentation` 的正式 Gate 4 UI 接线；正式只读 Store 已接通，但变更入口仍被有意省略。`MountEngineAdapter` 的纯逻辑骨架（命令路由 + 终止映射）已就位，仍缺注入的真实 `Executor`（真实执行须先过 Gate 并定义 FD 绑定启动边界）。
- 生产用可信策略仍未固定：尚未给正式应用配置经一手来源批准的 macFUSE 组合身份策略、
  NTFS-3G 可执行文件路径/SHA-256/版本目录和授权状态。Gate 2 具名候选范围与 footprint
  provider 的软件实现已完成，但仍缺 active scope 批准、具名镜像环境基线实证与真实 adapter；
  因此这些 Setup 能力继续保持未就绪。
- 正式依赖批准条目仍为空：记录格式、升级/回滚流程已有，但尚无通过 Gate 2 的 macFUSE/NTFS-3G 精确版本、源码与产物摘要。
- 在专用外置盘上运行 Gate 1 证据会话、保存逐轮外部系统对照并由人工签署；软件工具和合成
  fixture 均不能提供这些真实硬件证据，即使 artifact 的 verdict 为 `readyForHumanReview` 也不能
  自动改写 Gate 状态。
- Gate 2 磁盘镜像和 Gate 3 可牺牲物理盘验证。

在完成磁盘镜像 Gate 前，任何代码都不得修改真实用户磁盘。

## 当前 Gate 状态

- **Gate 1：未通过。** 只读事件源、稳定 mount table、独立 IOKit 精确枚举、证据映射、通用
  protected 角色、unknown 外置 NTFS 候选、inventory、observer、当前机器 smoke check，以及
  匿名有界 recorder、capture/verify CLI 和严格 canonical verifier 已实现；callback 静默仍只
  形成 Observation Settlement。明确的网络卷已从物理介质 inventory 排除，未知网络标记仍失败
  关闭，并由独立 IOKit 集合兜底。schema 2 工具已固定单一匿名 target、verified absence baseline、
  逐轮 comparison 窗口、pending 语义和 seal 的 stop-and-drain/final-enumeration 顺序；自然 source
  end 或未验证的最终 observation 会永久失败关闭。工具最多输出 `readyForHumanReview`，不能输出
  Gate pass；即使没有 failure code，canonical 最后一帧 unverified 也只能 `incomplete`，verifier
  会独立重算。当前仍缺
  candidate/声明与真实订阅生命周期的硬件对照，以及专用外置盘上的 100 次插拔、多分区父子
  关系、睡眠/唤醒、应用重启、逐轮系统清单与 mount table 对照和人工签署的完整实物证据。
  2026-09-08 用户已提供可牺牲 USB-1；[一次插入状态证据](../../.scratch/ntfs-mvp/evidence/G1-5354DF11B2C047289A1862B41EAC2300.md)
  已独立验证，最终 coverage verified，但系统未返回 NTFS Volume UUID，candidate 为空，
  verdict=incomplete、0/100。CLI 输入阻塞问题已修复（Issue 28），卷身份兼容性仍待调查
  （Issue 29）。随后已通过原生文件系统 UUID 补充只读候选身份，USB-1 形成一个 candidate；
  缺失/无效身份的展示也已补齐（Issue 29/30 resolved）。
  [后续证据](../../.scratch/ntfs-mvp/evidence/G1-599DFC215DBB4D6CBA982D72F91CBF50.md)
  仍为 incomplete、0/100；未挂载身份、物理重插和完整人工矩阵未验证。这些增量不改变 Gate 状态。
- **Gate 2：未通过。** Setup 事实模型、有界只读探针、精确版本与静态代码身份策略、物理盘
  推出事实、健康协议、安全调用编译器、纯 `MountEngine` 契约、具名冲突范围和 installed-footprint
  provider 已有软件实现，但生产策略值、active scope 与具名环境基线实证、真实
  MountEngine/helper adapter、固定依赖批准和
  一次性镜像上的真实生命周期证据仍未完成。macFUSE 5.3.3（唯一稳定版）仍带 FSKit 数据面
  回归 #1181 / #1187 / #1188，不能作为生产批准版本；5.4.0（2026-09-07）已在 release note
  确认包含这三项修复，但仍为 pre-release，不满足版本监视触发器；任何版本都必须作为新的
  精确候选完成 DMG 代码签名核对和镜像矩阵后再验证。
- **Gate 3：未通过。** 需要可牺牲物理盘、Windows 环境、`chkdsk` 与内容哈希矩阵，当前没有这些实物证据。
- **Gate 4：未进入变更能力。** 已提前完成正式只读 C 版壳、物理盘分组、多卷唯一展示序号、按选择身份触发的辅助功能事件、保留/展示选择与导航焦点纯逻辑契约、Setup 动作、诊断交互和可重复的自动映射检查；observer→coordinator→MountEngine→`VolumePresentation` 正式接线尚未实现，320 pt、深浅色、高对比、真实键盘焦点提交和 VoiceOver 仍缺 Issue 13 的人工验收。Gate 1–3 通过前不会加入挂载、卸载、推出或写入按钮。
- **Gate 5：未进入。** 本地只读构建验证、供应链记录格式和回滚说明已有；helper、Developer ID、Hardened Runtime、公证、依赖批准和两周个人使用验证均未完成。

## 模块边界

### 当前只读产品依赖边界

```text
NTFSLiteReadOnlyApp
  ├─ NTFSLiteCore
  ├─ NTFSLitePresentation ─┐
  ├─ NTFSLiteDiagnostics ──┼─> NTFSLiteSystem
  └─ NTFSLiteSystem ───────┘        └─> NTFSLiteReadOnlyProbing

NTFSLiteGate1EvidenceTool
  ├─ NTFSLiteGateEvidence ──> NTFSLiteCore
  │            ├────────────> NTFSLiteSystem ──> NTFSLiteReadOnlyProbing
  │            └────────────> NTFSLiteStrictJSON
  └─────────────────────────> NTFSLiteSystem

没有依赖路径进入 NTFSLiteMutationPreparation 或 NTFSLiteHelperProtocol
```

`NTFSLiteReadOnlyProbing` 不是 package product，只隐藏固定只读命令且已验证固定保存容量与墙钟
上界的进程运行器。变更准备与 helper 协议可由行为检查构建和验证，但不会进入当前正式只读
应用的产品依赖图。`NTFSLiteGateEvidence` 与 `NTFSLiteGate1EvidenceTool` 是另外两个只读 root；
边界检查要求它们不能到达 mutation/helper，并要求正式 App 不能直接或间接依赖证据工具链。
`NTFSLiteStrictJSON` 是中立的严格语法模块，复用它不构成证据模块与 helper 的依赖关系。

### 目标变更架构

以下是 Gate 通过后的目标边界，不代表当前只读应用已经接入变更能力：

```text
DiskObserver ──> ReadOnlyVolumeCandidate ──> ReadOnlyDashboardPresentation
     |                    （只读展示；无变更资格）
     |
     +── fresh system facts + 当前连接固定声明
                              |
                              v
                    Data Declaration Resolver
                              |
                              v
SwiftUI C 版主窗口 ──> VolumeCoordinator actor
                              |
                              +-- MutationGate  原子核对并消费一次性变更意图
                              +-- MountEngine   只接受固定安全策略
                              +-- SetupChecker  检查版本、后端、扩展和冲突
                              +-- Diagnostics   结构化并脱敏
```

约束：

- UI 不能生成操作 ID、挂载参数或 shell 字符串。
- UI 只能针对完整当前实例提交固定语义“这是数据卷且不是 Windows 启动/系统卷”的声明；不能
  构造 `VolumeSnapshot`、角色证据或任何 System Evidence。声明不持久化，并在重插、重订阅、
  拓扑变化、请求消费或应用重启后失效。
- 当前只读应用不得依赖 `NTFSLiteMutationPreparation` 或 `NTFSLiteHelperProtocol`；新增依赖必须先更新只读边界 ADR，并取得对应 Gate 证据。
- `VolumeCoordinator` 是唯一用户变更入口。
- UI 发起写入或推出时必须传完整 `VolumeInstanceID`，不能只传可被重插复用的 `VolumeID` 或 BSD 名。
- `MountEngine` 只能从 `VolumeCoordinator.executeMutation` 的 package-only engine 入口接收已领取的
  `MutationCommand`；不能接收命令文本、路径或参数，也不能保存或重放命令。
- engine 入口与兼容闭包入口共用最终预检和一次性消费。兼容闭包必须显式返回
  `MountEngineTermination`；只有 termination handler/`waitpid` 等证据确认 quiescence 才能结算。
  闭包或 typed engine 都可返回 termination unconfirmed，但协调器会继续持有整盘租约并拒绝回调绕过。
  Swift Task 取消、发送终止信号或用户等待超时都不算退出。
- 写路径先读取 Setup facts，再把更易变化的完整卷事实作为执行前最后一次异步读取。
- 写路径的每次系统变更都重新读取完整卷事实；卸载前要求仍为只读，挂载前要求仍为未挂载、clean、外置 data NTFS。
- 整盘推出在请求和每次系统变更前都检查完整、无重复且包含发起卷的 sibling inventory；实际
  eject 前再次要求每个子卷仍为未挂载，内部或其他 `protected` 卷永不进入执行器。用途仍为
  unknown 的只读候选同样不提供整盘推出。
- 介质事件立即撤销旧工作流；若旧变更进程仍在执行，则保留绑定原介质代次的 tombstone 租约，直到进程确认退出，期间禁止 inventory rebuild 和同物理盘新操作。
- 写入或推出变更超时、取消后都先等待真实进程退出，再分别用完整卷事实或完整物理盘事实收敛；整盘卸载或推出即使明确失败也必须核对可能的部分卸载或重挂载，观察不完整则继续锁定。
- 当前 operation 接纳的完整整盘事实必须原子同步所有 sibling 的挂载状态；缺失发起卷则将旧目标终结为不可用。同一代介质的移除 tombstone 单调不回退，即使迟到 `present` 带当前 operation ID，也只能重新发起读取，不得刷新 sibling 或释放租约；重插必须产生新介质代次并重建 inventory。
- 同盘其他卷在租约活动期间由 `VolumeStatusSnapshot` 禁用动作并显示独立的“勿读写或断开”文案；已经撤销的介质状态优先于 busy overlay。确认整盘消失后原子撤销所有 sibling 状态。
- 最终预检拒绝会原子消费一次性意图、进入明确终态并释放未执行的租约，绝不留下无法恢复的活动操作。
- `DiskObserver` 负责核对来源设备、挂载标志、后端、规范路径和符号链接。
- helper 只接收结构化目标和固定动作，不接收任意命令文本。
- 诊断只接受封闭枚举、数量、版本、布尔值、时间/耗时、数值退出状态和每次运行生成的匿名别名；不得把 BSD 名、设备或卷 UUID、路径、卷标、用户名、驱动原名或任何 stderr 文本投影进诊断模型。
- 进程重启与 inventory rebuild 都从系统事实重建，不恢复旧成功状态。

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
