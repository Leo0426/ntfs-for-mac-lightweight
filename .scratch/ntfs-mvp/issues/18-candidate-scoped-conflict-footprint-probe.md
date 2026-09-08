# 定义 Gate 2 候选范围并检测已安装冲突 footprint

Status: resolved
Labels: enhancement, resolved
Assignee:
Blocked-by: 15-macfuse-signing-evidence-policy

## 问题

当前 Setup 只核对已登记 system extension 与已加载 kext，并把冲突目录完整性建模成没有范围的
全局布尔值。商业 NTFS 驱动可能已经安装但尚未加载；同时，“穷举全部商业驱动”不是可关闭的
Gate。需要把检查绑定到一个具名、有限、可过期的 Gate 2 候选范围，并只读检查固定安装 footprint。

## 验收

- typed `ConflictCatalogScope` 携带固定 scope ID、目标 macOS/架构、证据日期、候选制品摘要、
  精确 loaded identifier 集合和固定 installed footprint；版本、摘要或平台变化使 scope 不匹配。
- 当前已知 kext 集合包含且只包含本候选范围的 Paragon、Tuxera、iBoysoft 精确 identifier；
  不把 service label、filesystem bundle ID、package ID 或 Team ID 混入 loaded identifier。
- installed footprint provider 不使用 `Process`，只读核对固定绝对路径；逐层拒绝符号链接，区分
  `absent`、`presentConflict`、`incomplete`，并对竞态、权限、类型或元数据异常失败关闭。
- 已知路径存在任何内容都不能降级为 absent；精确 bundle ID/签名事实只用于细化证据，错误值仍
  必须阻止或 incomplete。
- Setup 完整性只能由 active scope 已配置、目标环境匹配、loaded scan 完整、footprint scan 完整
  且环境基线满足共同产生；不能把永久常量或三个 ID 未命中解释为“系统没有其他 NTFS 驱动”。
- `SetupProbePolicy.current` 继续保持生产 scope 未批准和失败关闭；允许提前发现已知冲突，但不得
  因本 Issue 把 `conflictCatalogComplete` 直接改为 `true`。
- fixture 覆盖 absent、命中、错误 ID、Tuxera 旧 footprint、符号链接、不可读/非目录、竞态、
  scope/platform/摘要不匹配、loaded 输出截断/未知记录，以及三家精确 ID 命中。
- 不安装、加载、卸载或执行任何第三方驱动，也不执行真实磁盘变更。

## 评论

证据与候选范围见
[`docs/research/setup-conflict-catalog.md`](../../../docs/research/setup-conflict-catalog.md)。
完成本 Issue 只关闭候选目录的软件缺口，不代表 Gate 2 已通过；镜像生命周期、固定依赖批准、
授权和真实 adapter 仍由 Issue 03 验收。

## Resolution (2026-08-31)

- 已用 typed `ConflictCatalogScope`、目标平台、证据日期、候选制品版本与 SHA-256、精确
  loaded identifier 和固定 installed footprint 取代无范围的全局完整性常量。
- 当前候选范围包含且只包含三家已核验 kext identifier；system extension 集合保持为空，
  filesystem bundle identifier 只保存在 footprint 元数据中，不会混入 loaded identifier。
- 已接入无 `Process` 的只读 footprint provider：从根目录开始逐层使用 `openat`、
  `O_NOFOLLOW` 与描述符身份复核；仅明确不存在返回 `absent`，任何终端内容返回
  `presentConflict`，符号链接、权限、类型、可观察竞态或元数据异常返回 `incomplete`。
- Setup 完整性现在由 candidate/active scope 完全一致、运行目标一致、环境基线已满足、
  loaded scan 完整和 footprint scan 完整共同产生。`SetupProbePolicy.current` 的
  `activeScope` 仍为 `nil`，环境基线仍为未满足，因此生产状态继续失败关闭。
- 探针向 Setup facts 只传递稳定的 opaque conflict code 和计数；固定路径、厂商名与原始
  identifier 不进入 UI 或诊断投影。
- 公共行为 fixture 覆盖三家 loaded 命中、旧版 footprint、absent/present/incomplete、错误
  bundle ID、终端异常类型、符号链接、权限/元数据/竞态注入、scope ID、版本、摘要、macOS、
  架构与环境基线不匹配，以及 loaded 输出截断和未知记录。

本 Issue 的无硬件软件切片已关闭。Gate 2 仍未通过：active scope 批准、具名镜像环境基线、
固定依赖、授权和真实 adapter 证据仍属于 Issue 03 的外部门槛。
