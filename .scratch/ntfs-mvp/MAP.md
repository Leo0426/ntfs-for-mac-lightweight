# NTFS MVP 交付地图

更新时间：2026-09-08

本地图把当前代码完成度与仍需取得的证据分开。Gate 状态仍只由
[`docs/engineering/implementation-plan.md`](../../docs/engineering/implementation-plan.md)定义。

2026-09-08 实物增量：用户已提供可牺牲 USB-1；完成一轮插入状态只读取证并修复 CLI 等待输入
阻塞采集的问题（[Issue 28](issues/28-responsive-gate1-command-input.md)，resolved）。系统未返回
NTFS 卷 UUID；后续通过 FD 绑定的原生文件系统 UUID 形成了只读 candidate
（[Issue 29](issues/29-ntfs-volume-identity-unavailable.md)，resolved），并补齐缺失/无效身份的
展示（[Issue 30](issues/30-explain-unconfirmed-ntfs-identity.md)，resolved）。
[最新证据](evidence/G1-599DFC215DBB4D6CBA982D72F91CBF50.md)为 incomplete、0/100，
不构成 Gate 通过；物理重插、未挂载身份和正式窗口验收仍待验证，没有执行磁盘变更。

| 需求 | 当前实现 | 当前证据 | 剩余工作 | Issue |
|---|---|---|---|---|
| 只读系统观察 | Disk Arbitration、明确网络卷范围排除、独立 IOKit 精确枚举、稳定 mount table、身份/父盘/挂载事实失败关闭；真实 inventory 是唯一 Media Generation 来源 | 完整 Release 行为检查与当前 Mac 只读 smoke；声明失效矩阵及重插、整盘消失、同盘共享代次和 rebuild fixture | 专用外置盘 100 次与声明全生命周期实物对照 | 01（resolved）、02、09（resolved）、17（resolved）、21（resolved）、24（resolved） |
| Gate 1 匿名证据采集 | 独立有界 recorder、capture/verify CLI、共享严格 JSON、canonical bytes/SHA-256 与事件重放；结论类型没有 pass | 100-cycle、代次/拓扑/时间异常、隐私 poison、容量、seal、重复键、摘要与篡改的 Release 行为检查；只读 root 边界负向样例 | 用专用外置盘实际采集并由人工核对 100 轮外部事实；`readyForHumanReview` 不能关闭 Gate | 23（resolved）、02（ready-for-human） |
| unknown 外置 NTFS 可见性 | 其余事实完整时生成独立只读 candidate，显示用途与访问状态；不进入 mutation inventory | 错误事实、现有可写挂载、重插旧选择和零变更资格 fixture | 专用盘实物对照；不自动升级为 data | 16（resolved）、02 |
| 当前连接数据声明 | 固定语义、session/revision、完整实例、精确 sibling、一次性 nonce 与不可公开构造 approval 的纯逻辑契约 | 重插、克隆、重订阅、重启、拓扑变化、protected/conflicting/incomplete 和重放 fixture；零执行 | Gate 1 实物对照与 Gate 4 fresh 系统事实正式接线 | 17（resolved）、02、12 |
| Setup | typed report、有界只读探针、精确版本 allowlist、macFUSE 版本专属 requirement/Team ID/CodeDirectory identity 与 secured plist 核对、可信 NTFS-3G 制品读取、具名候选范围与 installed-footprint 三态探针、具体 UI 原因 | 完整 Release 行为检查；生产 active scope、环境基线与批准策略保持为空 | 具名 Gate 2 镜像环境实证、active scope/依赖批准、真实授权和 adapter | 03、07（resolved）、11（resolved）、15（resolved）、18（resolved）、22（resolved） |
| 写入与推出状态机 | 协调器、整盘租约、一次性意图、物理盘可推出事实、最终预检、reconciliation 与显式 termination 的纯 MountEngine/closure 契约；`MountEngineAdapter` 纯逻辑骨架（命令路由 + 终止映射，无真实 executor） | 完整 Release 纯逻辑行为检查；cancelled/unknown termination 保持同盘不可重入；adapter 路由/终止映射/execution-unavailable 失败关闭/engine 兼容性 | 注入真实 `Executor`（FD 绑定启动边界 + Gate）；真实 helper adapter | 03、08（resolved）、10（resolved）、20（resolved） |
| 当前只读 C 版 UI | 正式只读壳、物理盘分组、多卷物理盘唯一 sibling 序号、跨物理盘同名卷选择标签、按完整选择身份触发的辅助功能事件、Setup 动作、诊断复制/清除结果；新订阅轮换 selection-reset epoch，同 epoch scanning 分离保留/展示选择；失效导航焦点确定回落，wide/compact 只转移既有导航焦点；本地包固定 allowlist 与平台校验 | 固定动作/禁用矩阵、长名多分区排序、反序输入、用户卷名碰撞与隐私、跨盘同名卷标签、相同朗读正文下不同选择事件、跨订阅同实例 ID 旧选择/焦点重置、临时缺项、非选中焦点项和宽窄焦点矩阵、Setup/诊断文字与公告自动检查；严格 Release 构建及五组本地包负向 fixture | 320 pt、深浅色、高对比、真实键盘焦点提交和 VoiceOver 人工证据 | 05（resolved）、13、14（resolved）、19（resolved）、25（resolved）、26（resolved）、27（resolved） |
| Gate 4 正式集成 | 领域展示与协调器纯逻辑已存在，正式 App 尚未接变更能力 | 无 Gate 4 实物证据 | Gate 1–3 后接 observer、协调器、MountEngine 与只消费 `VolumePresentation` 的正式 UI | 12 |
| 诊断 | 白名单、有界内存、私有原子存档、完整性和语义校验 | 本地文件 fixture | 两周使用期间的真实问题覆盖；不得恢复运行状态 | 06 |
| helper | 四动作结构协议与唯一原子准入 | 纯协议行为检查 | XPC、安装、最小权限、FD 绑定执行、签名与公证 | 03、06 |
| 供应链与发布 | 固定包 allowlist、特殊文件拒绝、Mach-O/Info.plist 平台核对、本地正/负向验证脚本、版本与签名同项的静态代码身份策略、记录与回滚流程 | 严格 Release、五组负向 fixture、ad-hoc 签名本地包；不是 Gate 5 候选 | 生产批准版本/签名身份、Developer ID、公证、人工证据和候选使用期 | 06、13、14（resolved）、15（resolved）、22（resolved） |
| Gate 3 数据一致性 | 无真实写入实现，也未接 UI | 无 | 可牺牲盘、Windows、chkdsk、内容哈希和 100 次生命周期 | 04 |

## 当前依赖路径

```text
23 匿名证据工具（resolved） ─────（仅辅助，不替代）─┐
01/09/16/17/21/24 只读观察与声明（resolved） ───────┴─> 02 Gate 1 实物 ─┐
                                                                  v
07/11/15/18/22 Setup 与依赖证据（resolved） ──> 03 Gate 2 镜像与固定依赖
08/10/20 执行契约（resolved） ──────────────────┘
                                                        |
                                                        v
                                              04 Gate 3 数据一致性
                                                        |
05/14/19/25/26/27 UI 与本地包自动证据（resolved） ───┤
                                                        v
                                              12 Gate 4 正式集成
                                                        |
                                                        v
                                              13 UI/发布人工证据
                                                        |
                                                        v
                                              06 Gate 5 候选
```

Issue 23 是 Issue 02 的取证辅助路径，不是新的 Gate 前置条件；软件完成或 artifact 显示
`readyForHumanReview` 都不会改变 Issue 02 的 `ready-for-human` 状态。

`Blocked-by:` 表示即使状态说明了最终执行角色，也不能提前领取。任何
`ready-for-human` Issue 都不能由 Agent 用当前用户数据盘或纯逻辑检查代办。
