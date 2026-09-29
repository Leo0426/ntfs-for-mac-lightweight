---
status: accepted
---

# 由 helper 原子执行“启用写入”，App 以轻量写入会话接线

ADR 0010 接入写入能力时发现：Core `VolumeCoordinator` 的启用写入是多步流程（App 请求卸载 →
App 读取含健康状态的安全快照 → App 请求可写挂载）。健康检查需要以 root 读取原始设备，App 进程
无法取得，该流程无法在正式应用中推进。helper 的 `mountReadWrite` 已在 root 下原子完成身份核对、
启动扇区绑定、原生卸载、no-recovery 健康检查、驱动启动与 FSKit 挂载核验，并已在可牺牲 U 盘上
验证（2026-09-29，issue 03/04）。

决定：正式应用通过 `NTFSLiteWriteSession` 轻量写入会话接线——每块物理盘同一时刻一个操作、用户
显式确认后才发起、每次请求新的一次性 operation ID、只发送 ADR 0002 固定动作、超时/断线/无效响应
视为状态未知且不重发、结束后重新观察系统。“安全推出”依次请求 `unmountDisk` 与 `ejectDisk`。
Core `VolumeCoordinator` 的多步写入工作流暂不接入正式应用。

## Considered Options

- 为 helper 增加“健康检查”动作以满足 Core 多步流程：拒绝。ADR 0002 只允许四种固定变更动作，
  且拆分会在卸载与挂载之间留下由 App 协调的窗口。
- 让 App 以 root 读取设备：拒绝，违背最小权限与 helper 边界。
- 轻量写入会话 + helper 原子执行：采用。安全核对集中在 root helper，一次请求内完成且可验证。

## Consequences

- App 不能在请求之间“缓存”资格；helper 每次重新读取全部系统事实，App 侧的判断只决定按钮是否可用。
- 可写状态在 App 内按本次会话记录。helper 在底层可以按驱动持有关系识别并释放可写 FSKit 挂载；
  界面不能直接把占位来源映射回卷，需要后续改进。
- 2026-09-29 GPT EFI 同盘修复：helper 请求协议 v2 绑定整盘 IOMedia Registry Entry ID 与精确
  GPT 分区集合（BSD 名、分区 Registry Entry ID、MediaUUID、Content Hint）；helper 在首次卸载
  前独立枚举并核对，整盘推出前再次核对；同一 helper 进程内的所有 XPC 连接共用整盘执行租约。
  响应仍沿用结构未变化的 v1 信封，新增忙碌结果码供 App 显示并发拒绝。
  正式 App 当前仅向 GPT Microsoft Basic Data NTFS
  目标与可选的未挂载 EFI 分区开放这一路径，NTFS 用途仍需用户本次声明。系统字段依据见
  [研究记录](../research/gpt-efi-sibling-identification.md)。此路径尚未完成可牺牲盘上的快速拔插、
  真正整盘推出与 Windows 复核，不能据模拟测试认定消费级安全性已验证。
- 固定的 `ntfs-3g` 仍将 BSD 设备路径作为启动参数并自行打开。即使 helper 在启动前后多次
  核对 IOMedia 身份，也无法原子地绑定驱动最终打开的设备对象；快速拔插且 BSD 名复用的
  竞态尚未严格消除。关闭该缺口需要固定驱动支持并验证已打开设备句柄的传递，且重新评估
  驱动签名、进程归属和挂载后核对。相关未验证项不得用用户数据盘试验。
- helper 只从 `/Library/PrivilegedHelperTools/NTFSLite.app` 的受保护、root 所有树启动，
  并在每次变更前核对路径组件、权限与固定签名；`.build` 包只用于界面和构建检查。
  服务名、plist 与 helper 签名标识升级为 `com.leolu.ntfslite.helper.v2`，使新版 App 无法
  连接仍可能驻留的旧版 helper。旧服务的注销和受保护安装尚未完成。
- helper 在卸载原生只读卷前要求当前挂载用户通过 FSClient 观察到目标 FSKit 模块已启用；
  未取得正信号时保持原生挂载。Apple 未保证跨 Team 模块对调用方可见，本机已签名的只读
  探针没有观察到曾成功挂载一次性镜像的 macFUSE 模块，因此这项保守检查可能拒绝可用环境。
  App 不以 PlugInKit 缺少显式 `use` 标记隐藏写入入口，也不把它说成“扩展未启用”；
  受保护部署后的 helper 可见性与兼容性仍需验证，见
  [FSKit 运行时检查](../research/fskit-runtime-preflight.md)。
- 写入成功后即使 FSKit 占位使原 NTFS 行消失，本次会话仍可凭整盘 Registry Entry ID 保留
  安全推出入口，由 helper 再核对精确分区集合。应用重启后会话记录仍会消失，当前没有经验证的
  自动恢复入口；此前“重启后仍可通过安全推出”的预期尚未兑现。
- Core 多步工作流与其行为检查保留，未来若 helper 协议演进可重新评估。
