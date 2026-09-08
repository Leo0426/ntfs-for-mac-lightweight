# Gate 验证运行手册

本手册只规定证据如何记录，不授权在当前用户数据盘上试验。实际 Gate 定义和状态只见
[`docs/engineering/implementation-plan.md`](../engineering/implementation-plan.md)。

## 开始前

- 写下操作者、日期、Mac 型号、macOS 构建、应用构建和所有依赖摘要。
- Gate 2/3 必须使用一次性镜像或可牺牲盘；确认测试数据另有副本。
- Gate 3 必须准备 Windows 复核环境。
- 任何身份、健康、父子关系、挂载来源或后端事实未知时立即停止。

## Gate 1 只读证据

- 对同一块专用 target 记录每次插入、完整事实、移除和下一次介质代次，共 100 次；不能把不同
  物理盘的轮次相加。常驻内置盘可以继续存在，但不属于 target，也不阻塞 target 结算。
- 覆盖单分区、多分区、同 BSD 名重插、睡眠/唤醒和应用重启。
- 每轮只在 target 的 verified candidate 已出现、verified absence 尚未发生时，与系统磁盘清单和
  mount table 对照；矛盾或缺失单独编号。unverified pending 只暂停对照与结算，不能当作 absence。
- 逐次证明可信内部位置只映射为通用 `protected`；外置 NTFS 默认显示“用途未确认”的
  candidate，且 `coordinatorInventory` 为空，不按卷名声称 Boot Camp/data。
- 覆盖当前连接声明在重插、应用重启、睡醒重订阅、sibling 拓扑变化和一次消费后的失效；声明
  始终记录为人类策略输入，不得记录成 System Evidence。
- 证明测试期间没有产生 mount、unmount、eject、repair 或写入调用。

### 使用本地证据工具采集

`NTFSLiteGate1EvidenceTool` 是独立只读辅助工具，不进入正式 App。它生成 schema 2 artifact，
只记录匿名数字别名、固定问题码、计数、时间、版本/摘要和封闭检查点；不能记录截图或替操作者
执行系统清单、mount table 与专用硬件对照。先构建并核验本地只读 App、严格 Release 和只读
边界，再在仓库根目录准备工具：

Disk Arbitration 明确以 CFBoolean `VolumeNetwork=true` 标记的网络卷不属于物理盘 inventory，
不会阻塞 Gate 采集；缺失、类型错误或 `false` 的标记不能被猜成网络卷，无 BSD 身份事件仍会
失败关闭。若 IOKit 枚举发现被错误排除的物理介质，集合核对不会升级为 verified。

```zsh
scripts/build-local-read-only-app.sh
swift run -c release -Xswiftc -warnings-as-errors NTFSLiteCoreChecks
swift build -c release -Xswiftc -warnings-as-errors --product NTFSLiteGate1EvidenceTool
python3 scripts/check-gate1-cli-input.py
scripts/check-read-only-boundary.sh

BIN_DIR=$(swift build -c release --show-bin-path)
GATE_TOOL="$BIN_DIR/NTFSLiteGate1EvidenceTool"
APP_BUNDLE=".build/NTFSLiteReadOnlyApp.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/NTFSLiteReadOnlyApp"
APP_VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP_BUNDLE/Contents/Info.plist")
APP_BUILD=$(plutil -extract CFBundleVersion raw "$APP_BUNDLE/Contents/Info.plist")
APP_SHA256=$(shasum -a 256 "$APP_BINARY" | awk '{print $1}')
```

命令输入可以保持打开；等待输入或只收到半行时，系统观察必须继续运行。`status` 和 `seal`
在收到换行后立即处理，不要求关闭管道或填满读取缓冲区。上述 Python 3 标准库检查会启动真实
只读 CLI，验证开放管道、半行等待、超长/非法编码恢复和 EOF/读取失败；使用临时占位应用
身份并丢弃 artifact，因此不能当作 Gate 硬件证据。

每次重新开始都在本地生成新的无语义 Evidence-ID。格式必须严格为 `G1-` 加 32 位大写十六进制；
不要把日期、操作者、卷名、磁盘名或序列号写入 ID。下列 `uuidgen` 结果只作为随机 opaque 值，
不承载身份语义。采集命令保留终端标准输入供操作者输入固定命令；canonical JSON 单独保存自
标准输出，状态、错误和最终摘要保存自标准错误：

```zsh
EVIDENCE_ID="G1-$(uuidgen | tr -d '-' | tr '[:lower:]' '[:upper:]')"
EVIDENCE_DIR=".scratch/ntfs-mvp/evidence/$EVIDENCE_ID"
mkdir -p "$EVIDENCE_DIR"

"$GATE_TOOL" capture \
  "$EVIDENCE_ID" "$APP_VERSION" "$APP_BUILD" "$APP_SHA256" \
  > "$EVIDENCE_DIR/gate1-canonical.json" \
  2> >(tee "$EVIDENCE_DIR/gate1-capture.stderr" >&2)
```

### 建立 target baseline 并执行每一轮

- 一个会话只允许一个 reviewable external candidate。首个完整 candidate 会绑定为匿名 target；
  测试期间不要连接第二块会形成 candidate 的外置盘，否则会话因多 target 拓扑矛盾失败关闭。
  常驻内置盘和其他非 candidate 盘可以保留，它们不会进入 `未确认移除` target 计数。
- 第 1 轮前必须先有 verified target absence baseline。若启动采集时 target 已插入，该连接只用于
  绑定 target，不能计数：先用 `status` 确认 target 已被观察为 `未确认移除=1`，拔出后继续查看
  `status`，直到 `未确认移除=0` 且循环仍为 `0/100`。这才证明 recorder 已收到 verified absence；
  随后重新插入同一 target 才开始第 1 轮。
- 若在 target 未插入时启动，也必须等只读 observer 取得 verified absence 后才开始第 1 轮。
  常驻内置盘不会阻止这个 baseline；最终 cycle 计数和 verifier 仍会重放检查该前置条件。
- 第 N 轮重新插入同一 target 后，等待其成为 verified candidate。分别完成外部系统清单和 mount
  table 对照，然后在仍连接的同一轮内输入
  `checkpoint systemInventoryComparison N ...` 与
  `checkpoint mountTableComparison N ...`。两项都必须在该轮 target verified present 之后、
  verified absence 之前，不能提前、补录、跨轮或重复。
- 出现 unverified 观察时进入 pending：不要把 comparison 命令当作探针，也不要结算或开始下一轮。
  若 target 仍连接，等待后续 verified candidate 后再执行/记录对照；若已拔出，等待后续 verified
  absence。只有 verified absence 才会让 `未确认移除` 归零并把循环增加到 N。

采集期间只接受以下固定命令；逐轮对照必须在实际核对后才输入 `confirmed`，缺失时输入
`notPerformed`，矛盾时输入 `contradicted` 并让会话失败关闭。`applicationRestart` 指重启正式
只读 App，证据工具自身保持运行。

```text
status
checkpoint multiPartitionTopology confirmed
checkpoint sleep confirmed
checkpoint wakeResubscription confirmed
checkpoint applicationRestart confirmed
checkpoint systemInventoryComparison 1 confirmed
checkpoint mountTableComparison 1 confirmed
checkpoint declarationInvalidatedAfterReinsert confirmed
checkpoint declarationInvalidatedAfterWake confirmed
checkpoint declarationInvalidatedAfterRestart confirmed
checkpoint declarationInvalidatedAfterTopologyChange confirmed
checkpoint declarationInvalidatedAfterConsumption confirmed
checkpoint strictReleaseChecks confirmed
checkpoint readOnlyBoundaryReview confirmed
seal
```

`systemInventoryComparison` 和 `mountTableComparison` 的 round 必须分别覆盖 `1...100`；上面的 round
1 只是命令格式示例。只有显式输入 `seal`，工具才开始以下有序封存；输入后等待工具自然完成，
不要用 Ctrl-C 或其他 Task cancellation 代替封存：

1. 工具不取消 observation task，而是请求 Disk Arbitration source 在其专用串行队列上
   stop-and-drain。source 先停止接收新回调，再用队列 barrier 等待此前已排入队列的回调全部交付，
   最后发送唯一的 `drainBoundary`。
2. observer 在 `drainBoundary` 之后强制发布一次 pending，完成最终 settle，并执行独立 IOKit
   enumeration。最终枚举失败、超时或覆盖不一致都不能被当作 verified。
3. capture 将最终 observation 和 terminal 放入同一 FIFO；CLI 再把 observation 或 terminal
   派生的 source failure 放入 recorder 的同一事件 FIFO，确认 terminal 已消费后才排入 seal。
   因此 stderr 出现摘要前仍可能出现最终观察产生的失败状态。

自然 source end 没有有效排空边界，会永久记录 `observationStreamEnded`；排空完成但最终 observation
未验证，会永久记录 `finalObservationUnverified`。两者都只能封存为携带对应失败码的
`failedClosed` artifact，后续 verified 事实或再次输入 `seal` 都不能恢复会话，必须用新
Evidence-ID 重来。工具完成有序封存后才把 JSON 写完，并在 stderr 打印 `SHA-256:`。

verdict 还有一层独立的 canonical 防线：`readyForHumanReview` 必须以 observations 最后一帧
`coverage=verified` 为前提。即使 artifact 没有任何 failure code，最后一帧 unverified 也只能是
`incomplete`；`verify` 会从 canonical observations 独立重算这一条件和 verdict，而不是信任 JSON
中自报的 verdict。live capture 的 terminal 若明确报告最终 observation 未验证，还会按上一段
额外写入 `finalObservationUnverified`，因此是 `failedClosed`，不是这一无失败码的 incomplete 情形。

Ctrl-D/命令输入 EOF 或输入读取失败会在封存前退出，不输出 canonical bytes；shell 重定向可能
留下零字节目标文件，但它不是 artifact，必须丢弃并用新 Evidence-ID 重来。不要使用 `2>&1`，
否则人类状态文字会污染 canonical bytes。提取摘要到独立 sidecar，再用同一个工具的 `verify`
路径重新验证：

```zsh
sed -n 's/^SHA-256: //p' \
  "$EVIDENCE_DIR/gate1-capture.stderr" \
  | tail -n 1 > "$EVIDENCE_DIR/gate1-canonical.sha256"

EXPECTED_SHA256=$(tr -d '\n' < "$EVIDENCE_DIR/gate1-canonical.sha256")
"$GATE_TOOL" verify "$EXPECTED_SHA256" \
  < "$EVIDENCE_DIR/gate1-canonical.json" \
  > "$EVIDENCE_DIR/gate1-verify.stdout" \
  2> >(tee "$EVIDENCE_DIR/gate1-verify.stderr" >&2)
```

`gate1-verify.stdout` 按当前协议应为空；验证结论、摘要与结构进度只在
`gate1-verify.stderr`。将 canonical JSON、`.sha256`、capture/verify stderr、人工对照材料及各自
SHA-256 一起登记到 Evidence 文档。CLI 输出的 `readyForHumanReview` 绝不等于 `Result: pass`；
先确认 canonical observations 最后一帧为 verified，再由人工复核专用外置盘、100 轮外部事实、
声明失效和全程零磁盘变更，才能按本手册签署结果。
如果 capture stderr 出现 `observationStreamEnded`、`finalObservationUnverified` 或 verdict
`failedClosed`，保存该失败 artifact、摘要和 stderr 供诊断，但它不能提交为 Gate 1 通过证据。

## Gate 2 镜像证据

- 记录精确依赖目录、镜像初始哈希和每个阶段的固定结果码。
- 记录 macFUSE 所选精确版本的同一批准条目：指定 requirement、Team ID、CodeDirectory
  identity 以及同一个已验证 `SecStaticCode` 的 secured Info.plist identifier/version；确认任一
  漂移、目录缺失或跨版本 identity 复用都使 Setup 未就绪。
- 记录具名冲突 scope ID、目标平台、三个候选制品摘要、loaded identifier、installed footprint
  三态和环境基线；不得把有限范围结果写成“已检查全部商业驱动”。
- 健康、dirty、休眠、未知、错误后端、重挂载、超时、取消和崩溃逐项执行。
- 只有新的完整事实能确认可写或已移除；命令退出码不能作为最终结果。
- 任一元数据变化、卸载残留、路径 TOCTOU 或依赖漂移立即停止。

## Gate 3 物理盘证据

- 按实施计划完成文件语义、容量、并发、断连、多分区和 100 次生命周期。
- 每轮回 Windows 完整检查并比较内容哈希。
- 新错误、哈希不一致、提前显示成功或出现禁止选项时立即停止。

## Gate 4 UI 与正式接线证据

- 关联 Gate 1–3 的通过 Evidence-ID；任一缺失、过期或依赖漂移时不得开始 mutation 接线。
- 记录 320 pt、浅色、深色、高对比、键盘和 VoiceOver 的人工结果；自动 snapshot 或 agent smoke
  不能替代人工证据。
- 证明只读 candidate 仍只进入 `ReadOnlyDashboardPresentation`，正式 mutation UI 只消费
  `VolumePresentation`；View 不构造声明、System Evidence、命令、路径或参数。
- 对每个动作记录 fresh 事实复核和一次性消费；重复点击、旧选择或旧声明产生零次系统变更。

## Gate 5 本地候选证据

- 记录 Developer ID、Hardened Runtime、entitlement、公证 ticket、依赖摘要与本地安装/卸载结果。
- 记录 helper 最小权限、升级/回滚、崩溃恢复和无残留验证；ad-hoc 本地包不计为 Gate 5 候选。
- 两周个人非关键数据使用逐日关联 Evidence-ID；任何数据不一致、Windows 新错误或依赖漂移都会
  终止候选并重新打开相应 Gate。

截至 2026-08-31，仓库没有任何 `Result: pass` 的 Gate 1–5 Evidence-ID；代码、纯逻辑检查、
Gate 1 recorder/CLI、`readyForHumanReview` artifact、当前 Mac 只读 smoke 和本地 ad-hoc 包都不能
改变这一状态。

## 单条证据模板

每条证据存放在 `.scratch/ntfs-mvp/evidence/<Evidence-ID>.md`；关联的截图、日志或哈希清单
放在同名目录中。证据文档只记录仓库相对路径和每个 artifact 的 SHA-256，不嵌入原始卷标、
用户名、BSD 名、磁盘/卷 UUID 或用户路径。目录不存在不代表 Gate 已取得证据；创建空模板也
不能计为 pass。

```text
Evidence-ID:
Gate:
Date:
Operator:
Hardware / image alias:
macOS build:
App build and SHA-256:
Dependency manifest revision:
Preconditions:
Steps:
Observed system facts:
Expected invariant:
Result: pass | fail | incomplete
Artifacts:
Artifact SHA-256:
Follow-up issue:
```

`incomplete` 不能计为 pass；失败后的下一轮必须使用新的 Evidence-ID。
