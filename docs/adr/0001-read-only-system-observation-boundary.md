---
status: accepted
---

# 在实物 Gate 前保持只读系统观察边界

在 Gate 1 和 Gate 2 实物验证完成前，产品的系统边界只读取 Disk Arbitration、mount table 和运行环境事实，不暴露挂载、卸载或推出等磁盘变更接口。系统证据缺失或彼此矛盾时必须保留明确的不完整原因，且不得构造可进入变更流程的可信卷快照；介质代次属于整块物理盘的一次连接生命周期，在子卷回调和描述变化期间保持不变，只在确认整盘消失后、再次出现时轮换。选择这一边界而不是乐观补默认值、按回调生成身份或提前接入变更操作，是因为错误识别介质和把不完整事实当作安全事实会直接扩大数据损坏风险。

## Considered Options

- 用默认值补齐缺失字段并继续工作：拒绝，因为 unknown 不能证明 external、data、NTFS 或可信挂载来源。
- 每次子卷出现或描述变化都生成新代次：拒绝，因为同盘多个 callback 不代表物理介质被重新插入。
- 在只读观察尚未通过实物验证时同时公开磁盘变更：拒绝，因为观察身份和完整性尚未被证明，无法为最终预检提供可信输入。

## Consequences

- 不完整或矛盾的观察只能用于说明问题，不能授权磁盘变更。
- Disk Arbitration 回调静默只形成 Observation Settlement；没有独立全量覆盖证据时继续标为
  `enumerationCoverageUnverified`，不能把空回调窗口当成 Complete Observation。
- 独立覆盖证据由只读 IOKit `IOMedia` 枚举提供：迭代器必须有效，连续两次 BSD 名称集合
  必须完全相同，并与当前 Disk Arbitration 描述集合逐项相等；失败、变化、不一致和超时
  均保持失败关闭。新的 DA 事件会立即撤销该覆盖并重新开始收敛。
- Disk Arbitration 的 match-all 回调包含网络卷。只有
  `kDADiskDescriptionVolumeNetworkKey` 经严格 CFBoolean 解码后明确为 `true` 的事件才能作为
  范围外网络卷排除；`false`、缺失或类型错误且无 BSD 身份时仍记录
  `unidentifiedDiskEvent`。若错误标记隐藏了 IOMedia 身份，独立枚举集合不一致会继续失败关闭。
- mount table 读取必须同时通过单次 `getfsstat` 计数/复制一致性和连续两次完整快照相等；
  同数量替换和截断不能被视为稳定事实。
- 缺失或格式非法的 BSD 名、卷 UUID、父盘身份和零介质代次都必须保留固定问题码，不能
  生成可信 `VolumeSnapshot`。
- 标准整盘推出还要求绑定当前 Disk Instance 的完整 `Ejectable`/`Removable` 事实；已知
  不可推出使用固定阻塞原因，未知、矛盾或最终预检时被撤销则失败关闭。
- 正式只读应用的 package 依赖图不得到达变更准备或 helper 协议 target；固定只读 Setup 命令的进程运行器隔离在非产品只读探针 target，不能成为通用命令入口。
- 只读实现和当前机器 smoke test 不等于 Gate 1 通过；仍需外置盘、多分区、反复插拔和睡眠唤醒验证。
- 后续磁盘变更适配层必须作为独立边界接入，并继续由协调器的一次性意图和最终预检约束；本 ADR 不授权在真实用户磁盘上测试。
