# NTFS Lightweight Context

这个上下文描述个人版 NTFS 助手用于识别磁盘、判断写入安全性和确认安全推出时采用的统一领域语言。它把“系统命令已返回”与“系统事实已证明结果”明确区分开。

## Language

**Physical Disk（物理盘）**:
一次连接生命周期内承载一个或多个卷的整块介质，也是安全推出和并发排他的范围。
_Avoid_: Drive, Device, Disk（未说明是整盘还是卷时）

**Volume（卷）**:
物理盘上可被识别和挂载的文件系统单元；用户选择写入目标时选择的是卷。
_Avoid_: Partition（除非特指分区表项）, Physical Disk

**Sibling Volume（同盘卷）**:
与目标卷属于同一个物理盘实例的其他卷；整盘推出和同盘忙碌约束必须把它们作为一个集合考虑。
_Avoid_: Other Disk, Nearby Volume

**Media Generation（介质代次）**:
物理盘从一次确认出现到确认整盘消失之间的身份代次；同名物理盘再次出现属于新代次。
_Avoid_: Session, Mount Generation, Callback Count

**Disk Instance（物理盘实例）**:
物理盘身份与介质代次的组合，指向一次确定的整盘连接生命周期。
_Avoid_: BSD Name, Physical Disk ID

**Volume Instance（卷实例）**:
卷身份与其物理盘实例的组合，指向当前介质代次中的一个确定卷。
_Avoid_: Volume ID, BSD Name

**Sibling Volume Ordinal（同盘卷序号）**:
多卷物理盘当前展示中，每个 sibling 按确定的展示全序取得的从 1 开始本地序号；它作为卷名
前缀显示，使任意用户卷名组合下的文字选择和辅助功能公告仍可区分。单卷物理盘不显示序号。
它不持久化、不跨拓扑变化保持，也不参与角色、写入或推出授权。
_Avoid_: Partition Number, Persistent Alias, Volume Identity

**Retained Selection / Presented Selection（保留选择/展示选择）**:
保留选择只在同一 observation subscription 内跨临时 scanning 缺项记住一个卷实例；展示选择
必须指向当前 dashboard 中实际存在的项目，否则立即回到概览。稳定缺项或 selection-reset epoch
变化会清除旧的保留选择。导航焦点只在原本位于导航区时随展示选择或宽窄布局协调，不会从
标题、详情或其他控件抢夺焦点；暂时缺失的卷重新出现时也不会主动抢回焦点。这只是 UI 状态
契约，不是 System Evidence、磁盘身份或任何变更授权。
_Avoid_: Cached Volume State, Persistent Selection, Focus Authorization

**System Evidence（系统证据）**:
从当前 macOS 状态重新读取的磁盘、卷和挂载事实；命令返回值和缓存状态不属于系统证据。
_Avoid_: Command Success, Cached State

**Gate Evidence Session（Gate 证据会话）**:
由独立只读记录器从一次开始采集到显式封存的有界生命周期；header 绑定无语义的
`G1-` + 32 位大写十六进制 Evidence-ID、应用 version/build、应用二进制摘要和 macOS 版本。
首个完整只读 candidate 绑定为唯一匿名 target，原始磁盘身份只在内存中用于当前会话关联；
后续完整 candidate 必须匹配首次规范化卷 UUID 清单（含数量），不能仅凭复用的 BSD 名累计轮次。
清单变化永久失败关闭；UUID 克隆仍需人工核验，匿名 artifact 无法独立证明原始盘身份。
常驻内置盘不进入 target 计数。它不是正式应用 session，也不表示任何 Gate 已通过。
_Avoid_: App Session, Persistent Disk Identity, Gate Pass

**Capture Drain Boundary（采集排空边界）**:
显式封存时，Disk Arbitration source 先停止接收新回调，并在其专用串行队列上等待此前已排队的
回调全部交付后发出的唯一 `drainBoundary`。observer 只能在该边界之后强制进行最终 settle 与
独立 IOKit enumeration，并按同一 FIFO 发布最终 observation 和 capture terminal。它不是 Task
取消、callback 静默或完整观测的替代品；没有有效边界的自然 source end 和未验证的最终
observation 都会永久失败关闭。
_Avoid_: Task Cancellation, Quiet Window, Last Cached Observation

**Canonical Gate Evidence（规范 Gate 证据）**:
Gate 证据会话显式封存后的 schema 2 sorted-key JSON 与对应 SHA-256。内容只允许匿名数字别名、
固定枚举、计数、时间、摘要和封闭检查点；摘要、严格 JSON、schema、canonical bytes、派生值
或事件重放任一不一致都必须拒绝。
显式 `seal` 只有在采集排空边界、最终 observation 与 capture terminal 已按序处理后才能封存；
EOF 或输入读取失败则在封存前退出，不产生规范证据。
_Avoid_: Raw Log, Command Transcript, Best-Effort JSON

**Review-Ready Gate Evidence（待人工复核的 Gate 证据）**:
证据记录器在没有失败码、已为同一匿名 target 建立 verified absence baseline、结算 100 次连接、
在每轮 verified present→absence 窗口内完成两项对照、所需场景检查点与多分区观测完整且没有
未确认 target 连接，且 canonical observations 最后一帧 `coverage=verified` 时产生的
`readyForHumanReview` 结论。即使没有 failure code，最后一帧 unverified 也只能是 `incomplete`；
verifier 必须从 canonical observations 独立重算这一判定。unverified pending 只暂停对照和结算；
review-ready 只表示可以交给人工复核，绝不等于 `pass`，也不能替代专用硬件、外部系统事实或
Gate 负责人签署。
_Avoid_: Gate Pass, Automatic Approval, Verified Hardware

**Complete Observation（完整观测）**:
对一次判断所需的系统证据均已取得且彼此一致的观测；缺失或矛盾的字段使观测不完整。
_Avoid_: Best Effort Observation, Assumed State

**Mounted File System UUID Evidence（已挂载文件系统 UUID 证据）**:
绑定当前本地挂载对象、经描述符读取与前后挂载事实核对的文件系统 UUID；只可补充 DA 原始
UUID 缺失的外置 unknown-role NTFS 只读候选，不能用分区标识代替、覆盖冲突、生成变更快照或
跨卸载/重订阅缓存。
_Avoid_: Partition UUID, Cached Volume Identity, Mutation Authorization

**Observation Settlement（观察收敛）**:
事件流在一个短时间窗内没有新回调，只表示界面可以稳定展示目前已确认的事实；它不证明
Disk Arbitration 已枚举全部磁盘，也不能升级为 Complete Observation。
_Avoid_: Enumeration Complete, Complete Observation

**Independent Enumeration Coverage（独立枚举覆盖）**:
只读 IOKit `IOMedia` 枚举连续两次得到完全相同的 BSD 名称集合，并且该集合与当前
Disk Arbitration 描述集合逐项相等的覆盖证据。缺项、多项、迭代器失效、集合变化或超时
都只能保留为未验证。
_Avoid_: Quiet Callback Window, Initial Enumeration Finished

**Physical Media Observation Scope（物理介质观察范围）**:
物理盘 inventory 只处理本地介质。Disk Arbitration 明确提供 CFBoolean
`VolumeNetwork=true` 的网络卷事件不进入该 inventory，也不参与 IOKit `IOMedia` 集合核对；
`false`、字段缺失、类型错误或其他未知值都不能被当作网络卷排除，无 BSD 身份时仍永久失败关闭。
若一个带物理介质 BSD 身份的事件被标为网络卷，独立 IOKit 集合与 DA inventory 的不一致仍会
阻止 Complete Observation。
_Avoid_: All Disk Arbitration Objects Are Physical Media, Missing BSD Means Network Volume

**Stable Mount Table（稳定挂载表）**:
一次读取内部的计数与复制边界一致，并且连续两次完整挂载表快照逐项相同的系统证据。
同数量条目替换、截断、复制期间变化或读取失败都不构成稳定挂载表。
_Avoid_: One Successful `getfsstat`, Best Effort Mount List

**Physical Disk Safety Evidence（物理盘安全证据）**:
绑定当前 Disk Instance 的完整、彼此一致的整盘 `Ejectable` 与 `Removable` 事实。未知、
缺失、代次不匹配或 `Ejectable=true` 但 `Removable=false` 均不能授权推出。
_Avoid_: External Disk, USB Disk, Probably Ejectable

**Dependency Trust Evidence（依赖信任证据）**:
由固定策略对依赖路径、owner、权限、身份、字节和批准摘要完成核对后的 typed 结果；
`notConfigured`、`failedClosed` 与 `trusted` 必须保持可区分。
_Avoid_: Installed, Version String, Command Output

**Setup Readiness（运行环境就绪）**:
写入所需的系统版本、架构、依赖、后端、授权和冲突扫描均由当前事实确认满足的状态。
_Avoid_: Installed, Probably Ready

**Conflict Catalog Scope（冲突目录范围）**:
绑定目标平台、证据日期、候选制品摘要、loaded identifier、installed footprint 与环境基线的
具名有限集合；“完整”只表示当前事实满足该范围，不表示已穷举所有 NTFS 驱动。
_Avoid_: All Commercial Drivers, Global Conflict-Free, Permanent Complete

**Mutation（磁盘变更）**:
会改变卷或物理盘系统状态的标准卸载、可写挂载或整盘推出操作。
_Avoid_: Action, Command（未说明是否改变磁盘状态时）

**Mutation Quiescence（变更静止确认）**:
底层变更进程或系统调用已经明确停止、不会再继续改变磁盘的事实。超时、Task 取消或已发送
终止信号都不构成静止确认；未确认时必须继续持有 Whole-Disk Lease 并拒绝结果回调绕过。
_Avoid_: Timed Out, Cancelled, Termination Requested

**Whole-Disk Lease（整盘租约）**:
一个变更操作在物理盘范围内持有的独占资格；租约存在时同盘卷不得开始其他变更。
_Avoid_: Volume Lock, UI Busy Flag

**Verified Writable（已验证可写）**:
新的完整系统证据已经确认目标卷实例、可写标志、挂载来源、后端和挂载点均符合安全约束的状态。
_Avoid_: Mounted, Mount Succeeded, Writable Command Completed

**Safe to Remove（已验证可以拔出）**:
新的完整系统证据已经确认目标物理盘实例从系统中消失的状态。
_Avoid_: Eject Succeeded, Probably Removed

**Diagnostic Archive Generation（诊断归档代次）**:
诊断归档在一次 `clear` 之前签发的保存资格代次；清空会先轮换代次，因此较早异步保存即使
稍后完成也只能被拒绝，不能重新生成已清除的快照。
_Avoid_: File Revision, Display Revision

**Protected Volume（受保护卷）**:
内部卷、Boot Camp 卷或其他使整盘变更超出产品安全范围的卷。
_Avoid_: Unsupported Partition, Special Volume

**Read-Only Volume Candidate（只读卷候选）**:
身份、父盘、介质代次、文件系统、位置和挂载事实已核对，但用途角色仍为 unknown 的展示对象；
它不是 VolumeSnapshot，不能进入任何磁盘变更资格。
_Avoid_: Untrusted Snapshot, Probably Data Volume

**Data Volume Declaration（数据卷声明）**:
用户针对当前连接和一次性写入请求明确确认所选卷是数据卷且不是 Windows 系统卷的人类策略输入；
它必须与 fresh 系统事实重新核对，不能被记录或解释为 System Evidence。
_Avoid_: Trusted Data Evidence, Remembered Volume Role, Automatic Classification

**Data Declaration Observation Revision（数据声明观察修订）**:
resolver 为一次 fresh candidate 与精确 sibling 事实集合生成的不可复用修订标识；新的请求、订阅、
唤醒或应用进程都必须轮换。它不是 Media Generation，也不证明系统事实完整。
_Avoid_: Media Generation, Persistent Revision, System Evidence

**Data-Role Approval（数据角色批准）**:
纯逻辑 resolver 对当前 session、observation revision、完整目标实例、精确 sibling 集合和一次性 request
完成声明核对后的短生命周期结果；它只证明本次人为角色策略通过，不是 `VolumeSnapshot`、System
Evidence 或 Mutation 资格。未来 Gate 4 仍必须把它与 fresh 系统事实重新核对。
_Avoid_: Trusted Snapshot, Persistent Allowlist, Write Capability


## 已授权的隔离写入实验

2026-09-09 起按 [ADR 0009](docs/adr/0009-isolate-local-write-validation.md) 使用独立
`scripts/write-validation/` 文件语义库验证可牺牲介质。该库没有挂载资格判断或系统执行器，
调用方负责确认目标与实际可写挂载；临时目录检查不能证明 NTFS 通过。Windows 复核按用户
要求后置，实验结果不改变正式应用只读边界或 Gate 状态。当前证据见
[实验计划](.scratch/write-delete-validation/PLAN.md)。
