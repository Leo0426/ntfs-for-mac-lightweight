# NTFS for Mac Lightweight

一个面向个人自用的轻量 NTFS for Mac 原型。目标不是复刻商业磁盘工具，而是把两条高风险路径做得清楚、保守且可验证：

- 手动把健康的外置 NTFS 数据卷切换为可写。
- 标准卸载整块物理盘，并在系统确认磁盘已推出后提示可以拔出。

## 当前状态

目前已完成产品调研、安全状态机、独立 IOKit 精确枚举、稳定 mount table 采样、受保护卷
失败关闭角色模型，以及可运行的本地 C 版只读应用。用途仍为 unknown 的外置 NTFS 会在其余
事实完整时显示为“用途未确认”的 `ReadOnlyVolumeCandidate`，但不会被推断为可信 data、进入
变更 inventory 或获得写入/推出资格。独立 Gate 1 证据 recorder 与本地 capture/verify 工具已经
实现，但尚未在专用外置盘取得并人工签署实物证据；工具最多报告 `readyForHumanReview`，不能
报告 Gate pass。项目不会实际修改、挂载、卸载或推出磁盘。

Gate 的编号、定义、前置关系和当前状态只以[分阶段实施计划](docs/engineering/implementation-plan.md)为准；README、PRD 和调研文档不单独宣布 Gate 通过。

- 仓库由 Codex 主导开发，根目录 `AGENTS.md` 固化了测试驱动、失败关闭和硬件 Gate 前禁止真实磁盘变更的工作约定。
- UI 已确定采用 C 版方向：菜单栏保留常驻入口，主界面使用“左侧磁盘列表 + 右侧状态详情”的单窗口结构；A/B 仅作为一次性设计比较记录，不进入正式实现。
- 已有一个只使用内存 fixture 的 C 版 SwiftUI 场景原型；它不会读取磁盘、打开访达、启动进程或执行任何真实动作。
- 已有一个本地 C 版只读应用：通过 Disk Arbitration 与 mount table 展示可信 snapshot 和无变更
  资格的 unknown-role candidate，按物理盘分组，提供文字菜单栏入口、手动刷新、可执行的 Setup
  下一步和脱敏诊断；它不包含写入、挂载、卸载或推出按钮。
- C 版自动验收已固定全部 24 个领域状态的动作/禁用矩阵、长卷名和多分区排序；新观察订阅
  会轮换 selection-reset epoch 并回到概览，即使新 inventory 复用相同完整实例 ID，而同一 epoch
  的临时 scanning 保留选择且详情只从当前 dashboard 解析。多卷物理盘的每个 sibling 使用确定、
  不含原始身份的“卷 1、2… · 原卷名”展示标题，避免同名或用户卷名与生成标题发生碰撞；辅助
  功能变化键同时绑定完整选择身份，正文相同也不会吞掉切换。侧栏与窄版选择器的卷标签统一
  朗读“物理磁盘 N，卷标题”，因此不同物理盘上的同名卷也可区分。UI 同时区分保留选择和
  当前可展示选择：scanning 可记住暂时缺失的卷，但详情与控件立即回概览；宽版失效卷焦点
  回到当前展示项，窄版 Picker 保持焦点，只有原本位于导航区的焦点才随宽窄布局转移。
  Setup/诊断可见文字与辅助功能公告也已自动固定；320 pt、深浅色、高对比、键盘和 VoiceOver
  仍需 Issue 13 的人工证据。
- 当前连接数据卷声明已有纯 Core 契约：固定语义绑定 session/revision、完整目标实例、精确 sibling
  与一次性 nonce；重插、克隆、重订阅、应用重启、拓扑变化和重放都拒绝。它只产生不可公开
  构造的短生命周期 `DataRoleApproval`，不产生 `VolumeSnapshot`、System Evidence 或磁盘命令。
- 首次设置展示层集中处理固定排序、明确中文状态、刷新期间 fail-closed，以及冲突驱动信息脱敏。
- Setup 探针只允许固定语义的只读命令，并严格解析 PluginKit、System Extension 与已加载 kext
  输出；授权、依赖、输出或 Gate 2 具名有限候选范围的冲突目录不完整时保持未就绪。
- 诊断只保存固定状态码、数量、版本、布尔事实、数值退出状态和运行期数字别名；不会保存卷标、用户名、任何路径、磁盘或卷 UUID、BSD 名，也不接收或记录任何标准错误文本。快照以原子替换、`0600` 权限、schema/字节/时间上限、canonical JSON、文件稳定性和 target 语义检查保存在用户 Application Support；清除操作只有在本地存档确实移除后才报告成功，损坏、过期、未来时间、符号链接或权限异常的旧存档全部忽略。
- helper 协议已有唯一的进程期原子准入入口：先限制 4 KiB 原始消息，再严格拒绝未知/重复字段，核对 schema、完整实例身份和固定动作，最后原子消费 operation ID；解码与重放集合已经收回模块私有，只有该入口能产生不可由调用方伪造的准入值。它仍不包含 IPC/XPC、提权、安装、命令执行器或真实磁盘变更。
- 正式只读应用的 package 依赖图不包含 `NTFSLiteMutationPreparation` 或 `NTFSLiteHelperProtocol`；唯一的进程运行器位于非产品 `NTFSLiteReadOnlyProbing` target，只能执行固定语义的只读 Setup 探针。输出上限、超时、取消、继承管道和终止未确认均在固定墙钟上界内失败关闭，不把“已截断”误报为可信输出。
- Gate 1 取证位于独立的 `NTFSLiteGateEvidence` 与 `NTFSLiteGate1EvidenceTool`：原始磁盘身份只在
  会话内存中用于关联，schema 2 artifact 只含匿名别名、固定枚举、计数、时间、版本、摘要与
  封闭检查点；Evidence-ID 固定为 `G1-` 加 32 位大写十六进制无语义值。观察/检查点/拓扑/编码
  字节均有上限，时间、代次、拓扑或容量异常永久失败关闭。
- 一个会话只把首个完整 candidate 绑定为单一匿名 target，不能把不同物理盘拼成 100 轮；常驻
  内置盘不阻塞 target。启动时已插入的 target 必须先取得 verified absence baseline，逐轮两项
  comparison 只能在该轮 verified present 与 verified absence 之间记录；unverified pending 只暂停。
- Gate artifact 使用 sorted-key canonical JSON 与 SHA-256；共享的 `NTFSLiteStrictJSON` 会先拒绝
  重复键，再核对 schema、canonical bytes、派生字段和事件重放。review-ready 还要求 canonical
  observations 最后一帧 coverage verified；即使无 failure code，最后一帧 unverified 也只能
  incomplete，verifier 会独立重算。正式只读 App 不依赖 recorder 或 CLI，包边界检查把三者
  分别作为只读 root，并禁止证据工具链到达 mutation/helper。
- Gate capture 的显式 seal 不取消观察任务：它先排空 Disk Arbitration 串行队列，再在
  `drainBoundary` 后完成最终 settle 与独立 IOKit enumeration，最终 observation 与 capture
  terminal 按 FIFO 处理后才封存。自然 source end 或未验证的最终 observation 永久失败关闭。
- 正式应用直接消费 Setup typed report，能在 UI 中区分“尚未配置可信策略”和“已配置但文件身份、bundle 元数据、精确版本、代码签名或批准摘要核对失败”，并显示不含路径的固定失败码；两者都会安全映射为未就绪。后端不再由 mapper 默认成 FSKit，授权状态仍由可注入 provider 提供且当前正式应用保持 unknown。
- NTFS-3G 可信制品读取器从同一个已打开文件描述符核对文件类型、owner、权限、大小和 SHA-256，并只通过预先固定的“哈希 → 版本”目录报告版本；没有完整目录或任一核对失败时保持未知，且不会为读取版本而执行该程序。安全挂载编译器只接受不可伪造的可信制品能力并在编译时重验；在未来执行器能用 FD-bound 或等价的失败关闭方式消除最后的路径 TOCTOU 前，不接入真实执行。
- 核心状态机不执行 shell 命令，也不访问真实磁盘。
- 已挂载外置 NTFS 在 Disk Arbitration 未提供卷 UUID 时，可通过 FD 绑定的原生文件系统 UUID
  补充只读候选身份；两次 UUID 与前后挂载对象均须一致，读取失败或来源冲突仍失败关闭，
  原始 DA 字段不改写。2026-09-08 的 USB 实测已显示一个只读、用途未确认的候选；尚无物理
  重插周期或未挂载身份验证。身份仍缺失/无效时，概览明确解释原因且不生成选择项。
- 所有变更操作都由协调器生成一次性语义效果；受限适配层只能通过协调器的执行边界调用一次。
  兼容 closure 必须显式返回 `MountEngineTermination`，未确认终止不能被闭包返回误当成进程已静止。
- `MountEngineAdapter` 的纯逻辑骨架已就位：把已领取命令路由为具名动作，并只从 positive reap
  或已触发的 Disk Arbitration 回调断言静止；deadline、取消、已发信号都不推断进程已停止。真实
  启动/等待由注入的 `Executor` 提供，本仓库不含任何 `Process` 或 Disk Arbitration executor，
  `executionUnavailable` 对每个命令都失败关闭。
- 介质代次只由真实 `ReadOnlyDiskInventory` 维护；未接生产路径的平行 `MediaGenerationTracker`
  API 已删除，避免出现两个 source of truth。
- 每个效果绑定完整磁盘实例；执行前必须重新读取并核对目标、完整卷安全事实、整盘范围和当前设置条件。
- 用户动作也必须携带完整 `VolumeInstanceID`；等待设置检查期间若磁盘重插，旧点击不会重新绑定到新介质。未来写入还必须有当前连接的一次性 Data Volume Declaration，并与 fresh 候选和精确 sibling 拓扑重新核对；声明不能缓存、跨重插复用或伪装成系统角色证据。
- 可写挂载前再次要求卷仍为未挂载、clean、经当前请求批准的外置 data NTFS；真正推出前再次
  要求同盘所有分区仍为未挂载。unknown-role candidate 自身始终没有任何 mutation 动作；
  一次性声明与 fresh 事实只能进入本次写入资格核对，整盘推出仍需独立的可信 snapshot 与正式规则。
- 命令成功不等于最终成功；写入与推出都需要新的系统观察结果复核。
- 休眠、dirty、健康未知、内部或其他 `protected` 卷默认拒绝写入。
- 内部、`protected` 或含受保护分区的物理盘不会提供整盘推出；生产观察不按卷名声称精确识别
  Boot Camp。
- 已开始的卸载、挂载或推出若超时、取消或期间介质被拔出，会继续锁定整块物理盘，直到进程确认退出；整盘卸载或推出即使明确失败，也必须取得当前 operation 的完整整盘观测再释放，观察不完整则继续锁定。
- 完整且无重复的整盘事实会原子更新所有 sibling；观测中消失的发起卷终结为“磁盘已断开”。同一代介质一旦收到移除事件，移除 tombstone 单调不回退；同 operation 的迟到 `present` 也只能触发重新读取，不能复活状态或释放租约。
- 同盘 sibling 在操作期间只显示“请勿读写或断开磁盘”且不提供动作；确认整盘消失后，只有发起卷显示“已验证可以拔出”，其他 sibling 立即撤销为“磁盘已断开”。
- 公开接口没有强制卸载、`remove_hiberfile`、自动恢复或内核扩展回退。
- 健康探针解析器只接受单行版本化协议；安全挂载编译器只能生成固定的 `rw,backend=fskit,norecover` 调用，二者都不具备执行能力。
- 只读订阅使用随机 refresh token 隔离连续刷新；旧任务迟到、取消或旧事件源结束不能覆盖当前状态，当前事件源结束会明确降级为“事件源不可用”。手动、通知与系统唤醒触发的新订阅都会轮换 selection-reset epoch 并回到概览，不继续使用睡眠前或旧订阅的选择与事实。
- 无 BSD 身份事件、缺父盘子卷、非法 UUID/BSD 名和零介质代次会留下固定问题码，不能被静默变成完整空库存或可信快照。Disk Arbitration 的短暂静默只表示界面收敛，继续标记为枚举覆盖未验证，不能授权变更。
- Disk Arbitration 明确标记 `VolumeNetwork=true` 的网络卷不进入物理盘 inventory；该标记只接受
  CFBoolean。`false`、缺失或类型错误不会被猜成网络卷，无 BSD 身份时仍失败关闭；错误排除的
  物理介质也会被独立 IOKit 集合不一致拦截。
- 独立 IOKit `IOMedia` 枚举与 Disk Arbitration 集合完全一致、且 mount table 连续稳定，是
  Complete Observation 的必要条件；角色仍为 unknown 时仍只产生候选。物理盘
  ejectable/removable 缺失、矛盾或明确不可推出时不会提供安全推出资格。
- 只读概览的失败关闭标题只在顶层观测事实本身不可信（枚举覆盖未验证、mount table 不可读、
  未识别磁盘事件等），或有未完整读取的可移动物理盘时出现。顶层事实一致但 EFI / APFS 容器
  等非 NTFS 分区天然缺少卷 UUID/名称/文件系统时，正常 Mac 会显示“未检测到 NTFS 磁盘”，
  不再误报为“磁盘信息尚未确认”。
- 卷 BSD 名识别接受 `diskNsM` 和三级 `diskNsMsK`（macOS 用 APFS 快照设备挂载封闭系统卷）；
  路径片段、整盘名、空分段或四级名仍失败关闭。

## 目标环境

- macOS 15.4 或更高版本
- Apple Silicon first
- 经 Gate 2 固定并核对精确版本、源码与产物摘要的 NTFS-3G；2026.7.7 当前仅为未批准候选
- macFUSE FSKit 候选固定版本：5.3.3 是当前唯一稳定版，但带 FSKit 数据面回归
  #1181 / #1187 / #1188，不是生产批准版本；5.4.0（2026-09-07）已在 release note 确认
  包含这三项修复，但仍为 pre-release，尚未作为候选批准
- macFUSE FSKit backend

Swift Package 的部署下限已设为 macOS 15.4。当前只读 Setup adapter 已能读取系统版本、架构、
严格解析的扩展与冲突证据；未经可信文件及静态代码身份核对的依赖版本、helper 授权和不完整的
Gate 2 候选范围冲突目录仍保持未知。未来每次写入请求与变更前仍必须重新运行 `SetupChecker`。

## 本地查看 C 版

构建并打开正式只读壳：

```bash
scripts/build-local-read-only-app.sh
open .build/NTFSLiteReadOnlyApp.app
```

这个应用会读取本机只读系统事实，但不会提供任何磁盘变更操作。

查看覆盖全部状态的内存场景原型：

直接打开主窗口：

```bash
swift run NTFSLiteScenarioPrototype --show-window
```

不加 `--show-window` 时只显示文字菜单栏入口，再由“打开 NTFS 轻量助手”进入主窗口。窗口顶部会一直显示“一次性原型 · 仅模拟数据”；38 个场景覆盖全部 24 个公开 `VolumeState`、全部写入阻止原因、三类整盘推出阻止、设置状态、安全推出可用性，以及同盘 busy/多物理盘分组。应用启动时会自动检查状态目录完整性。场景切换与全部按钮只改变内存提示，不会访问真实磁盘或系统剪贴板。

## 本地 Gate 1 证据工具

工具的固定入口为：

```text
NTFSLiteGate1EvidenceTool capture EVIDENCE-ID APP-VERSION APP-BUILD APP-SHA256
NTFSLiteGate1EvidenceTool verify EXPECTED-SHA256 < artifact.json
```

`capture` 保留标准输入给 `status`、封闭 checkpoint 和 `seal`，只把 canonical JSON 写到标准输出；
操作提示、状态、错误和 SHA-256 只写到标准错误。Evidence-ID 必须是无身份语义的
`G1-[0-9A-F]{32}`；显式 `seal` 会等待串行 stop-and-drain、边界后的最终 settle/独立枚举与
capture terminal，不能用取消代替。自然 source end 或最终 observation 未验证会生成永久
`failedClosed` 结论；命令输入 EOF 或读取失败不会输出 canonical bytes。不要合并两个输出流。
即使没有 failure code，canonical 最后一帧 unverified 也只能 incomplete，`verify` 会独立重算
verdict。完整的本地 ID 生成、单一 target absence baseline、逐轮对照、摘要
sidecar 和复核命令见[Gate 验证运行手册](docs/operations/gate-validation-runbook.md)。这个工具不执行
系统清单对照，也不能替代专用外置盘、人工观察或 Gate 签署。

## 本地检查

当前命令行工具链没有 XCTest 或 Swift Testing 模块，因此使用同一 Swift Package 内的可执行检查器，通过 package 级接口覆盖状态机、协调器、只读系统层和严格协议边界：

```bash
scripts/check.sh
```

需要 Apple Silicon Mac、macOS 15.4+、支持 Swift 6 的命令行工具链及 Python 3。该入口会执行
全量 warnings-as-errors Release 构建、行为检查、CLI 输入回归、只读包/源码边界、本地 App
构建与签名验证，以及篡改包负向回归。任一步失败立即退出；不会安装 App 或改变磁盘。
排查单项失败时，可单独运行 `swift run -c release -Xswiftc -warnings-as-errors NTFSLiteCoreChecks`
或 `scripts/` 下对应检查脚本。`.build/` 和根目录临时 Swift 编译产物不进入 Git；
`.scratch/ntfs-mvp/` 中的工单和脱敏证据属于版本化项目记录。

仓库行为检查覆盖设置门禁、typed 依赖证据、完整实例请求、非法观察身份拒绝、枚举覆盖失败关闭、最终卷预检、显式挂载证据、介质代次防重插、一次性变更授权、helper 原子准入、真实可写复核、推出前子卷复检、内部盘保护、回调与拔盘乱序、事件源终止、连续刷新隔离、写入及推出超时收敛、整盘部分卸载收敛、完整 sibling 清单同步、畸形清单拒绝、私有诊断存档、inventory 重建、Gate 1 recorder 的 opaque ID、单一 target、absence baseline、逐轮 comparison 窗口、unverified pending、stop-and-drain/FIFO seal、自然 source end、最终 observation 未验证、100-cycle/隐私/限制/永久失败关闭，以及 canonical verifier 的摘要、重复键、篡改和事件重放。数量以检查器本次完整成功输出为准；中途终止不能计为通过。

## 代码导航

| 目录 | 职责 |
| --- | --- |
| `Sources/NTFSLiteCore` | 领域状态、设置门禁、声明与协调器纯契约 |
| `Sources/NTFSLiteSystem`、`NTFSLiteReadOnlyProbing` | 只读系统证据与固定 Setup 探针 |
| `Sources/NTFSLitePresentation`、`NTFSLiteReadOnlyApp` | 展示映射与正式只读 SwiftUI 应用 |
| `Sources/NTFSLiteDiagnostics` | 脱敏诊断与私有本地存档 |
| `Sources/NTFSLiteGateEvidence`、`NTFSLiteGate1EvidenceTool` | 独立匿名取证、封存与核验 |
| `Sources/NTFSLiteHelperProtocol`、`NTFSLiteMutationPreparation` | 尚未接入系统执行的协议和纯逻辑 |
| `Sources/NTFSLiteCoreChecks`、`scripts/` | 行为回归、边界与本地发布检查 |

## 文档

- [MVP PRD](docs/product/mvp-prd.md)
- [UI 指南](docs/design/ui-guidelines.md)
- [分阶段实施计划](docs/engineering/implementation-plan.md)
- [商业产品与技术底座调研](docs/research/ntfs-for-mac-landscape.md)
- [Setup 冲突驱动候选目录](docs/research/setup-conflict-catalog.md)
- [ADR 索引](docs/adr/README.md)
- [Gate 验证运行手册](docs/operations/gate-validation-runbook.md)
- [依赖供应链记录](docs/operations/dependency-supply-chain.md)
- [本地只读发布与回滚](docs/release/local-read-only-release.md)
- [交付地图与本地 Issues](.scratch/ntfs-mvp/MAP.md)

## 安全边界

第一版明确不做：

- 格式化、分区、擦除、检查或修复 NTFS。
- 强制卸载、强制推出或自动关闭占用磁盘的应用。
- 删除 Windows 休眠文件或自动清除 NTFS 日志。
- 内部 NTFS、Boot Camp 或 BitLocker 写入。
- 自动可写挂载。
- kext、降低启动安全性、关闭 SIP 或替换系统文件。

真实磁盘适配层完成后，也只应先在磁盘镜像和可牺牲外置盘上验证。不要用唯一副本测试。
