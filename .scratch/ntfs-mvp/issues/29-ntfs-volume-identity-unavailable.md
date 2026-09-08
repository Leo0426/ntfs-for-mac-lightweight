# 实物 NTFS 未返回卷 UUID 的兼容性调查

Status: resolved
Labels: bug, resolved
Assignee: Codex
Blocked-by:

## 实物事实

2026-09-08，用户明确授权可牺牲的 USB-1：32.2 GB 外置 USB、GPT 两分区，其中一个 NTFS
分区约 32.0 GB。macOS 26.6.2 (25G83)、arm64。本次不读取盘内文件，不执行磁盘变更。

`diskutil info -plist` 未提供 VolumeUUID；直接读取 Disk Arbitration 描述也得到
`kDADiskDescriptionVolumeUUIDKey=nil`。两者的分区/介质 UUID 存在。挂载表报告 ntfs、read-only
和 fskit。重复 diskutil 卷事实相同，不能因此推断文件系统健康或 UUID 缺失的具体原因。

生产 recorder 最终独立枚举 coverage=verified，但 NTFS 记录有 missingVolumeUUID 和
unknownVolumeRole，没有 candidate，coordinatorInventory 不可用。当前仪表盘因没有可选候选
而按逻辑显示一般的信息未确认状态；本轮 UI 自动化连接失败，没有取得窗口截图/人工证据。
匿名完整记录见 [Evidence](../evidence/G1-5354DF11B2C047289A1862B41EAC2300.md)。

## 待明确

- 以一手平台文档与额外只读实物对照确认：这是介质自身、系统返回契约还是具体环境差异；
  不能将单次本机证据推广为所有 macOS 或 NTFS 的结论。
- 若采用替代身份，先定义其作用域、碰撞/克隆、重插和 sibling 关系，再评估 CONTEXT / ADR
  与 VolumeID、候选、声明和 Gate artifact 的兼容性。不得直接拿 MediaUUID / DiskUUID 填入
  volumeUUID，也不得读不到 UUID 就用卷名、BSD 名或随机值构造可信候选。
- 可独立改善缺失身份时的只读诊断展示；该展示不能具有选择/声明/变更资格。

## 验收边界

任何未来适配先补公共接口失败检查，再验证当前实物、重插/克隆/多分区的身份语义。身份仍未知
时保留失败关闭。格式化不是本 Issue 的默认修复步骤；本次证据不能关闭 Gate 1。

## 评论

2026-09-08 后续公开接口对照：Foundation volumeUUIDString 与 FD 绑定的 ATTR_VOL_UUID
取得相同有效 UUID，且与分区 UUID 不同。Issue 已从 needs-info 经 triage 转为 ready-for-agent。
调查结论见 [研究记录](../../../docs/research/ntfs-volume-identity.md)，采用范围见 ADR 0008。
已挂载候选身份适配与缺失身份的展示（Issue 30）正在走公共接口 TDD；不把该读取扩展到未挂载
身份或写入资格，Gate 1 的完整实物生命周期证据仍由 Issue 02 承接。

## Resolution

2026-09-08：已实现 ADR 0008 限定的已挂载 NTFS 只读身份补充。原生读取检查固定返回长度/掩码、
全零 UUID、同一 FD 两次属性一致性、前后及重开路径的 fsid/源设备/挂载点/文件系统/标志。
稳定 mount snapshot 同时比较身份与完整性；读取失败保持不完整，DA 与原生 UUID 冲突拒绝。
只有 DA UUID 缺失的外置 unknown-role NTFS 候选可以补充身份；原始 DA evidence 不变，
补充值不生成 mutation snapshot、不跨卸载或订阅缓存。

207 项行为检查和完整交付检查通过；真实 USB-1 形成一个只读、用途未确认的候选，零变更资格。
见 [新证据](../evidence/G1-599DFC215DBB4D6CBA982D72F91CBF50.md)。本 Issue 关闭的是已挂载只读
兼容性调查与适配；物理重插矩阵仍在 Issue 02，未挂载身份仍是 Gate 2/4 接线前的待验证条件。
