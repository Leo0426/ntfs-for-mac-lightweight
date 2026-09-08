---
status: accepted
---

# 把只读卷候选与数据卷声明分开

Apple 公开的 Disk Arbitration 与 IOKit 事实不能可靠区分普通外置 NTFS 数据卷和外置 Windows
系统卷，因此本项目不再把 `external` 自动映射为 `data`。只读系统层可以生成经过身份、父盘、
文件系统、位置和挂载事实核对的 **Read-Only Volume Candidate** 供界面展示，但只有可信角色
证据才能生成 `VolumeSnapshot` 并进入 `VolumeCoordinator`；未来的个人 MVP 若开放写入，只接受
用户针对当前连接显式作出的 **Data Volume Declaration**，并把它作为独立的人类策略输入，而
不是 System Evidence。

## Considered Options

- 把所有外置 NTFS 自动视为数据卷：拒绝，因为外置 Windows 系统盘使用相同文件系统和常见
  分区类型，系统位置不能证明用途。
- 按卷名、BSD 名、分区名称或启动标志推断：拒绝，因为这些值可修改、可复制，也没有 Apple
  一手资料把它们定义为可靠数据角色。
- 持久保存卷 UUID、分区 UUID 或硬件标识 allowlist：拒绝作为授权，因为 UUID 可随克隆复制、
  硬件身份不证明内容用途未改变，且持久记录会跨重插和应用重启错误复用旧判断。
- 永远保留 unknown：安全但无法实现用户明确要求的个人写入流程；保留为用户不接受人为判断
  风险时的最终停止选项。
- 每次连接显式声明：接受，因为它不伪造平台事实，并能绑定当前实例、精确 sibling 拓扑与
  一次性请求；代价是每次连接都需用户确认，且无法消除用户误认的残余风险。

## Consequences

- `ReadOnlyVolumeCandidate` 与 `VolumeSnapshot` 必须是不同类型；候选可以显示，不能进入 mutation
  inventory，也不能使 `writeControlsAvailable` 为真。
- Data Volume Declaration 只存在内存中，绑定完整 `VolumeInstanceID`、`DiskInstanceID`、当前
  精确 sibling 集合和一次性请求；重插、应用重启、睡醒重订阅、覆盖声明、拓扑变化或消费后
  都失效。
- internal、protected、conflicting 或任何不完整系统事实始终覆盖用户声明并失败关闭。
- UI 只能提交固定语义声明和完整目标实例，不能生成 `VolumeSnapshot`、operation ID、命令、
  路径或挂载参数；协调器必须在接受声明后重新读取最新候选与 sibling 集合。
- 用户仍可能误把外置 Windows 系统盘声明为数据盘。Gate 1–3 的 UI、硬件和 Windows 矩阵必须
  明确验证这个警告与停止路径；若该残余风险不可接受，产品不得开放写入。
- 本 ADR 只批准只读候选与纯逻辑声明契约，不批准真实挂载、卸载、推出或任何用户数据盘试验。
- Apple 系统事实边界与未能证明的角色字段见
  [`docs/research/apple-protected-volume-role-evidence.md`](../research/apple-protected-volume-role-evidence.md)。
