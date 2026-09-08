---
status: accepted
---

# 把 Setup 冲突完整性绑定到具名候选范围

“已经穷举全部商业 NTFS 驱动”不是可以稳定证明或长期维持的命题；只检查几个已加载 identifier
也不能发现已经安装但尚未加载的驱动。本项目把冲突完整性收敛为一个具名的
**Conflict Catalog Scope**：它固定目标 macOS/架构、证据日期、候选制品版本与摘要、loaded
identifier、installed footprint 和环境基线。Setup 只能声称“当前事实满足这个范围”，不能声称
系统全局不存在其他 NTFS 驱动。

## Considered Options

- 穷举全市场并用永久布尔值表示完整：拒绝，因为产品、版本、标识与安装形状会变化，无法定义
  可关闭边界。
- 只扫描 `systemextensionsctl` 与 `kmutil showloaded` 的已知 identifier：拒绝作为完整证明，因为
  已安装但未加载的冲突会被漏掉。
- 枚举整个系统并猜测名称中包含 NTFS 的组件：拒绝，因为名称启发式会产生漏报和误报，也会把
  未经批准的路径或厂商文字带入模型。
- 对具名制品范围固定 loaded identity、installed footprint 与环境基线：接受，因为范围、证据与
  过期条件都可以明确记录和重复验证；范围不匹配时能够失败关闭。

## Consequences

- scope 必须携带稳定 ID、目标平台、证据日期、候选制品摘要和三类 extension 结论；任一版本、
  摘要、路径、平台或 extension 类型变化都会使旧 scope 过期。
- installed footprint 只读探针逐层拒绝符号链接，并区分 `absent`、`presentConflict` 与
  `incomplete`。已知路径存在任何内容都不能降级为 absent；读取、权限、类型或竞态不确定时
  失败关闭。
- Setup Ready 需要 active scope 已由 Gate 2 批准、目标环境匹配、loaded scan 完整、footprint
  scan 完整且环境基线满足。永久常量或 allowlist 未命中不能单独产生完整结果。
- 范围外 NTFS 工具、不明安装 footprint 或用户环境与基线不符都产生 `scopeMismatch`/incomplete，
  不能显示成“未安装任何其他 NTFS 驱动”。
- UI 和诊断只显示固定状态与数量，不投影厂商名、安装路径或原始命令输出。
- 2026-08-31 对 Paragon、Tuxera、iBoysoft 当前官方制品的目录只是 Gate 2 候选证据，不是生产
  批准，也不改变 Gate 状态。具体范围与摘要见
  [`docs/research/setup-conflict-catalog.md`](../research/setup-conflict-catalog.md)。
- 本 ADR 只批准只读范围模型与检测边界，不授权安装、加载、卸载第三方驱动或任何磁盘变更。
