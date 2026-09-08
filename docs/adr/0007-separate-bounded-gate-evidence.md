---
status: accepted
---

# 把有界 Gate 证据工具链与正式应用分开

Gate 1 的实物验证需要为同一个专用 target 连续记录 100 次连接生命周期、在每轮 target 确认
出现与确认消失之间完成系统清单和 mount table 对照，以及覆盖多分区、睡眠、唤醒重订阅、
正式应用重启和声明失效检查点。人工转写容易遗漏，但把原始
Disk Arbitration 描述、BSD 名、UUID、卷标或挂载路径写入日志又会扩大隐私与语义边界。
本项目因此用独立的 `NTFSLiteGateEvidence` target 把 typed `DiskInventoryObservation` 投影为
匿名、有界、可重放核验的证据；本地 `NTFSLiteGate1EvidenceTool` 只负责接入只读 observer、
接受封闭的操作者检查点并通过标准输入输出采集或校验证据。

正式 `NTFSLiteReadOnlyApp` 不依赖证据模块或命令行工具。证据模块只依赖 Core、System 与共享
的严格 JSON 语法模块，工具只依赖证据模块和 System；两者都作为独立只读 root 接受包依赖和
源码边界检查，不能到达 mutation 或 helper。System 的既有依赖图仍包含隔离的固定 Setup
只读探针，但证据模块和 CLI 不得实例化其 `Process` runner，也不能把它扩展为通用命令入口。

每个 Evidence-ID 必须是 `G1-` 加 32 位大写十六进制的无语义随机值，不能编码操作者、日期、
磁盘名或序列号。记录器只在内存中用原始磁盘身份关联连接；schema 2 封存内容只包含数字别名、
固定枚举、计数、时间、应用版本/build/二进制摘要和封闭检查点。观察、检查点、单次磁盘数、
单盘卷数和编码字节数都有固定上限；超限、时间倒退、拓扑矛盾或介质代次异常会永久失败关闭，
不驱逐旧记录来伪装完整。输出使用 sorted-key canonical JSON 和独立 SHA-256；校验先验证摘要
与严格 JSON（包括重复键），再核对 schema、canonical bytes、派生计数、事件重放和 verdict。

会话把第一个完整的只读 candidate 绑定为唯一匿名 target，100 轮只能累计该 target 的后续介质
代次；第二个可复核 candidate 会产生拓扑矛盾。常驻内置盘和其他非 candidate 物理盘仍可出现在
匿名观察中，但不进入 target 的未确认连接计数，也不阻塞 readiness。任何 target 连接只有在此前
已有 verified target absence baseline 时才具备轮次资格；因此采集启动时已经插入的 target 必须先
确认消失，该次启动连接不计为第 1 轮。每轮两项 comparison checkpoint 都必须位于该轮 target
的 verified candidate 出现之后、verified absence 之前。unverified 观察只暂停 comparison 与结算，
不会把 pending 当作消失；随后 verified candidate 可以恢复对照，随后 verified absence 才能结算。

2026-09-08 补充：BSD 名可被另一块盘复用，因此 target 还在会话内固定首次完整 candidate 的
规范化卷 UUID 清单（排序并保留数量）。同一连接或新连接中的完整候选清单变化均永久记录
`topologyContradiction`；unverified pending 不更新绑定。清单不写入 artifact，也不产生授权。
UUID 克隆以及真实物理盘连续性仍须人工复核；匿名 verifier 不能从已脱敏的 schema 2 恢复或
独立证明原始身份。旧 artifact 不会因新代码而补得这项采集期验证。

显式 `seal` 是有序封存协议，不是取消观察任务。CLI 必须先请求 Disk Arbitration 事件源在其
专用串行队列上 stop-and-drain：停止接收新回调，并等待此前已经排入队列的回调全部交付后，
才向 observer 发送唯一的 `drainBoundary`。observer 收到该边界后必须强制完成一次最终 settle
与独立 IOKit enumeration，再把最终 observation 和 capture terminal 按同一 FIFO 输出；CLI
转发 observation 或 terminal 派生的 source failure 后，才可在同一 recorder 事件 FIFO 中排入
seal。显式封存路径不得通过 Task cancellation 抢先终止 observation task，也不得把输入 `seal`
时缓存的上一帧当作最终事实。

没有有效 `drainBoundary` 的自然 source end 永久记录为 `observationStreamEnded`；排空完成但
最终 observation 仍未验证则永久记录为 `finalObservationUnverified`。两者都让会话失败关闭，
后续状态不能把它恢复为 incomplete 或 review-ready；操作者显式封存时只能得到如实携带失败码的
`failedClosed` artifact。

verdict 的类型只有 `failedClosed`、`incomplete` 和 `readyForHumanReview`。最后一种除其他结构条件
外，还要求 canonical observations 最后一帧的 `coverage` 为 `verified`。即使 failure codes 为空，
最后一帧 unverified 也只能是 `incomplete`；verifier 必须从 canonical observations 独立重算该前提
和 verdict，不能信任 bundle 自报结论。`readyForHumanReview` 只表示已达到送交人工复核的结构
条件，类型中不存在 `pass`，也不能创建或替代实施计划要求的人工 Gate Evidence。CLI 只把
canonical JSON 写到标准输出，把操作提示、状态、错误和 SHA-256 写到标准
错误，避免两类字节被合并成不可验证的 artifact。只有显式 `seal` 才能生成 artifact；命令输入
EOF 或读取失败会在封存前退出，不输出 canonical bytes。

## Considered Options

- 把采集状态并入正式只读 App：拒绝，因为长期状态、交互刷新和应用重启会让证据生命周期与
  产品状态耦合，也会使“重启正式应用”检查点无法由独立观察者连续记录。
- 保存 Disk Arbitration 原始描述、命令输出或自由文本日志：拒绝，因为它们可能包含磁盘、卷、
  用户和路径身份，且无法用封闭 schema 重放验证语义。
- 使用无上限数组，或超限时淘汰较早记录：拒绝，因为长时间运行会失控，淘汰又可能把不完整
  生命周期误写成满足要求的连续证据。
- 收到 `seal` 后取消 observation task 并直接编码当前状态：拒绝，因为取消无法证明此前排队的
  Disk Arbitration 回调已消费，也会跳过边界后的最终 settle、独立枚举和 terminal 顺序。
- 只校验 JSON 可解码或摘要匹配：拒绝，因为未知字段、重复键、非 canonical 编码或伪造派生
  计数仍可能产生歧义。
- 在工具达到固定数量后自动宣布 Gate 通过：拒绝，因为工具无法证明外置盘是否专用、人工对照
  是否真实、截图/系统清单是否匹配，也不能替代 Gate 负责人签署。

## Consequences

- Gate 1 可以得到可重复校验的匿名证据包，同时不把原始磁盘身份写入 artifact。
- 一个会话只累计单一匿名 target；常驻内置盘不会伪装成 target 或阻塞 target 的结算，但出现
第二个可复核 candidate 会让会话失败关闭。
- 启动时已插入的 target、comparison 窗口外检查点和 unverified pending 都不能被乐观计数；
  操作者必须取得 verified absence baseline，并在每个合格连接窗口内完成两项逐轮对照。
- 显式封存会等待 Disk Arbitration 串行队列排空、边界后的最终 settle/独立枚举和 capture
  terminal；自然 source end 或未验证的最终 observation 都永久失败关闭，不能靠稍后的 seal
  恢复。
- `readyForHumanReview` 仍要求人工核对专用硬件、每轮外部系统事实和无磁盘变更证明；仓库 Gate
  状态只能由实施计划和人工 Evidence 更新。
- canonical 最后一帧 coverage 不是可相信的摘要字段；recorder 与 verifier 都从 observation frame
  派生 readiness。无失败码但最后一帧 unverified 的 artifact 只能保持 `incomplete`。
- 证据工具不会随本地只读 App 打包，也不能被 App 间接引入；新增依赖必须同时通过
  `scripts/check-read-only-boundary.sh` 的三个只读 root 检查。
- 共享 `NTFSLiteStrictJSON` 只提供严格 JSON 语法边界，不让证据模块依赖 helper，也不让 helper
  进入只读证据依赖图。
- schema 2、固定检查点、匿名 target 投影或容量策略变化时必须新增行为检查并重新评估兼容
  策略；默认校验仍拒绝未知 schema 和非 canonical bytes。
- 本 ADR 不证明截至 2026-08-31 已取得任何真实外置盘证据，不授权挂载、卸载、推出、修复、
  格式化或写入磁盘。
