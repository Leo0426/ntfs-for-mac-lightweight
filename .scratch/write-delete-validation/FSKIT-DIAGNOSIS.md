# macFUSE FSKit 注册与镜像闭环诊断

Date: 2026-09-10
Status: image-local-checks-passed / usb-fskit-mount-failed

最新 USB 结果：2026-09-10 16:02 +08:00，用户原终端的 sudo 运行已通过设备读取并完成
原生只读卷卸载；首次 FSKit 挂载时驱动退出。日志报告 `macfuse-local` 扩展未找到。
尚未进入测试文件写删、4 GiB + 1 字节文件或重挂载读回。详细证据与待验证假设见末节；
下文 2026-09-09 的“USB 尚未变更”只描述当时状态。

用户已重启，后续 PlugInKit 查询已正确列出两个 macFUSE 扩展及所属应用；一次性 NTFS
镜像的真实挂载、写删、重挂载读回、清理和卸载均已通过。之前“扩展仍未恢复”的判断已被
新证据更新。尚不能确定重启、重新启用或注册操作中哪一步恢复了关联。

## 本轮证据与转折

- macOS 26.6.2（25G83）、arm64；启动时间为 2026-09-09 16:41:14 +08:00，SIP 启用。
- macFUSE 安装 receipt 为 5.4.0；正式应用、两个扩展和库严格签名验证通过，Team ID 为
  `3T5GSNBU6W`。应用 Gatekeeper 评估为 `accepted / Notarized Developer ID`。
- 重启后 22:24:56 的 `pkd` 日志仍拒绝两个扩展，原因涉及所属应用关系未被认可。
  此历史日志不是当前状态，也不是降低 SIP 的依据。
- 系统设置“按类别”中的两个开关均为开启；分别关闭再开启、局部扩展注册、正常启动原
  应用及用户 Applications 下的签名副本注册比较均已执行。副本已注销、核对并完整移除。
- 最终 PlugInKit 枚举包含两个正式模块，详细输出的 Parent Bundle 都指向
  `/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app`，注册时间为 22:29:24。
  不能将后来重新查询发现成功，等同于该次查询造成恢复。
- 随后只对已授权的第二个 128 MiB 镜像进行实测，实际挂载表确认 FSKit 可写挂载，镜像
  本机闭环通过。数据及证据边界见 [镜像结果](IMAGE-RESULT.md)。USB 尚未变更。

## 更正 FSClient 空结果的含义

旧临时工具把成功查询中的空集合写为 `missing`，并用它判断系统模块缺失；这个解释过强。
22:35:54 本机工具查询时，`fskitd` 报告连接无 entitlement，且未找到调用方 Team ID。
最终 PlugInKit 已可见、镜像也真实挂载成功时，ad-hoc FSClient 工具仍返回空集合。
因此它不能单独判断 macFUSE 是否安装、注册或可用，更不能作为镜像实验必须通过的硬门槛。

工具现标记 `observationScope=currentProcess`，使用 `notObserved`；两个模块都被观察到并
启用时仅报告 `observedAndEnabled`。查询失败、未观察到、禁用、重复和错误路径保持区分，
始终不授予挂载或写入权限。跨调用方签名身份的完整可见范围尚未验证，不作通用 API 保证。

## 一手来源与适用范围

- [Apple FSClient 枚举接口](https://developer.apple.com/documentation/fskit/fsclient/fetchinstalledextensions(completionhandler:))
  及本机 `FSClient.h` 确认公开只读查询方式；该页面未明确当前调用方的跨 Team 可见范围。
- [macFUSE #1192](https://github.com/macfuse/macfuse/issues/1192) 报告同系统版本上的 local
  模块枚举问题，但其 PlugInKit 可见，不能等同于本机较早的两个模块关联拒绝。
  [维护者建议](https://github.com/macfuse/macfuse/issues/1192#issuecomment-5409800952)
  曾提出全用户 LaunchServices 重建，[报告者复测](https://github.com/macfuse/macfuse/issues/1192#issuecomment-5410114839)
  表示没有修复并观察到其他应用权限需重新授予。本机未执行全库删除。
- [维护者对 #1194 的说明](https://github.com/macfuse/macfuse/issues/1194#issuecomment-5470510841)
  建议在系统设置“按类别”启用，本机已使用该路径；未执行 issue 正文的手动 plist 修改脚本。
- [macFUSE 5.2.0 说明](https://macfuse.github.io/2026/04/09/macfuse-5.2.0.html) 记录过重新
  注册后的子系统状态问题；[5.4.0 说明](https://macfuse.github.io/2026/09/07/macfuse-5.4.0.html)
  声明 SDK 27 构建与旧系统兼容。这些说明不单独证明本机恢复的根因。

原拟上游问题报告已撤下，未对外发布。2026-09-09 结束时，下一步为用户在自己的终端完成
固定 USB 入口的管理员认证；此后的设备读取和 USB 首次运行结果如下。Gate 保持原状。

## USB 首次运行：扩展查找失败（2026-09-10）

- 00:57 原终端只读设备探针通过，报告 `deviceReadVerified/bootBytes=512`。随后两次
  AppleScript 管理员启动均在设备打开返回 `EPERM`，未进入磁盘变更；原终端的 sudo
  全流程则越过该失败点。这些是不同启动环境下的结果，不能继续描述为等待管理员认证。
- 16:02 完整运行生成 `.build/write-validation/usb-run-eeqo4enw/`，依次记录 `started`、
  `nativeUnmountVerified`、`failed/mountProcessExited`。`mount-02.log` 报告
  `File system extension not found`，定向系统日志明确是
  `io.macfuse.app.fsmodule.macfuse-local`。`Mounted … (Read-Write)` 是驱动内部日志，
  随后挂载失败并退出，不证明系统存在可写挂载。
- 失败后 fresh 目标核对仍为固定 U310；数据分区未挂载，挂载表没有 USB 实验卷，驱动已退出。
  原生卸载和可写挂载尝试属于已执行的磁盘变更；不能据文件测试未开始推断 NTFS 元数据完全
  未变。两次随后重试均在 `initialNativeReadOnlyMountRequired` 拒绝，没有新的实验目录。
  保留上述失败证据和卸载状态，不直接重跑或清理未知数据。
- 当前登录用户的 PlugInKit 仍列出两个正式扩展及正确 Parent Bundle。随后用户在同一
  原终端通过 sudo 查询，也取得唯一 local 模块，UUID 为
  `FFA92B33-B355-4C3C-A4DF-2D516A334E8F`，正式路径、Parent Bundle 及时间戳与当前
  用户查询一致。这否定了“root 完全没有注册该模块”的假设；仍不能据 PlugInKit 注册
  推断 macFUSE 挂载进程的 FSKit 枚举、启用或挂载可用性。
- 两边输出均没有 `+` 标记。本机 `man pluginkit` 将 `+` 定义为用户明确选择 use，且说明
  `-m` 查询不施加宿主特定限制；不能因缺少该标记直接断定 FSKit 未启用。当前用户的
  local 镜像已经实际进入过挂载阶段，也反对这样的简单推断。未盲目执行 `-e use` 或重注册。
- [Apple 工程师对 FSKit 用户状态的说明](https://developer.apple.com/forums/thread/831396)
  指出 AppEx 注册及同意状态按用户区分；[MFMount 公开挂载实现](https://github.com/macfuse/mount/blob/master/Mount/Mounter.swift)
  的请求包含后端、挂载点及选项，没有公开的任意目标用户参数，并要求调用导出 API。
  查阅日期 2026-09-10；上游 main 源码不是本机二进制身份或本机根因证据。未据此修改
  驱动身份、设备权限、私有 XPC 协议或系统安全设置。

## 当前用户的 local 镜像对照（2026-09-10 16:14 +08:00）

- 只对此前已验证、保留的 128 MiB 常规镜像做对照。启动前核对固定候选、镜像 owner、
  类型、大小、device/inode、无实验挂载及无驱动进程；USB 仍为未挂载的固定目标。
  参数为 `ro,no_def_opts,backend=fskit,norecover,no_detach,local`，未执行文件写删。
- 系统日志确认 uid 501 的 `macfuse-local` 扩展启动并建立通道；真实挂载表出现
  `/dev/disk4 on /Volumes/NTFSLiteLocalProbe-9ae653de0fd9`
  及 `macfuse, local, …, fskit, mounted by leolu`。因此当前用户的 local 模块能进入真实
  挂载阶段，不能把 USB 的失败解释为 local 扩展在所有调用环境下都不可用。
- 尽管 NTFS-3G 记录 Read-Only，系统挂载表没有 `read-only`，`statvfs` 也没有 `ST_RDONLY`。
  对照协调脚本在此拒绝 `unexpectedProbeMount` 并退出，没有进入文件操作；驱动随后已不在
  进程表中，日志记录服务端连接失效。本轮不报告只读挂载验证通过，也未完成镜像字节摘要
  的前后核对。后续对照脚本需在校验异常时保持协调进程，收集子进程退出与残留状态。
- fresh 核对确认上述挂载来自本轮唯一临时挂载点且与 U310 不同，随后仅对该挂载点执行
  标准 `/sbin/umount`。等待期间挂载表条目短暂消失，但命令未返回，不能将其报告为变更
  静止或完整卸载成功。确认该镜像对应的扩展 PID、uid、启动时刻、正式路径及失效连接后，
  对该单独扩展进程请求普通 SIGTERM；没有终止共享的 fskitd 或 macFUSE daemon，也未使用
  SIGKILL 或强制卸载。标准卸载随后返回 `Input/output error`，挂载表恢复残留条目。
- 再次核对前一卸载、驱动及该扩展进程全部退出后，对同一临时挂载点尝试标准
  `diskutil unmount`，仍退出 1。两个卸载调用现均已结束。`diskutil info` 将该来源标为
  4 KiB 的虚拟 Disk Image，且 MountPoint 为空，然而稳定挂载表仍有原条目；事实矛盾，
  不据此推出或删除设备，不继续新一轮实验。U310 身份保持匹配且数据卷未挂载。
- 对照日志保留为 `.build/write-validation/image-local-readonly-64ff9c7f65c9.log`、
  `image-local-probe-activation.log` 和 `image-local-probe-unmount.log`。
  该对照不升级原镜像结果、USB 结果或 Gate；USB 写删、4 GiB 和重挂载读回仍待完成。

## 管理员注册确认后的下一步（2026-09-10）

本轮只有只读复查，未发起新磁盘变更。依赖摘要与签名仍通过，U310 仍匹配且未挂载；
相关驱动与标准卸载进程已退出，但镜像残留的挂载表和 diskutil 仍矛盾。快照保存于
`.build/write-validation/fskit-root-registration-confirmed-20260910.json`，管理员枚举明确标记为
用户提供，快照另保存当前用户的实时查询与系统启动时间。

已尝试的普通 umount 和 Disk Arbitration 卸载均失败，当前不重复尝试或使用强制卸载。
请用户保存工作后正常重启，以清理这次失败对照的残留；这不是 USB 故障已修复的声明。
重启后先确认启动时间变化、镜像残留消失、无变更进程、固定 U310 身份与原生只读挂载；
不要直接运行完整 USB 写入实验。

后续假设依验证成本排序：用户范围内的 FSKit 启用状态差异、macFUSE 挂载进程的 FSClient
枚举差异、管理员启动上下文差异。需保留同一镜像、候选及挂载选项，只改变调用上下文，
才能将不同结果归因于用户身份；目前的 root/USB 与 user/镜像对照还混有资源类型差异。
后续镜像协调器须在异常路径继续持有子进程句柄，保留驱动直到标准卸载结果已收集，避免
重演临时协调脚本退出后驱动连接消失的现场；所有不完整结果都保持失败关闭。

## 重启后的受控挂载对照（2026-09-10）

- 系统启动时间更新为 21:30:55 +08:00。稳定挂载表已无前述镜像残留，无 NTFS-3G 或变更
  进程；固定 U310 的身份核对通过，原生 NTFS 只读挂载已恢复。该结果只说明现场恢复，
  不说明先前 USB 挂载错误被修复。
- 新增独立 `mount_context_probe.py`，固定种子摘要
  `835e54c912d82eac3cf3a6beaf75f73e379191d0e142b950fc2c7a49ba69fc13`，只读取得完整种子并
  核对路径、描述符身份及摘要，再独占创建新副本。用户/管理员对照保留相同种子内容和
  `rw,no_def_opts,backend=fskit,norecover,no_detach,local,quiet`，不操作物理设备。
- 挂载校验异常的系统边界测试先复现“未卸载就退出”，再把标准卸载和驱动等待放入共同
  收尾路径。6 项回归检查覆盖此错误、正常流程、已有残留、启动中断、卸载失败以及无挂载
  的驱动失败；验证失败不主动终止仍挂载的驱动。未知归属时保留驱动等待人工检查。
- uid 501 的真实对照通过，卷外证据为 `.build/write-validation/context-probe-p7cf6q4m/`。
  挂载表确认 local FSKit 可写，虚拟来源为本次 4 KiB Disk Image，驱动确实持有镜像副本；
  标准卸载完成、驱动退出、卸载后 NTFS 健康查询通过。前后 U310 与挂载表一致；最新挂载表
  无实验残留。该对照没有运行文件写删或 4 GiB 测试。
- 管理员对照已返回并与实际日志核对，证据为 `context-probe-ci1oaeyj/`：同样镜像与参数
  仍在 `MFMount: File system extension not found` 退出，没有残留。本轮两组对照确认调用
  身份与结果相关，尚不能断言 FSKit 内部的精确根因，也不是用户未输入正确密码。
- `scripts/check.sh` 退出 0：56 项隔离实验测试、严格 Release、只读边界及全部仓库检查
  通过。`git diff --check` 通过。正式 App、生产依赖批准目录及 Gate 保持不变。

## 设备打开后永久降权候选（2026-09-10）

- 新增独立构建脚本与 C 身份校验，复制原始固定构建后只在新目录编译；不安装，不改设备
  ACL，不修改 macFUSE。C 补丁在存储访问前拒绝错误身份，在打开存储后、调用 FUSE 前执行
  `setgroups`、`setgid`、`setuid`，核对实际/有效 ID 与组。根据本机 setuid(2) 手册，root
  调用 setuid/setgid 会同时改变保存 ID；驱动没有恢复 root 的路径。
- 固定新驱动 SHA-256 为 `13828433c63659992556eab4ab8acc05bd6d393a6be392fb85872a40f7d69d58`。
  构建保留上游的 reparse-path 未初始化变量与 daemon 弃用警告；本补丁没有改变这些路径，
  不能把编译成功解释为第三方源码已通过完整安全审查。
- `--user-mount-candidate` 显式选择该候选；原始对照仍保留。镜像探针通过 ps 核对实际及
  有效用户/组，并将挂载点的文件属性检查和标准卸载限定为 uid 501。协调器的临时身份
  范围不执行子进程，离开范围时恢复原身份；驱动本身永久降权，两者不能混淆。
- 普通用户真实对照通过，证据 `context-probe-_xs2xuzt/`，包含 local FSKit 可写挂载、
  驱动真实身份、标准卸载、退出、卸载后健康与 U310 前后状态一致。管理员启动后的永久
  降权路径仍待用户 sudo 对照；物理设备已打开描述符在降权后能否完成写删仍未验证。
- 断线恢复时 U310 不在挂载表，用户接回后重新核对目标通过；没有沿用旧 BSD 名授权。
  目前 USB 写删、4 GiB + 1 字节、重挂载读回和 Windows 均未通过，正式 App 仍只读。
- 当前实现的 `scripts/check.sh` 退出 0：60 项隔离实验测试、严格 Release、只读边界及
  全部本地 App 检查通过；日志为 `/private/tmp/ntfslite-user-mount-check.log`。

### v1 的组列表校验错误与 v2（2026-09-10）

- 管理员 v1 对照 `context-probe-2m02l58j/` 在永久降权检查退出，未进入 FSKit、无挂载
  残留。其日志缺少具体子步骤，不能把这次失败认定为 setuid 系统调用拒绝。
- 本机 `man 2 getgroups` 明确区分进程组列表与 Darwin 扩展的账户默认组列表。`nm -u`
  证明 v1 实际链接 `_getgroups$DARWIN_EXTSN`，因此 `setgroups` 后要求该查询返回单组
  是错误条件。使用实际 `gnu23/_DARWIN_C_SOURCE` 编译模式新增红测试，复现错误符号。
  v2 显式链接公开 libc 的进程组列表版本 `_getgroups`，保留严格单组核验，测试转绿。
- Python 的 `os.getgroups` 同样有此区别，见 [Python 官方说明](https://docs.python.org/3/library/os.html#os.getgroups)。
  协调器通过固定系统 libc 的公开 `getgroups` 读取和恢复实际进程组，而非账户默认组。
  此前 mock 没有覆盖编译模式，是本轮测试遗漏；现已增加该回归和错误组列表的 OS 边界测试。
  内核进程组语义亦见 [Apple XNU 源码](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_prot.c)。
- v2 保留 v1 目录，构建在 `ntfs-3g-user-mount-v2-build`，固定摘要
  `3e512072bcb53b5d4af0582b23c980e2c679aacc36afdf0f2a330317dbf01d86`。降权失败日志新增
  操作名、errno、实际/有效 ID；协调器在创建镜像前先检查临时身份切换和恢复。
- v2 普通用户镜像对照 `context-probe-rp_khxyi/` 通过并正常卸载。61 项测试及严格 Release、
  只读边界、全部仓库检查通过，日志 `/private/tmp/ntfslite-user-mount-v2-check.log`。
  管理员 v2 对照待执行，USB 写入仍未验证。

## 管理员 v2 镜像通过，进入 USB 闭环（2026-09-10）

- 用户返回 `context-probe-e5vd5b8g/`，已核对卷外结果和驱动日志：协调器 euid 0，驱动
  实际/有效 uid 501、gid 20；真实 local FSKit 可写挂载、标准卸载、驱动退出、卸载后健康
  检查及前后 U310 状态一致均通过。当前挂载表无实验残留、无驱动/卸载进程，U310 原生只读。
- 这表明原管理员调用环境中的扩展查找阻塞可由当前独立永久降权候选跨过，不说明 FSKit
  内部根因已经完全解释。用户的管理员认证有效，先前失败不应归咎于确认操作。
- USB 协调器接入同一 v2 固定摘要及 local/quiet 参数：原始设备检查仍为 root，驱动永久
  降权，文件写删临时使用用户身份，独立复验和卸载子进程使用永久用户身份。写入前仍要求
  真实挂载 source 精确匹配物理分区，不能使用镜像的虚拟 source 放宽 USB 资格。
- 增加独立复验子进程身份测试；失败收尾回归先红后绿，未知挂载归属不再终止驱动。
  可重新证明同一可写挂载时才标准卸载，否则保留进程等待检查，不清理测试文件。
  USB 写删、4 GiB + 1 字节与重挂载读回仍待本次实际运行。
- `scripts/check.sh` 退出 0，62 项实验测试、严格 Release、只读边界与全部本地 App 检查
  通过；日志 `/private/tmp/ntfslite-usb-user-driver-check.log`。运行前只读 `--inspect` 再次
  确认固定 U310、32,000,442,368 字节数据分区及原生只读状态。
