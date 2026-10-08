# NTFS for Mac Lightweight

一个面向个人自用的轻量 NTFS for Mac 原型。目标不是复刻商业磁盘工具，而是把两条高风险路径做得清楚、保守且可验证：

- 手动把健康的外置 NTFS 数据卷切换为可写。
- 标准卸载整块物理盘，并在系统确认磁盘已推出后提示可以拔出。

## 当前状态

正式 SwiftUI 应用已接入外置 NTFS 数据卷的手动启用写入与安全推出：用户确认卷用途后，App
通过一次性结构化请求调用特权 helper；helper 在操作前重新核对系统事实并执行固定的可写挂载
或标准整盘卸载与推出。当前仅开放 GPT Microsoft Basic Data NTFS 目标，以及同盘可选的未挂载
EFI 分区。独立 Gate 1 证据工具仍未取得人工签署的实物证据，不能报告 Gate pass；Gate 1–5
状态不因正式 App 接入写入而改变。现有可牺牲 U 盘写入闭环属于有限验证；新增 GPT/EFI 路径的
快速拔插、真正整盘推出和 Windows 复核仍未完成，不能视为已验证消费级安全性。2026-09-30
本机已完成首次受保护安装并通过安装后权限、清单与签名核验；helper 注册、系统批准、XPC 与
当前正式 App 的实盘写入尚未完成，不能视为实盘可写。

Gate 的编号、定义、前置关系和当前状态只以[分阶段实施计划](docs/engineering/implementation-plan.md)为准；README、PRD 和调研文档不单独宣布 Gate 通过。

- 仓库由 Codex 主导开发，根目录 `AGENTS.md` 固化了测试驱动、失败关闭与仅在一次性镜像或已授权可牺牲 U 盘上验证真实磁盘操作的工作约定。
- UI 已确定采用 C 版方向：菜单栏保留常驻入口，主界面使用“左侧磁盘列表 + 右侧状态详情”的单窗口结构；A/B 仅作为一次性设计比较记录，不进入正式实现。
- 已有一个只使用内存 fixture 的 C 版 SwiftUI 场景原型；它不会读取磁盘、打开访达、启动进程或执行任何真实动作。
- 正式 App 通过 Disk Arbitration、IOKit 与 mount table 展示磁盘状态，按物理盘分组，提供菜单栏
  入口、手动刷新、设置引导与脱敏诊断；符合当前范围的目标可显式确认用途并请求启用写入，
  本次会话中已启用写入的磁盘可从概览请求安全推出。App 重启后不会自动恢复此前的推出会话。
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
- 诊断页面与“复制摘要”输出中文分段报告，包含状态概览、处理建议、运行环境、磁盘识别和最近 10 条记录；最新检查覆盖旧结论，历史存档明确标注为上次运行，不能代表当前状态或授权磁盘操作。时间按本机时区显示并带 UTC 偏移；物理盘与卷总数包含本机磁盘及其他文件系统，不作为外置 NTFS 目标数量。
- 诊断只保存固定状态码、数量、版本、布尔事实、数值退出状态和运行期数字别名；不会保存卷标、用户名、任何路径、磁盘或卷 UUID、BSD 名，也不接收或记录任何标准错误文本。快照以原子替换、`0600` 权限、schema/字节/时间上限、canonical JSON、文件稳定性和 target 语义检查保存在用户 Application Support；清除操作只有在本地存档确实移除后才报告成功，损坏、过期、未来时间、符号链接或权限异常的旧存档全部忽略。
- 正式 App 通过 `SMAppService` 注册的 launchd daemon helper 和 XPC 执行四种固定语义动作；请求协议限制消息大小、核对完整磁盘实例与精确 GPT 分区集合，并一次性消费 operation ID。App 不拼接命令或挂载参数，特权执行集中在 helper。
- 新版 helper 的签名标识、Mach service 与 daemon plist 统一使用 `com.leolu.ntfslite.helper.v2`；旧版服务不会被构建脚本移除，但新版 App 不连接旧服务。
- App 进程仅为 Setup 运行固定语义的只读探针；写入会话负责一次请求、超时后不重试和操作后重新观察。独立的 Gate 取证工具仍不得依赖 mutation/helper 模块。
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
  incomplete，verifier 会独立重算。正式 App 不依赖 recorder 或 CLI；包边界检查保持取证工具链
  与 mutation/helper 隔离，并检查正式 App 的允许依赖集合。
- Gate capture 的显式 seal 不取消观察任务：它先排空 Disk Arbitration 串行队列，再在
  `drainBoundary` 后完成最终 settle 与独立 IOKit enumeration，最终 observation 与 capture
  terminal 按 FIFO 处理后才封存。自然 source end 或未验证的最终 observation 永久失败关闭。
- 正式应用直接消费 Setup typed report，能在 UI 中区分“尚未配置可信策略”和“已配置但文件身份、bundle 元数据、精确版本、代码签名或批准摘要核对失败”，并显示不含路径的固定失败码；两者都会安全映射为未就绪。后端不再由 mapper 默认成 FSKit，授权状态仍由可注入 provider 提供且当前正式应用保持 unknown。
- NTFS-3G 可信制品读取器从同一个已打开文件描述符核对文件类型、owner、权限、大小和 SHA-256，并只通过预先固定的“哈希 → 版本”目录报告版本；没有完整目录或任一核对失败时保持未知，且不会为读取版本而执行该程序。正式 App 的固定驱动在构建时按摘要核对并签名；helper 在执行前后复核身份，但驱动最终打开 BSD 设备路径的快速拔插竞态尚未严格消除。
- 核心状态机不执行 shell 命令，也不访问真实磁盘。
- 已挂载外置 NTFS 在 Disk Arbitration 未提供卷 UUID 时，可通过 FD 绑定的原生文件系统 UUID
  补充只读候选身份；两次 UUID 与前后挂载对象均须一致，读取失败或来源冲突仍失败关闭，
  原始 DA 字段不改写。2026-09-08 的 USB 实测已显示一个只读、用途未确认的候选；尚无物理
  重插周期或未挂载身份验证。身份仍缺失/无效时，概览明确解释原因且不生成选择项。
- Core 协调器及 `MountEngineAdapter` 保留为纯逻辑契约；正式 App 按 ADR 0011 使用
  `NTFSLiteWriteSession` 调用 helper 的原子 `mountReadWrite`，安全推出依次请求标准整盘卸载与推出。
  helper 每次操作重新核对目标，超时、断线或无效响应按结果未知处理，不自动重发。
- 介质代次只由真实 `ReadOnlyDiskInventory` 维护；未接生产路径的平行 `MediaGenerationTracker`
  API 已删除，避免出现两个 source of truth。
- 每个变更请求绑定完整磁盘实例；helper 执行前重新读取并核对目标、完整卷安全事实和整盘范围。
- 用户动作携带完整 `VolumeInstanceID`；磁盘重插后旧点击不会重新绑定到新介质。当前写入要求用户在本次连接中明确确认数据卷用途，并与 fresh 候选和精确 sibling 拓扑重新核对；确认不能缓存、跨重插复用或伪装成系统角色证据。
- 可写挂载前要求卷仍为 clean、经当前请求批准的外置 data NTFS；helper 可先卸载其原生只读挂载。
  整盘推出前要求同盘分区满足当前安全条件。用途未知的候选必须由用户本次确认且通过 fresh 核对才可请求写入；
  安全推出由 helper 独立重新核对整盘身份与分区集合。
- 命令成功不等于最终成功；写入与推出都需要新的系统观察结果复核。
- 休眠、dirty、健康未知、内部或其他 `protected` 卷默认拒绝写入。
- 内部、`protected` 或含受保护分区的物理盘不会提供整盘推出；生产观察不按卷名声称精确识别
  Boot Camp。
- helper 在同一进程的所有 XPC 连接间共享整盘执行租约；App 对超时、断线或无效响应保持结果未确认，
  暂停本次会话中该盘的其他操作，不自动重发。操作结束后重新观察系统状态；不能仅凭请求返回就提示可拔出。
- 公开接口没有强制卸载、`remove_hiberfile`、自动恢复或内核扩展回退。
- 健康探针解析器只接受单行版本化协议；helper 的可写挂载只使用固定的 FSKit 参数，详见 ADR 0010。
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
- 固定摘要的 NTFS-3G 2026.7.7 本机制品；有限实物验证不等于 Gate 2 或分发批准
- macFUSE 5.4.0 FSKit local 是 ADR 0010 中已验证的本机组合，尚未形成跨版本验证矩阵
- macFUSE FSKit backend

Swift Package 的部署下限已设为 macOS 15.4。Setup 只读检查展示系统、依赖与冲突状态；独立
可信报告未配置时不会据此判定依赖缺失或永久关闭写入。PlugInKit 没有显式 `use` 标记也不能
证明 FSKit 不可用，因此 App 不以该只读结果隐藏已满足磁盘安全条件的写入入口。helper 的
安装与系统批准状态独立展示；helper 在卸载原生只读卷之前重新核对目标事实和 FSKit 正信号，
未确认时拒绝本次操作并保持原生挂载。当前签名调用方可能看不到已可用的跨 Team macFUSE 模块，
所以这项保守门禁仍需在受保护部署下验证；详见
[FSKit 运行时写入前检查](docs/research/fskit-runtime-preflight.md)。

## 本地构建与界面检查

构建并打开包含 helper 文件的本机签名检查件：

```bash
scripts/build-local-app.sh
open .build/NTFSLite.app
```

构建脚本需要本机 Apple Development 签名身份，以及 `.build/dependency-candidates/` 中与脚本摘要
一致的两个固定 NTFS-3G 制品。`.build/NTFSLite.app` 位于用户可写目录，只用于构建、签名与界面
检查；不能从此路径启用特权 helper 或执行真实挂载、卸载、推出。写入路径另需已配置的 macFUSE
FSKit。

首次受保护安装使用系统 Installer 安装包：

```bash
scripts/build-local-installer.sh
python3 scripts/verify-local-installer.py .build/NTFSLite-local.pkg .build/NTFSLite.app
scripts/install-local-installer.sh
scripts/verify-protected-install.sh
open /Library/PrivilegedHelperTools/NTFSLite.app
```

包的 payload 固定为 `/Library/PrivilegedHelperTools/NTFSLite.app`。安装入口先将本地未签名 pkg
复制到 root 所有的暂存目录，对不可由普通用户改写的副本做离线核验，Installer 使用同一副本；
包内预检拒绝已有目标或不可信父目录。安装不会自动注册 helper 或操作磁盘。安装后先通过验证
脚本核对 root 属主、权限、ACL、完整文件清单与签名，再在已安装 App 的“运行环境”页点击
“启用帮助程序”或“尝试注册帮助程序”，按 macOS 系统设置提示由管理员批准。App 只在
签名 XPC 健康检查通过后开放写入入口，实际磁盘操作仍由 helper
逐次重新核对。本包只支持**首次安装**，已有目标时不会覆盖；更新、卸载与旧服务清理尚无安全
自动流程。本机只有 Apple Development 身份，此包不是 Developer ID 签名／公证的分发制品。
Apple SDK 27 对含 LaunchDaemon 的 App 写有公证要求；旧 tracer 的本机开发签名成功经验不能
替代当前安装件的注册实测。详见 [ADR 0012](docs/adr/0012-protected-local-install-and-live-helper-check.md)。

安装包与暂存交接的离线回归另运行 `python3 scripts/test_local_installer.py` 和
`python3 scripts/test_install_local_installer.py`；测试不会调用管理员授权或 Installer。
当前已安装的旧构建不含“尝试注册”按钮，首次安装包也拒绝覆盖它；更新须先完成单独的
受保护替换流程，不能直接重跑首次安装命令。

`scripts/build-local-read-only-app.sh` 仅构建不包含 helper 的只读打包检查件，输出为
`.build/NTFSLiteReadOnlyApp.app`，不是上述正式 App。

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

需要 Apple Silicon Mac、macOS 15.4+、支持 Swift 6 的命令行工具链及 Python 3.11+。该入口会执行
全量 warnings-as-errors Release 构建、行为检查、CLI 输入回归、只读包/源码边界、无 helper
检查件构建与签名验证，以及篡改包负向回归。正式签名 App 需另行运行
`scripts/build-local-app.sh`。任一步失败立即退出；这些构建与检查不会安装 helper 或改变磁盘。
排查单项失败时，可单独运行 `swift run -c release -Xswiftc -warnings-as-errors NTFSLiteCoreChecks`
或 `scripts/` 下对应检查脚本。`.build/` 和根目录临时 Swift 编译产物不进入 Git；
`.scratch/ntfs-mvp/` 中的工单和脱敏证据属于版本化项目记录。

仓库行为检查覆盖设置门禁、typed 依赖证据、完整实例请求、非法观察身份拒绝、枚举覆盖失败关闭、最终卷预检、显式挂载证据、介质代次防重插、一次性变更授权、helper 原子准入、真实可写复核、推出前子卷复检、内部盘保护、回调与拔盘乱序、事件源终止、连续刷新隔离、写入及推出超时收敛、整盘部分卸载收敛、完整 sibling 清单同步、畸形清单拒绝、私有诊断存档、inventory 重建、Gate 1 recorder 的 opaque ID、单一 target、absence baseline、逐轮 comparison 窗口、unverified pending、stop-and-drain/FIFO seal、自然 source end、最终 observation 未验证、100-cycle/隐私/限制/永久失败关闭，以及 canonical verifier 的摘要、重复键、篡改和事件重放。数量以检查器本次完整成功输出为准；中途终止不能计为通过。

## 代码导航

| 目录 | 职责 |
| --- | --- |
| `Sources/NTFSLiteCore` | 领域状态、设置门禁、声明与协调器纯契约 |
| `Sources/NTFSLiteSystem`、`NTFSLiteReadOnlyProbing` | 只读系统证据与固定 Setup 探针 |
| `Sources/NTFSLitePresentation`、`NTFSLiteReadOnlyApp` | 展示映射与正式 SwiftUI 应用（target 名保留 ReadOnlyApp） |
| `Sources/NTFSLiteDiagnostics` | 脱敏诊断与私有本地存档 |
| `Sources/NTFSLiteGateEvidence`、`NTFSLiteGate1EvidenceTool` | 独立匿名取证、封存与核验 |
| `Sources/NTFSLiteWriteSession` | 正式 App 的一次性写入与推出会话 |
| `Sources/NTFSLiteHelperProtocol`、`NTFSLiteHelperExecution`、`NTFSLiteHelper` | XPC 协议、特权执行与 launchd helper |
| `Sources/NTFSLiteMutationPreparation` | 保留的请求、安全挂载编译与适配纯逻辑 |
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
- [旧只读检查件的本地构建与回滚](docs/release/local-read-only-release.md)
- [交付地图与本地 Issues](.scratch/ntfs-mvp/MAP.md)

## 安全边界

第一版明确不做：

- 格式化、分区、擦除、检查或修复 NTFS。
- 强制卸载、强制推出或自动关闭占用磁盘的应用。
- 删除 Windows 休眠文件或自动清除 NTFS 日志。
- 内部 NTFS、Boot Camp 或 BitLocker 写入。
- 自动可写挂载。
- kext、降低启动安全性、关闭 SIP 或替换系统文件。

正式 App 的代码已接入真实挂载与推出；当前 `.build` 检查件不得执行。完成受保护安装验证后，
开发和验证中的磁盘操作仍只允许在一次性镜像或已授权的可牺牲 U 盘上执行，并在每次操作前
核对当前目标和失败关闭条件。不要用用户数据盘或唯一副本测试。
