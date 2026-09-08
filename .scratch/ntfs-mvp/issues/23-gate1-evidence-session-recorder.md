# 自动记录 Gate 1 只读证据会话

Status: resolved
Labels: enhancement, resolved
Assignee: Codex
Blocked-by:

## 问题

Issue 02 需要 100 次真实外置盘连接生命周期、多分区、睡醒和应用重启证据。现有只读 observer
能失败关闭地生成 typed 系统事实，但没有把连续观测收敛为匿名、有界、可核验的证据包；完全
人工记录容易遗漏代次、absence、拓扑和不完整观测。fixture 或自动工具也绝不能自行把 Gate
标记为通过。

## 验收

- 新增独立 `NTFSLiteGateEvidence` 模块，只依赖 Core、System 与中立的严格 JSON 语法模块；正式
  只读 App 不新增该依赖。
- recorder 只消费 `DiskInventoryObservation` 和封闭 checkpoint，不执行命令或任何磁盘变更。
- 运行期原始磁盘/卷身份只用于内存关联；canonical bundle 只含数字别名、固定枚举、计数、
  时间和摘要，不含 BSD 名、UUID、卷标、mount point、用户名或用户路径。
- Evidence-ID 只接受固定的 `G1-` + 32 位大写十六进制无语义值，不能承载操作者、日期或磁盘
  身份；canonical bundle 当前 schema 固定为 2。
- 首个完整 candidate 绑定唯一匿名 target，100 轮只能累计该 target；第二个 reviewable candidate
  失败关闭，常驻内置盘和非 candidate 盘不进入 target 未确认连接计数。
- 同一次 present 生命周期代次必须稳定；第 1 轮前必须已有 verified target absence baseline，
  启动时已插盘的首次连接不能计数。每轮两项 comparison 只允许在该轮 target verified present
  与 verified absence 之间记录；unverified pending 只暂停对照和结算，随后 verified absence 才能
  完成 cycle。未确认移除、重插复用代次、拓扑矛盾、乱序时间和容量溢出均失败关闭或保持 incomplete。
- 默认要求同一 target 的 100 个完成 cycle，并记录多分区、睡醒重订阅、应用重启分段、声明
  失效演练、逐轮两项 comparison、严格 Release 与只读边界摘要；不足时只能 `incomplete`。
- 输出 verdict 只有 `failedClosed`、`incomplete`、`readyForHumanReview`，类型上不存在 `pass`；
  `readyForHumanReview` 也不能创建或替代人工签署的 Gate Evidence。
- `readyForHumanReview` 的派生条件必须包含 canonical observations 最后一帧 `coverage=verified`；
  即使 failure codes 为空，最后一帧 unverified 也只能 `incomplete`。verifier 不信任 bundle 自报
  verdict，必须从 canonical observations 独立重算。
- canonical JSON 使用 schema 2、sorted keys 和 SHA-256；未知 schema、非 canonical 字节、
  摘要不一致或篡改均不能通过 verifier。
- CoreChecks 使用公共 recorder 接口覆盖 100-cycle、重复 callback、多分区、代次/拓扑异常、
  opaque ID、单一 target、absence baseline、comparison 窗口、unverified pending、常驻盘、隐私
  poison、限制、seal 后重放和篡改场景。
- CLI 只有收到显式 `seal` 才输出 artifact；命令输入 EOF 或读取失败不输出 canonical bytes。
- 显式 `seal` 不得 cancel observation task：先在 Disk Arbitration 专用串行队列 stop-and-drain，
  仅在已排队 callback 全部交付后发出 `drainBoundary`；observer 再强制完成最终 settle 与独立
  IOKit enumeration。最终 observation 和 capture terminal 必须同 FIFO，terminal 消费后才可
  排入 recorder seal。
- 没有有效 `drainBoundary` 的自然 source end 永久记录 `observationStreamEnded`；最终 observation
  未验证永久记录 `finalObservationUnverified`。两者均只能产生 `failedClosed`，后续事件不得恢复。
- 严格 Release、warnings-as-errors 与 `scripts/check-read-only-boundary.sh` 全部通过。

## 评论

本 Issue 只减少 Gate 1 取证的人工作业量，不构成真实硬件证据，也不改变 Issue 02 的
`ready-for-human` 状态。

2026-08-31 软件切片已完成：新增独立 `NTFSLiteGateEvidence`、本地
`NTFSLiteGate1EvidenceTool capture/verify`、共享 `NTFSLiteStrictJSON`，以及把正式 App、证据
模块和 CLI 分别作为只读 root 的依赖/源码边界检查。公共行为检查已覆盖匿名投影、确认
verified present→absence 才结算 cycle、schema 2 与 opaque Evidence-ID、单一匿名 target、启动
已插盘的 absence baseline、常驻内置盘不阻塞、逐轮 comparison 窗口、unverified pending、
100-cycle 仍不产生 pass、封闭 checkpoint、时间/代次/拓扑异常、观察/检查点/磁盘/卷/编码容量、
永久失败关闭、显式 seal 的 DA 串行 stop-and-drain、`drainBoundary` 后最终 settle/独立 IOKit
enumeration、observation/terminal FIFO、自然 source end、最终 observation 未验证、EOF/读取失败
零输出、canonical 摘要、重复键、派生字段篡改与事件重放。显式 seal 路径不会取消 observation
task；capture terminal 处理完成后才排入 recorder seal。recorder 与 verifier 还分别从 canonical
observations 最后一帧 coverage 派生 verdict，确保无 failure code 的 unverified 尾帧只能
`incomplete`，不能伪装成 review-ready。

## Resolution

2026-09-08 仓库审查修正：同一个 `diskN` 可在拔盘后被不同 UUID 的磁盘复用。原实现仅比较
BSD 对应的匿名 diskOrdinal，因此遗漏了跨连接换盘。新增公共 recorder 回归先复现 RED；
现在首次完整 target 的规范化 candidate UUID 清单只保存在内存，后续完整清单（含数量）
变化即原子拒绝观测并永久 `topologyContradiction`，不累计替换盘轮次。schema 2 与原证据不变；
旧 artifact 不包含该新增采集期保证，UUID 克隆仍需人工核验。该修复不关闭硬件 Gate。

2026-08-31：软件切片已完成并按公共接口走完 RED、GREEN、重构。最终补充了 typed `VolumeID`
仅大小写不同的重复卷负向样例；recorder 先解析并规范化有效 UUID，再用同一 canonical 值比较
evidence 与建立卷别名，非法 typed UUID 和大小写重复拓扑都原子失败关闭。

严格 Release CoreChecks、完整 warnings-as-errors Release 构建、只读源码/依赖边界、本地 App
正向验包和 5 组篡改包负向样例全部通过。一次新的本机只读 capture 可生成并独立验证 canonical
artifact，隐私模式扫描为 0；本机最终观察因覆盖未验证而正确封存为
`finalObservationUnverified / failedClosed`。EOF 路径返回 65 且输出 0 字节。

这些结果只关闭 Gate 1 recorder 的软件实现，不构成专用外置盘、100 轮生命周期或人工 Gate
签署；Issue 02 仍保持 `ready-for-human`，必须在可牺牲测试盘上完成真实硬件证据。

2026-08-31 后续诊断确认，上述本机 `finalObservationUnverified` 来自 Disk Arbitration 明确标记的
范围外网络卷，而非 recorder、stop-and-drain 或 IOKit 枚举竞态。Issue 24 收紧网络标记类型并
排除明确网络卷后，连续 3 个新 capture 均以最终 verified observation 封存为无失败码的
`incomplete`，且通过独立 verifier。原 failed-closed artifact 仍是修复前行为的有效诊断证据，
但不再代表当前软件状态。
