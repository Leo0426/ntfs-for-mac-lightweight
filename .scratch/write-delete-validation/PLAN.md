# NTFS 写入、删除与持久化验证闭环

Status: in-progress / image-passed-usb-awaiting-v2-run（最新状态见末节）
Date: 2026-09-09
Assignee: Codex

## 目标与现状

最新结论：用户已重启，两个扩展最终已恢复 PlugInKit 可见性；一次性 NTFS 镜像的写删、
标准卸载、重挂载独立读回和清理均已通过。USB 当前身份只读核对通过，但原始设备访问需要
用户在终端完成管理员认证。临时 FSClient 工具的空结果不能证明全局缺失。
以下阶段记录保留历史顺序，当前状态以末尾复测及 [诊断记录](FSKIT-DIAGNOSIS.md) 为准。

用户要求在已授权的可牺牲 U 盘上验证真实写入、删除等操作，形成操作闭环。该授权已存在，
无需再次确认是否允许删除测试盘数据。

2026-09-08 的只读观察发现一块已授权可牺牲 USB 外置介质，32,212,254,720 字节；
NTFS 分区为 32,000,438,272 字节。当时不可写。这个历史观察不能代替执行前重新核对。
正式应用仍保持只读，生产依赖批准目录为空；实验边界见 ADR 0009。

## 用户已确认的开发顺序

- 2026-09-09 用户接受安装 macFUSE 5.4.0 候选用于隔离实验。
- Windows 复核由用户在功能完成后手动进行，**不再是 macOS 开发与实验的前置阻塞**。
- 原有可牺牲 U 盘授权继续有效。本次不对其他磁盘开放操作，也不自动放开正式 App。

## 候选依赖与实验状态

- macFUSE 5.4.0 官方 DMG 的摘要与固定值匹配，镜像校验通过；安装包受信任、已公证，
  签名 Team ID 为 `3T5GSNBU6W`。通过系统管理员认证正常安装，receipt 确认为 5.4.0。
  系统设置中的两个 macFUSE 文件系统扩展已开启；没有加载内核后端或降低系统安全性。
- NTFS-3G 官方 tag `2026.7.7`、commit `d327833ec1d5eb1358b6f2c37139f10a3460944d`
  的 `git archive` 已本地构建。版本输出为 external FUSE 29；没有全局安装 NTFS 工具。
  原始 tarball 返回 HTTP 403，不能宣称已验证 tarball。参数和产物摘要见
  [依赖回执](dependency-receipt.json)。
- 上游 NTFS-3G 默认增加 `allow_other,nonempty`；固定调用已补充 `no_def_opts` 禁用默认值。
  实验使用 `rw,no_def_opts,backend=fskit,norecover,no_detach`。`no_detach` 用于前台观察；
  上游不接受 `-f` 前台参数，错误尝试已退出，未形成挂载。
- 已创建、格式化一个全新的 128 MiB 常规文件镜像，未对物理 USB 格式化、挂载或写入。
  镜像首次挂载进程输出“Mounted”，但实际挂载表没有目标，挂载点也不存在，因此拒绝写入。
  进程采样定位到 MFMount 的 `CFUserNotificationDisplayAlert` 等待系统提示。
- 自动 UI 工具拒绝访问 `UserNotificationCenter`，理由是安全限制；已请求用户手动处理提示。
  对等待进程发送普通 SIGTERM 尚未得到退出确认，因而没有宣布静止或清理其镜像。
  随后的挂载尝试因原镜像锁仍在占用而退出 18，没有绕过锁或强制终止。
- 文件语义库及 9 项自动化测试通过系统临时目录验证；**NTFS 镜像、本机重挂载和 USB 实物
  写删尚未通过**。当前需先处理系统提示并重新检查进程/挂载状态，不能把日志当作挂载成功。

## 最小闭环

1. 固定候选依赖的下载摘要、内部代码签名身份、NTFS-3G 构建参数和产物摘要；保持正式 App
   的生产批准目录为空。先验证一次性镜像，再验证可牺牲 U 盘。
2. 接通隔离执行边界：只支持固定 FSKit/no-recovery 路线、标准卸载和最终事实复核；保持完整
   实例、一次性请求、整盘租约和超时后的静止确认。另行解决卸载后文件系统 UUID 来源，
   不能复用已挂载候选的缓存身份来通过 fresh 预检。
3. 核对当前外置 NTFS 身份、健康、同盘卷、挂载来源和实际可写状态。任何缺失或矛盾均停止。
4. 在本次专用测试目录完成下表操作。目录名由随机 Run ID 生成，独占创建，拒绝既有路径、
   符号链接和越界路径；只操作此运行创建的文件。
5. 标准卸载并重新挂载后，重新读取全部保留文件和已删除文件状态，核对内容和目录清单。
6. Windows 阶段后置：用户之后运行独立一轮并核对清单、SHA-256 与文件系统检查。本机
   阶段不等待 Windows，状态始终保留 `windowsVerified: false`。
7. 验证通过后仅清理本次创建的条目，再核对清理结果；标准推出后只有新系统事实确认整盘
   消失，才报告可以拔出。异常时保留证据并报告实际残留，不递归删除未知内容。

## 数据语义矩阵

| 操作 | 数据 | 必须独立检查的结果 |
| --- | --- | --- |
| 创建 | 空文件、1–16 字节、4 KiB、1 MiB、Unicode/空格文件名 | 重新打开后的长度、逐字节内容或 SHA-256 |
| 覆盖 | 长内容改短、短内容改长 | 精确新长度与哈希，没有旧尾部 |
| 追加 | 多次小块追加、跨块边界 | 顺序和最终完整哈希 |
| 重命名 | 文件与目录；单独记录已有目标的替换语义 | 旧名消失、新名内容一致、目录项符合预期 |
| 删除 | 文件、空目录；非空目录拒绝场景 | 删除项确实不存在；权限/读取错误不能当作不存在 |
| 大文件 | 4 GiB + 1 字节，分块生成且事先核对剩余空间 | 精确长度、流式哈希、跨 4 GiB 边界内容 |
| 持久化 | 保留一组文件和一组已删除条目 | 重挂载和 Windows 两端的清单、长度、哈希及缺席状态一致 |
| 清理 | 仅本次生成的清单内条目 | 测试目录确实移除，范围外条目未被操作 |

macFUSE 的小块写入回归使 1–14 字节用例必须逐个运行，不能只测一次大块复制。
磁盘满、并发、睡醒、异常断连、稀疏/压缩文件及 100 轮生命周期仍按 Gate 3 完整矩阵独立
记录；一次最小闭环通过不能替代它们。

## 结果定义

- `blocked`：驱动、执行器、目标身份或系统执行条件未满足，未执行实物闭环。
- `failed`：实际操作、读回、清理或文件系统检查出现不一致，保留失败阶段和证据。
- `fileChecksPassed`：仅文件语义库检查完成，不证明文件系统类型或发生过重挂载。
- `localChecksPassed`：仅本机读回/重挂载检查完成，尚不能证明 Windows 一致性。
- `roundTripVerified`：同一批测试数据在本机重挂载和 Windows 复核均符合预期。

这些结果只描述这一轮测试，不自动改变仓库 Gate 状态或正式应用能力。

## 开发检查

2026-09-09：新增行为按红、绿循环实现；回归验证覆盖 FIFO 阻塞和读回期间同名文件替换。
`scripts/check.sh` 严格 Release、CoreChecks、CLI、只读边界、本地签名包和负向 fixture 通过。
依赖安装镜像已正常卸载；待确认的实验进程和其新建测试镜像保留，未强制终止或绕过锁。

## 用户处理提示后的复测（2026-09-09）

- 用户告知已手动处理原提示；原等待进程已确认退出，日志最终为扩展未启用及挂载失败。
- 使用同一 128 MiB 镜像重新尝试，系统进入扩展启动阶段，但 mount 返回 69；
  `fskitd` / `fskit_agent` 报 ExtensionKit Code 2、Cocoa 4099。
  `extensionkitservice` 报 `_EXExtensionIdentity` 初始化失败 Code 5，XPC 解码得到 nil。
  实际挂载表无实验卷，不能进入文件写入。
- LaunchServices 中两个扩展均指向正式 `/Library/Filesystems/macfuse.fs` 安装位置；
  正式 app 的 deep/strict 签名验证通过，系统版本为 macOS 26.6.2（25G83）。
- 对本次请求使用的当前用户 ExtensionKit 服务正常发送 SIGTERM，确认旧服务退出。
  用独立新建的第二个 128 MiB 镜像复测，新服务仍出现相同 Code 5 / XPC 解码失败。
  因此不能声称单独重启此服务修复了问题。
- 随后向当前用户 `fskit_agent` 发送普通 SIGTERM；尚未确认其退出，不把请求当成重启成功。
  官方 `macfuse install --components file-system-extensions` 返回 0；尚无随后成功挂载证据。
- 两个实验挂载均采样确认等待 `CFUserNotificationDisplayAlert`。已发出普通终止请求，
  尚未确认进程静止；没有强制终止、绕过镜像锁或继续叠加挂载尝试。用户已被请求手动关闭
  新提示并提供完整文字。UI 工具此前因安全限制拒绝访问系统提示中心，不尝试绕过限制。
- USB 仍为原生 NTFS 只读挂载，本次未写入、卸载或格式化物理盘。实验镜像保留。

当前推测是扩展身份/注册状态问题，尚未证实根因。macFUSE 官方曾记录重新注册扩展后的
FSKit/PluginKit 状态问题，但该历史说明不能证明本机的具体原因：
[官方 5.2.0 发布说明](https://macfuse.github.io/2026/04/09/macfuse-5.2.0.html)。
下一步先关闭待处理错误提示，确认进程退出，再判断是否需要用户重新登录或重启系统。

## 继续开发与状态复核（2026-09-09）

- 本次重新读取进程表，已无遗留 `ntfs-3g` 进程；两个等待提示的实验日志均已以挂载失败和
  卸载日志结束。实际挂载表无实验镜像，USB 仍是原生 NTFS 只读挂载。原先的“进程静止未确认”
  阻塞已解除，但这不能证明 FSKit 扩展启动问题已修复。
- 尚未收到用户是否重新登录或重启的反馈；本次未重复发起已连续失败的挂载，也未进行 USB
  写入、卸载或格式化。下一次实物尝试仍须重新核对当前目标、依赖及挂载事实。
- 新增清单持久化与独立只读复验命令：规范 JSON + SHA-256、16 KiB 上限、独占创建和同步、
  父目录/文件描述符核对、链接/特殊文件/非法字段/重复键/摘要与字节不一致拒绝；失败保留现场。
  CLI 对清单加载和文件读回分别报告失败阶段，成功保持 `fileChecksPassed`，重挂载及 Windows
  标志均为 false。接口及限制见 [工具说明](../../scripts/write-validation/README.md)。
- 修复复验在读回期间新增未知条目时可能错误通过的问题，结束前重新核对完整目录清单。
  新增行为已完成红、绿循环；当前 16 项自动化检查只使用系统临时目录，不能作为 NTFS 证据。
- 交付验证：`scripts/check.sh` 退出 0，严格 Release、CoreChecks、Gate CLI、16 项实验测试、
  只读 package/source 边界、本地 ad-hoc 签名包与五组负向 fixture 全部通过；`git diff --check`
  通过。正式应用能力、生产依赖批准目录和 Gate 状态均未改变。

## FSKit 注册诊断增量（2026-09-09）

- 新只读 API 证据确认：系统查询成功，但两个 macFUSE 模块均缺失。PlugInKit 定向日志拒绝
  “没有所属应用且非 SIP 保护”的插件；正式应用、扩展和库签名均有效。
- 候选自带重新注册及原位置所属应用注册均退出 0，但没有恢复 FSKit 可见性。Mac 自安装
  以来尚未重启，安装前启动的 `fskit_agent` 仍存活。下一步由用户保存工作后正常重启，再用
  已固化的只读命令比较注册状态；重启恢复是待验证假设。
- 新增独立 `InspectFSKit` 命令及注册判断测试；未知/超时、缺失、未启用、重复和路径不符均
  失败关闭。`registeredAndEnabled` 只描述注册状态，始终不授予挂载或写入资格。
- 本次没有镜像挂载或 USB 变更；具体观测、尝试、一手来源和恢复步骤见
  [FSKit 诊断记录](FSKIT-DIAGNOSIS.md)。
- 交付验证：`scripts/check.sh` 严格 Release、22 项隔离实验测试及全部既有检查通过；
  本机只读诊断如实退出 1，报告 `standard/local=missing`。正式 App 和 Gate 状态保持原状。

## 用户重启后的复测与诊断修正（2026-09-09）

- 启动时间已更新到 2026-09-09 16:41:14 +08:00；原“等待重启”步骤已完成，但故障未恢复。
  PlugInKit 在新启动会话仍以所属应用关联不被认可为由拒绝两个正式扩展。
- 系统设置按“类别”显示两个扩展开启；分别关闭再开启、正常启动已公证的原应用并局部注册，
  均未恢复 PlugInKit 可见性。用户 Applications 下的签名副本比较也未恢复，已注销并完整移除。
- 本机 FSClient 查询日志报告调用方无 Team ID。修正诊断契约：`notObserved` 只表示当前进程
  未观察到，增加 `observationScope=currentProcess`；肯定结果改为 `observedAndEnabled`。
  旧 `missing` 输出不能作为系统全局缺失的证据，也不作为真实挂载必须通过的单独门槛。
- 上游 #1192 存在同系统版本的相关症状，但其 PlugInKit 可见且只影响 local 模块，与本机不同；
  #1194 推荐的按类别启用路径本机已验证。全用户 LaunchServices 重建没有得到可靠修复支持。
- 本次未执行镜像挂载或 USB 变更；NTFS 文件语义、本机重挂载与 Windows 复核仍未通过。
  后续查询已发现注册恢复，并实际完成镜像闭环，见下一节；原拟上游报告未发布。

## 镜像闭环通过与 USB 执行入口（2026-09-09）

- 最终 PlugInKit 查询已列出两个原位置模块及正确的 Parent Bundle；同时，ad-hoc FSClient
  查询仍为空。修正可见范围后恢复镜像实验。不能确定重启、注册或其他操作中哪一步起作用。
- 第二个 128 MiB 一次性 NTFS 镜像：34 项文件语义检查通过，包括 1–16 字节、Unicode、
  覆盖、追加、重命名/替换、删除和 1 MiB 文件；标准卸载后重新挂载，独立进程核对
  22 个保留文件与 6 个删除项。随后清理测试目录并标准卸载，实际挂载表确认无残留。
  [镜像结果](IMAGE-RESULT.md) 是本机镜像证据；不表示 USB 或 Windows 已通过。
- 新增固定目标的 `usb_lab.py`：私有目标回执摘要固定在代码中；只读预检在当前 U310 上通过。
  不接受任意设备、挂载参数或恢复/格式化命令。实际 `--run` 在管理员权限检查前未做磁盘变更，
  并如实报告 `administratorAuthenticationRequired`。不缓存、收集或回显管理员口令。
- USB 执行顺序：fresh 身份/同盘卷核对 → 标准卸载原只读卷 → 原始 NTFS 启动扇区绑定及
  no-recovery 健康检查 → FSKit 可写挂载 → 小目录写删/清理 → 4 GiB + 1 字节数据集 →
  标准卸载/重挂载/独立读回 → 标准卸载。保留数据供 Windows 后续核对；不宣布整盘已推出。
  原始启动扇区在初次卸载之前读取并绑定，每次操作再次核对；分区 UUID 不冒充 VolumeUUID。
- 未知或矛盾事实均停止；变更命令超时继续等待实际退出并持有本实验租约，失败保留状态与证据。
  此入口仍是 ADR 0009 的隔离实验，并非正式 helper、通用磁盘执行器或 Gate 资格。
- USB 原始设备读取返回 Permission denied，非交互 sudo 要求密码。已完成可代办的目标核对、
  代码及只读验证；下一步由用户在自己的终端运行 [工具说明](../../scripts/write-validation/README.md)
  中的固定命令完成管理员认证。USB 写入、4 GiB 实物检查和 Windows 复核尚未执行。
- 最终交付验证：`scripts/check.sh` 退出 0，35 项隔离实验测试、严格 Release、CoreChecks、
  Gate CLI、只读边界、本地签名包及 5 组负向 fixture 全部通过；`git diff --check` 通过。
  最新只读预检仍为 `targetMatched/currentlyWritable=false`，USB 仍是原生只读挂载，
  无实验镜像挂载或 `ntfs-3g` 残留进程。管理员路径仍未执行。


## 管理员入口的块设备判断修复（2026-09-10）

- 用户实际运行 sudo 入口，报告 `blocked/notCharacterDevice`，且 `diskMutationsPerformed=false`。
  失败发生在初始化读取启动扇区之前，未进入卸载、挂载或文件操作。
- 本机只读核对确认：diskutil 给出的 `/dev/disk…` 为块设备，对应 `/dev/rdisk…` 为字符设备；
  两者本机 `st_rdev` 相同。当前目标仍为 U310 及原 NTFS 分区，只读挂载未改变。
  根因是实验脚本错误地对前者使用了 `S_ISCHR`，不是设备权限或 NTFS 健康检查失败。
- 通过真实 `USBLab.read_boot` 调用路径的受控系统调用输入，先复现同一 `notCharacterDevice`，
  再修正为严格块设备检查。保留 diskutil 路径和只读/no-follow 打开，不扩大为接受任意类型。
  打开前、打开的描述符及读后路径必须具有相同设备号、inode 和类型，否则丢弃读回结果。
- `--inspect` 复用类型检查并输出 `deviceNodeType=block`，本机已通过。新增 7 项回归检查覆盖
  正常块设备、字符设备/链接/普通文件/FIFO 拒绝、打开和读回期间替换、非法 NTFS 扇区，以及
  只读预检不打开设备的边界。自动化系统调用为受控输入，不冒充管理员实际设备读取。
- 当前工具会话的非交互 sudo 仍要求密码，未绕过认证或修改设备权限；需要用户在原终端
  重新运行同一固定目标命令。USB 实物写删、重挂载和 Windows 复核仍未通过。
- 交付验证：`scripts/check.sh` 退出 0，42 项隔离实验测试、严格 Release、CoreChecks、Gate CLI、
  只读边界、本地签名包及 5 组负向 fixture 全部通过；`git diff --check` 通过。当前挂载表仍为
  USB 原生只读挂载，无 `ntfs-3g` 进程或实验挂载残留。

## 管理员设备读取的错误定位（2026-09-10）

- 用户第二次运行报告 `blocked/OSError` 和 `diskMutationsPerformed=false`。当前没有
  `usb-run-…` 证据目录，USB 仍为原生只读挂载；原错误输出丢失 errno，不能确定失败调用。
- 新增 `--probe-device`，复用实际启动扇区读取路径但不初始化实验、不创建租约或证据目录，
  不进入卸载/挂载/文件操作。连续读回必须一致，前后目标与挂载表必须一致。
- 读取路径分别记录节点检查、打开、描述符检查、扇区读取、读后检查及关闭阶段；启动入口
  区分目标、依赖、管理员检查、租约及初始化阶段。系统调用错误附 `errno` / `errnoName`，
  不泄露原始路径或异常正文。已请求用户运行只读诊断，真实错误码尚待采集。
- 待验证假设：原生只读卷已挂载，块设备打开可能返回 `EBUSY`。
  [Apple vfs_mountedon 文档](https://developer.apple.com/documentation/kernel/1523197-vfs_mountedon)
  说明已挂载设备的忙状态；[Apple XNU spec_open 实现](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/miscfs/specfs/spec_vnops.c)
  在块设备打开路径调用该检查。查阅日期为 2026-09-10；上游 main 源码不等于本机内核构建，
  不能凭此替代本机 errno，也尚未据此更换设备读取方式。
- 5 项新增回归检查覆盖打开/读取错误的阶段与 errno、初始化及租约失败不进入变更，以及
  只读诊断不初始化实验或取得租约。`scripts/check.sh` 退出 0：47 项隔离实验测试、严格
  Release 及全部既有检查通过；`git diff --check` 通过。USB 与 Windows 结果仍未通过。

## 已挂载块设备 EBUSY 的修复（2026-09-10）

- 用户执行只读诊断后得到 `operation=bootDeviceOpen`、`errno=16`、`errnoName=EBUSY`，
  `diskMutationsPerformed=false`。这确认了上一节的已挂载块设备打开假设；尚未读到启动扇区，
  也没有进入卸载、健康检查或写入阶段。
- 再次核对固定 U310 身份、原生只读挂载和 512 字节逻辑扇区；系统两条节点分别为块设备和
  原始字符设备，同一 `st_rdev` 与设备文件系统，各自具有不同 inode。
- 系统调用边界测试复现真实读取路径的 `bootDeviceOpen/EBUSY`，再修改为从严格派生并配对
  的原始字符设备读取。块设备继续作为 diskutil、驱动和实际挂载表的目标；没有改挂载参数。
  两节点类型、设备号、设备文件系统及前后路径/描述符身份全部核对，原始设备只以
  `O_RDONLY | O_NOFOLLOW | O_NONBLOCK` 打开，只读 512 字节，不接受任意输入路径。
- 3 项新增回归检查覆盖已挂载块设备下的原始读取、原始节点类型/设备不匹配及非法派生路径；
  原有替换检查扩展为分别替换块节点和原始节点。50 项隔离实验测试通过。
- 工具会话的 `sudo -n` 仍要求认证；已请求用户在原终端重复只读诊断。管理员原始设备读取、
  USB 实物闭环和 Windows 复核仍待验证，不能把受控系统调用测试作为实物通过证据。
- 一手依据沿用上一节的 Apple XNU `spec_open`；查阅日期 2026-09-10。本机实际 errno 现已
  与块设备分支吻合；原始设备分支的本机读取结果仍需上述只读命令确认。
- 最终检查：`scripts/check.sh` 退出 0，50 项隔离实验测试、严格 Release、CoreChecks、
  Gate CLI、只读边界、本地签名包及 5 组负向 fixture 全部通过；`git diff --check` 通过。
  最新 `--inspect` 为 `targetMatched/currentlyWritable=false`。

## 管理员原始设备读取通过（2026-09-10 00:57 +08:00）

- 通过当前任务的只读终端接口取得完整后续输出；用户粘贴的 `Password:` 后实际已经返回：
  `{"bootBytes":512,"diskMutationsPerformed":false,"stage":"deviceReadVerified"}`。
  终端回到 shell 提示，系统没有 sudo/Python 诊断进程残留。命令前的 `exit:1` 属于上一轮失败。
- 该输出由真实管理员 `--probe-device` 产生，确认了两次 512 字节 NTFS 启动扇区读取一致、
  节点身份核对和前后目标/挂载事实检查通过；本轮没有磁盘变更。此结果解决设备读取阻塞，
  不能替代完整 USB 写入、重挂载持久化或 Windows 验证。
- 再次执行 `--inspect`，固定 U310 仍为 `targetMatched/currentlyWritable=false`。下一步为
  同一固定目标的管理员 `--run`，执行已授权的完整实验；代码仍为前述 50 项测试与严格
  Release 已通过版本。本次仅更新真实验证记录，`git diff --check` 通过。

## 系统弹窗启动路径被拒绝（2026-09-10）

- 为执行完整 USB 实验，尝试用 macOS `do shell script … with administrator privileges`
  启动同一个固定脚本；用户明确要求重试并随后确认已授权。两次调用都已结束，输出均为
  `stage=blocked/operation=bootDeviceOpen/errno=1/errnoName=EPERM`，且
  `diskMutationsPerformed=false`。代码路径说明管理员权限检查已通过，拒绝发生在设备打开时，
  不能再描述为仍等待管理员认证，也不能归因于未输入正确密码。
- 两次失败均未生成 `usb-run-…` 目录，系统没有实验 Python 或 NTFS-3G 进程；固定 U310
  的最新 `--inspect` 仍为 `targetMatched/currentlyWritable=false`。没有卸载或文件写入。
- 该启动环境与 00:57 原终端 `sudo --probe-device` 的已验证结果不同，具体系统访问拒绝原因
  尚未确定。停止重复弹窗路径，回到原终端运行固定 `sudo … usb_lab.py --run`；不改变设备
  权限、系统安全设置或实验目标。完整 USB 闭环与 Windows 复核仍未通过。
- 定向系统日志进一步记录两次 Python 责任进程均为 `auid=0/euid=0`；第一次出现后台会话
  `SystemPolicyAllFiles` 的 `record_denial`，第二次同类预检 `authValue=0`，并有
  `SystemPolicyRemovableVolumes` 请求转发。日志中的直接访问者为其 diskutil 子进程，
  尚未把这条 TCC 记录与原始设备 `open` 的 EPERM 一一关联，故仅作为启动环境差异线索，
  不据此扩大系统权限。定向日志保存在被忽略的 `.build/write-validation/usb-authorization-*.log`。

## 原终端完整 USB 运行失败（2026-09-10 16:02 +08:00）

- 用户启动固定 sudo 全流程，已通过管理员设备读取并完成 `nativeUnmountVerified`；
  首次可写挂载时 `mountProcessExited`。卷外证据为
  `.build/write-validation/usb-run-eeqo4enw/`，不是此前零磁盘变更的初始化拒绝。
- 驱动日志与系统日志一致指向 `macfuse-local` 扩展未找到。当前 U310 身份仍匹配，数据卷
  保持卸载，驱动已经退出；无 `writableMountVerified` 或文件检查证据。
  写删、4 GiB + 1 字节文件、USB 重挂载读回及 Windows 均未通过。驱动尝试挂载期间可能
  已触及 NTFS 元数据，不能声称磁盘字节未变。正式 App 和 Gate 状态不变。
- 用户的两次后续重试都因缺少初始原生只读挂载而拒绝，没有新建运行目录。保留失败现场，
  不移除初始挂载约束或盲目重试。当前登录用户仍能枚举两个正式扩展，正在核对管理员
  用户范围差异；没有用 FSClient 空集合断言系统模块不存在。
- 详细诊断、来源和未验证项见 [FSKit 诊断记录](FSKIT-DIAGNOSIS.md)。
- 后续一次性镜像 local 对照确认当前用户的扩展能够启动并形成 local 挂载；但请求的只读
  标志未被系统事实确认，对照中止。标准卸载返回 I/O 错误，普通 diskutil 卸载也失败，
  留有该镜像的挂载表残留；相关测试和卸载进程已退出。暂停新的磁盘操作，保留证据，
  不将此对照计为通过。用户随后返回管理员 PlugInKit 输出，已确认其能看到与当前用户
  相同 UUID、路径及 Parent Bundle 的 local 模块；root 未注册假设被否定，FSKit 运行时
  可见性和启用状态仍不能由注册结果推断。
- 本轮仅修改实验记录与入口说明，没有更换固定依赖或修改运行代码；`git diff --check`
  通过。上一代码版本的 50 项实验测试、严格 Release 和仓库检查结果仍见前节，未重复运行。
- 当前只读复查仍有镜像残留，U310 未挂载；未新增磁盘操作。已保存含启动时间的现场快照，
  下一步由用户正常重启清理残留，再核对挂载与进程状态后继续定位。重启仅用于恢复干净
  实验环境，不能作为 USB 写入故障已修复或可以直接重跑 `--run` 的证据。

## 重启后镜像挂载对照与异常收尾修复（2026-09-10）

- 已确认 21:30:55 的新启动时间，旧镜像残留消失，U310 身份和原生只读挂载通过核对。
- 新独立镜像对照入口固定候选、种子内容及 local FSKit 参数，只操作新建的镜像副本；
  不卸载或写入物理 USB。以异常检查路径为红测试，修复先丢失驱动、后无法卸载的问题。
  正常卸载之前保留驱动，失败等待实际退出，不发送强制退出或强制卸载。
- 当前用户 uid 501 的实际挂载/标准卸载/驱动退出/卸载后健康查询均通过，U310 与挂载表
  前后不变，没有残留。管理员同参数镜像对照已执行，仍报扩展未找到并退出；USB 文件
  写删、4 GiB + 1 字节文件和重挂载读回尚未完成。
- `scripts/check.sh` 退出 0，56 项实验测试、严格 Release 和全部仓库检查通过。证据及
  完整边界见 [FSKit 诊断](FSKIT-DIAGNOSIS.md) 与工具 README。

## 永久降权候选验证（2026-09-10）

- 固定 NTFS-3G 的独立补丁构建在打开存储后、进入 FUSE 前永久降至当前用户；原候选和
  系统安装不变。身份降权测试、镜像生命周期测试及普通用户真实镜像对照已通过。
- 下一步由原终端执行 `mount_context_probe.py --run --user-mount-candidate` 的 sudo 对照。
  管理员路径通过前不切换 USB 协调器；通过后仍需独立验证物理设备、写删、大文件及读回。
- 当前 60 项隔离实验测试、严格 Release 和全部仓库检查通过；候选普通用户实际对照
  证据位于 `.build/write-validation/context-probe-_xs2xuzt/`。
- 管理员 v1 在组列表校验退出、无残留。已修复 Darwin 扩展 `getgroups` 与进程组列表
  混淆，v2 普通用户真实对照和 61 项测试、严格 Release、全部仓库检查通过。管理员 v2
  同入口对照待返回；实际候选摘要和测试来源见诊断记录。
- 管理员 v2 对照 `context-probe-e5vd5b8g/` 已通过，现场无残留，U310 原生只读。独立 USB
  协调器接入同一固定驱动和用户文件操作身份，保留严格物理 source 核对与失败保留边界；
  下一步在已授权 U310 上完成实际闭环，Windows 仍后置且未验证。

## 审计 P2 修复：失败即时落证与运行候选预检（2026-09-28）

- 失败路径先写 `failed`（原始阶段、原因）再进入可能长时间等待驱动的收尾；收尾返回后另记
  `failureHandlingFinished`。证据目录不可写时终端仍输出 `failed` 并标 `journalRecorded=false`。
- `--inspect` 与 `--run` 共用 `run_preflight()`：v2 驱动候选摘要/属主与文件检查身份切换。
  失败报告 `operation=candidateCheck`；`--run` 在租约与原生卸载前即拒绝。`targetMatched`
  新增 `mountCandidateVerified=true`，仍不代表管理员设备读取、FSKit 挂载或写删资格。
- 6 项新增回归先红后绿；`scripts/check.sh` 退出 0（68 项实验测试、严格 Release、只读边界、
  本地签名包与负向 fixture）；`git diff --check` 通过。
- 本机账户目录已由 `/Users/leolu` 变为 `/Users/heyonepiece`，uid 仍为 501，与固定
  `MOUNT_UID` 一致；工具说明中的绝对路径改为仓库相对命令。历史记录中的旧路径保持原样。
- 同日只读 `--inspect` 返回 `blocked/targetQuery/targetAbsentOrAmbiguous`，无磁盘变更。
  下一步由用户连接原 U310 并回传 `--inspect`；USB 闭环与 Windows 复核仍未通过。

## 更换可牺牲目标盘与 macOS 27 依赖缺失（2026-09-28）

- 用户在对话中指定并授权新的可牺牲 USB 盘（XMUP22YM，124,623,257,600 字节，外置 USB，
  原内容仅为 macOS 27 安装器），允许格式化及后续实验；U310 不再是固定目标。
- 新增一次性 `prepare_usb_target.py`：固定型号/容量/USB 外置/原卷名，GPT 抹盘后用固定摘要
  mkntfs 快速格式化，等待原生只读挂载后独占写私有回执。用户 sudo 运行成功：
  `targetConfirmed → diskErased → ntfsFormatted → targetPrepared`，数据分区 124,411,445,248 字节，
  `/Volumes/NTFSLAB` 为原生 NTFS 只读。旧 U310 回执保留为 `approved-usb-target-previous.json`。
- `usb_lab.py` 的 `TARGET_DIGEST` 已改为新回执摘要；`--inspect` 通过目标查询，但在
  `dependencyCheck` 报 `ENOENT`：系统已升级到 macOS 27.0（26A428），`macfuse.fs` 与
  `libfuse.2.dylib` 均不存在。缓存的 macFUSE 5.4.0 DMG 摘要与固定值一致、镜像校验通过。
  macFUSE 5.4.0 在 macOS 27.0 上的兼容性尚未验证；重新安装和启用扩展由用户执行。
- `scripts/check.sh` 退出 0（72 项实验测试）。USB 写删、重挂载读回与 Windows 复核仍未通过。

## macOS 27 首次 USB 运行：FSKit 虚拟挂载来源（2026-09-29）

- 重新安装缓存的 macFUSE 5.4.0（摘要一致、镜像校验通过；GitHub API 显示其为最新正式版，
  发布说明称 FSKit 后端以 macOS 27 SDK 构建，查询日期 2026-09-29）。首次镜像对照在扩展刚
  开启后以 `mountProcessExited` 失败（日志因 quiet 为空），随后手动与正式对照
  `context-probe-loj9xkl6/` 均通过；首败原因未证实。
- `usb-run-3nb_8xf9/`：原生卸载通过，FSKit 可写挂载实际建立，但挂载表来源是 4 KiB 虚拟
  Disk Image（`/dev/disk9`），diskutil 视 disk8s2 为未挂载；`mountedTargetMismatch` 在任何
  文件写入前失败。新的即时落证先输出 `failed`，收尾保留驱动。核对驱动 PID/uid/参数与
  本轮挂载点后执行标准 `umount`，驱动退出，`failureHandlingFinished`；无残留。
- 修正：此前“挂载 source 必须精确为物理分区”在 macFUSE FSKit 下不可满足。改为要求：
  唯一本轮挂载点的 macfuse/fskit/local/nodev/nosuid 可写挂载；来源为 4 KiB 虚拟整盘且本轮内
  不变；物理分区无原生挂载；固定摘要、uid 501 的本轮驱动经 `lsof` 证明持有该物理分区。
  5 项新增回归先红后绿；`scripts/check.sh` 退出 0（75 项实验测试）。
- 失败后已由系统 `diskutil mount` 恢复原生只读挂载，准备重跑。USB 写删与 Windows 仍未通过。

## FSKit 绑定通过，文件操作 EOPNOTSUPP（2026-09-29）

- `usb-run-n_q1gjd9/`：原生卸载、`writableMountVerified`（虚拟来源 + lsof 持有物理分区）通过；
  随后小数据集在建立测试目录后、首个文件前以 `OSError/EOPNOTSUPP(102)` 失败。收尾标准卸载
  `unmountVerified`、`failureHandlingFinished`。原生只读挂载可见 U 盘仅有空测试目录。
- 本机 FSKit 镜像上以真实 uid 501 运行同一 `prepare()` 33 项通过；手动附加 `blkdev` 选项仍通过。
  普通用户无法以块设备形式挂载（ntfs-3g 拒绝），块设备后端与 root 实际 uid + 临时 euid 的
  文件操作身份两项差异尚未区分。
- 诊断增强：失败记录新增 `failedAt`（文件名:函数:行号，不含目录或错误正文）；USB 驱动去掉
  `quiet`，ntfs-3g 自身错误写入运行内挂载日志。2 项新增回归先红后绿，77 项实验测试及
  `scripts/check.sh` 通过。已恢复原生只读挂载，待下一次管理员运行定位具体调用。

## EOPNOTSUPP 根因：no_def_opts 取消了默认 silent（2026-09-29）

- `usb-run-xzbp8t4h/` 定位 `failedAt=file_cycle.py:__init__:39`，即测试目录 `mkdir`；目录实际已建立。
- NTFS-3G 2026.7.7 源码：上下文 `uid = getuid()`（驱动以 root 启动，记为 0）；权限未启用时
  `chown` 目标与上下文 uid/gid 不同即返回 `-EOPNOTSUPP`，除非 `silent`。`silent` 默认开启，
  但 `no_def_opts` 同时取消默认 silent（`ntfs-3g_common.c:377-378`）。uid 501 新建条目时的
  属主设置因此失败；镜像对照由 uid 501 启动驱动，上下文 uid 一致，所以未暴露。
- 修正：USB 驱动固定参数改为 `rw,no_def_opts,silent,backend=fskit,norecover,no_detach,local`，
  恢复上游默认的 silent，不启用 permissions，也不带回 `allow_other,nonempty`。镜像上带该
  参数的实际挂载、33 项 prepare/cleanup 与标准卸载通过；1 项新增回归先红后绿；
  `scripts/check.sh` 通过。
