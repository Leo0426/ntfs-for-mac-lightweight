# 隔离文件语义检查与复验

此目录是 ADR 0009 的隔离实验，不进入正式 App。`usb_lab.py` 是需要用户在终端以 sudo
启动的固定 USB 实验入口；其余文件语义、清单复验和 FSKit 观察工具没有磁盘执行能力。
`file_cycle.py` 只负责调用方已经确认的目录中的文件语义；它不能识别 NTFS、授权测试盘或证明
FSKit 已经挂载。不得把临时目录单元测试视为 NTFS 硬件证据。

## 接口

- `prepare(root, large_bytes=0, progress=...)`：独占创建随机测试目录，执行创建、独立读回、
  长短覆盖、追加、文件/目录重命名、已有文件替换、删除、非空目录拒绝。返回精确内容清单。
  `large_bytes` 可选，最大为 4 GiB + 1；大文件按块生成和读取。
- `verify(root, manifest)`：独立打开并核对全部保留文件长度、SHA-256、目录清单和删除项缺席。
- `cleanup(root, manifest)`：先验证全部内容，再逐个核对和删除清单内文件，最后移除空测试目录。
  损坏、未知条目和链接均停止；不会递归删除。中途失败可能留下部分条目，不能直接重跑清理。
- `manifest_io.save_manifest(path, manifest)`：把清单保存为规范 JSON 与 SHA-256，使用 `0600`
  独占创建并同步文件和父目录，拒绝覆盖旧证据或跟随链接。调用方须选择测试卷外的保存位置；
  本接口没有卷身份输入，不能自行证明保存位置属于另一卷。失败可能留下不完整文件，保留
  该文件并使用新的证据路径，不覆盖或自动删除。
- `manifest_io.load_manifest(path)`：最多读取 16 KiB，拒绝特殊文件、硬链接、符号链接、
  读取期间替换、重复 JSON 键、非规范字节、摘要不符及非法清单字段。摘要只用于检测损坏，
  不是签名、来源认证或磁盘操作授权。

调用方须把 manifest 保存到测试卷以外，并在标准卸载、重新挂载及重新确认卷身份后调用
`verify`。接口返回 `fileChecksPassed` 只表示文件语义检查通过，**不表示发生过重挂载**。
Windows 和重挂载结果必须由独立证据记录，不能根据这个字段推断。

调用方在任何真实卷写入前，必须取得新鲜的来源、挂载点、文件系统、可写状态和授权目标
身份事实；未知、缺失或矛盾即停止。驱动输出“Mounted”不是事实证明。
文件语义模块自身不提供这些资格判断；下方 USB 实验入口另行核对固定目标和系统事实，
仍不是正式应用的资格判断或通用磁盘测试 CLI。

## 独立只读复验命令（macOS）

实验调用方在 `prepare` 成功后调用 `save_manifest` 保存原始清单，标准卸载、重新挂载并
重新核对目标身份后，可以用新的 Python 进程执行：

```sh
python3 scripts/write-validation/verify_files.py \
  --root /Volumes/CONFIRMED_TEST_VOLUME \
  --manifest /ABSOLUTE_EVIDENCE_DIRECTORY/manifest.json
```

`--root` 指向包含随机 `ntfslite-check-…` 子目录的根目录；不要把该子目录本身作为 root。
路径必须没有符号链接（包括父目录）；macOS 的 `/tmp`、`/var` 别名应使用对应的真实路径。
此命令仅加载清单和读回数据，不提供 prepare、cleanup 或磁盘变更入口。

- 成功退出 0，JSON 报告 `fileChecksPassed`、已核对保留文件及删除项数量。
- 清单加载或文件复验失败退出 1，报告 `manifestRead` 或 `fileReadback` 阶段及固定原因；
  不清理残留文件，不输出原始路径或系统异常正文。参数错误使用 argparse 的退出码 2。
- 所有报告均保持 `remountVerified: false` 与 `windowsVerified: false`。同一挂载上的重复
  读回也会成功，调用方必须另外记录卸载/重挂载事实。该命令不是 Windows 验证器。
- 核对包含读回前后的完整目录清单，但不是文件系统原子快照；运行时应停止并发修改测试目录。

## 自动化检查

```sh
python3 -m unittest discover -s scripts/write-validation -p 'test_*.py' -v
```

这些检查只在系统临时目录运行；它们已纳入 `scripts/check.sh`。真实 NTFS 执行状态见
[实验记录](../../.scratch/write-delete-validation/PLAN.md)。

## 只读 FSKit 注册诊断（macOS）

`InspectFSKit.swift` 使用 Apple 的 `FSClient.fetchInstalledExtensions`，只读取当前调用进程收到的模块事实，
不执行安装、注册、系统设置变更或挂载。编译和运行：

```sh
mkdir -p .build/write-validation
swiftc -O -warnings-as-errors -parse-as-library \
  scripts/write-validation/FSKitRegistration.swift \
  scripts/write-validation/InspectFSKit.swift \
  -o .build/write-validation/inspect-fskit-registration
.build/write-validation/inspect-fskit-registration
```

报告仅包含 `standard` / `local` 两个固定别名及状态，不输出其他扩展、原始路径或错误正文。
报告标记 `observationScope: currentProcess`；未观察到、未启用、重复或安装位置不符都不能
提供肯定证据，查询失败与成功返回空列表保持可区分。`notObserved` 不表示系统未安装：
本机 ad-hoc 工具查询时，`fskitd` 日志报告调用方无 Team ID。API 的完整可见范围尚未确认，
因此不能把此工具的空结果作为 macFUSE 不可用的单独依据或必须通过的挂载前置门槛。
正常文件 URL 可有一个结尾目录斜杠，除此之外只接受正式安装位置的精确 URL。

| 退出码 | 结果 | 含义 |
| --- | --- | --- |
| 0 | `observedAndEnabled` | 当前进程观察到两个扩展均在预期位置且启用 |
| 1 | `blocked` | 当前查询未建立肯定证据；未观察到、未启用、重复或位置不符 |
| 2 | `queryFailed` | API 错误、缺失结果或系统不支持；输出失败也退出 2 |
| 3 | `timedOut` | 15 秒内未完成查询 |
| 64 | 用法错误 | 只支持无参数查询和 `--help` |

该检查不核验代码签名、路径所有权、依赖批准、目标介质或实际挂载。所有 JSON 报告均保留
`mountVerified: false`、`writeAuthorized: false`，不能作为写入资格。
需结合 PlugInKit、macFUSE 自身的日志和实际挂载事实独立诊断。
当前故障、重启后复测与已尝试的修复见
[FSKit 诊断记录](../../.scratch/write-delete-validation/FSKIT-DIAGNOSIS.md)。

## 固定 USB 的管理员执行入口

### 挂载调用环境对照（2026-09-10 重启后）

上轮镜像残留已随 21:30:55 的正常重启消失；U310 已重新核对为原生只读挂载。
原始候选在当前用户下通过，管理员同参数对照仍报扩展未找到，且已正常退出、无残留。
永久降权 v1 的组列表检查使用了 Darwin 账户列表接口，现已修正为进程列表并增加编译模式
回归测试。当前入口固定 v2；普通用户和管理员启动对照均已通过。以下保留镜像诊断入口：

```sh
sudo /opt/homebrew/bin/python3 -I -S scripts/write-validation/mount_context_probe.py --run --user-mount-candidate
```

该入口只使用已固定 SHA-256 的 128 MiB 实验镜像种子，每次独占创建新副本；不以可写方式
打开种子，不打开物理设备，不卸载 U 盘。参数固定为原有 FSKit/no-recovery 参数加
`local,quiet,no_detach`；quiet 用于减少交互提示，脚本不主动重注册或切换后端。普通用户与 sudo 使用相同
镜像内容、候选和参数，JSON 记录实际有效 UID；不能从结果反推 root 必然看不到注册。

`--inspect` 仅核对候选、种子和现场，不创建镜像或发起挂载。`--run` 拒绝已有实验挂载或
驱动，对真实挂载核对本轮唯一挂载点、local FSKit 标志、4 KiB 虚拟 Disk Image 来源、
驱动持有的镜像和镜像身份。属性检查失败仍先保留驱动并尝试标准卸载；如果系统未完成
收尾，保持终端与驱动存活，输出 `inspectionRequired` / `quiescencePending`，不强制结束。

成功只报告 `mountContextVerified`：本次镜像可写挂载、标准卸载、驱动退出及卸载后健康
查询完成，前后 U 盘与挂载表一致。`usbWriteVerified=false`、`windowsVerified=false`。
证据保存于 `.build/write-validation/context-probe-…/`；不会自动继续 USB 写入。

`--user-mount-candidate` 显式选择固定摘要的本地 NTFS-3G 补丁构建；不带此参数仍使用
原始候选。补丁在打开存储前核对调用者，打开后、调用 FUSE 前永久降为 uid 501/gid 20，
清除附加组和保存的 root 身份。探针独立查询驱动实际/有效 UID/GID，不把日志视为证明。
管理员协调器只在文件属性检查时临时切换有效身份并恢复；卸载子进程以用户身份启动。
构建脚本 `build_user_mount_candidate.py --build` 要求新目录不存在，记录输入、补丁和产物
摘要，不安装或替换系统依赖。管理员成功证据为 `context-probe-e5vd5b8g/`；这仍不能替代
USB 写入证据或允许接入正式 App。

### USB 全流程（永久降权候选）

镜像写删与重挂载已通过，见 [镜像结果](../../.scratch/write-delete-validation/IMAGE-RESULT.md)。
`usb_lab.py` 仅匹配本次已授权的 U310（32,212,254,720 字节）及其既定 NTFS/EFI 分区组合。
私有分区标识位于已忽略的 `.build/write-validation/approved-usb-target.json`，文件的 SHA-256
固定在源代码中；修改回执、目标缺失/重复、额外分区、同盘 EFI 已挂载或身份矛盾都会拒绝。
BSD 编号可以在启动新一轮前变化，单轮运行中变化立即停止；分区 UUID 不是 NTFS VolumeUUID。

先进行无磁盘变更的只读核对：

```sh
python3 -I -S scripts/write-validation/usb_lab.py --inspect
```

在仓库根目录运行。`targetMatched` 现在还要求 `--run` 实际使用的 v2 驱动候选摘要、属主和
文件检查身份切换通过（`mountCandidateVerified=true`）；任一失败报告 `operation=candidateCheck`。
`--run` 在取得租约和卸载原生卷之前执行同一预检。管理员设备读取、FSKit 挂载与文件写删仍只能
由完整运行证明，`targetMatched` 不等于运行资格。

本机已实际得到 `targetMatched` 和 `deviceNodeType=block`；预检同时检查 diskutil 返回的
`/dev/disk…` 是块设备，拒绝字符设备、链接及其他文件类型。该节点继续用于挂载及来源核对；
启动扇区从对应的 `/dev/rdisk…` 原始字符设备只读获取。读取前核对两节点的规定类型、相同
设备号及设备文件系统，读后重新核对两条路径与原始描述符的设备号、inode 和类型。
普通用户原始设备读取被系统拒绝，`--run` 和 `--probe-device` 的非管理员调用在磁盘操作前
报告 `administratorAuthenticationRequired`。此前管理员读取确认为块设备打开返回 `EBUSY`；
修正后先在用户自己的终端运行只读诊断：

```sh
sudo /opt/homebrew/bin/python3 -I -S scripts/write-validation/usb_lab.py --probe-device
```

此模式核对固定目标和依赖，连续读取两次启动扇区并核对前后目标与挂载表；不创建实验租约
或证据目录，不卸载、不写入。成功仅报告 `deviceReadVerified` 和 `bootBytes=512`，不证明
可写挂载或完整实验通过。失败输出 `operation`，系统调用错误另附 `errno` / `errnoName`，
不输出设备原始内容、路径或异常正文。应保留失败 JSON，再依据实际阶段与错误码修复。

完整实验还要求目标当前处于原生只读挂载。2026-09-10 16:02 首次完整运行已完成卸载，
但 FSKit 挂载因 `macfuse-local` 扩展未找到而失败。重启后残留已消失、原生只读挂载恢复，
永久降权候选的管理员镜像对照通过。当前 USB 入口固定使用同一候选并再次核对实际目标：

```sh
sudo /opt/homebrew/bin/python3 -I -S scripts/write-validation/usb_lab.py --run
```

密码只输入 sudo 的终端提示，不传给脚本、不写日志或配置。`-I -S` 隔离 Python 环境与 site
初始化；脚本仅使用标准库和本目录代码。此入口没有安装提权 helper 或保存凭据。
固定设备核对及原始扇区读取保留管理员身份，驱动打开设备后永久降权。文件写删使用
uid 501，独立读回和标准卸载子进程也使用该身份；不允许跨用户 FUSE 访问。
失败时只在新鲜目标、来源和可写挂载仍全部匹配时执行标准卸载，不清理测试数据；归属
不明则保留驱动与终端等待检查，绝不先终止驱动。文件和挂载检查结果分别记录。
本机通过 AppleScript 管理员弹窗启动同一脚本时，两次均在管理员检查通过后返回
`bootDeviceOpen/EPERM`，没有磁盘变更。该启动路径的具体系统拒绝原因未定位；使用前述
已验证能读取设备的原终端 `sudo` 路径，不把弹窗授权成功等同于设备访问成功。

执行前固定核对 NTFS-3G/probe/libfuse 摘要与 macFUSE 签名；在当前原生只读挂载下读取并
绑定原始 NTFS 启动扇区，然后每次重新核对整盘、分区、同盘卷、设备节点和该扇区。
原始启动扇区只用于本轮实验的连续身份核对，不产生正式 VolumeSnapshot 或 Gate 资格。

执行顺序为标准卸载、no-recovery 健康预检、固定 FSKit 可写挂载、小数据集写删/清理、
含 4 GiB + 1 字节文件的数据集、标准卸载/重挂载、独立进程读回、最后标准卸载。
写入前必须看到准确 `/dev/disk…` 来源的本地 `macfuse` + `fskit` 可写挂载，系统卷事实与
挂载标志还必须一致；只看到驱动输出或其他来源的挂载会停止。大文件可能需要数分钟。

- 成功状态为 `localChecksPassed`，保持 `windowsVerified=false`。保留 22 个文件和 6 个
  删除项的清单，供后续 Windows 复核；测试目录名会在输出中显示。
- 证据与日志独占保存到卷外 `.build/write-validation/usb-run-…/`，清单为 `manifest.json`。
- 变更命令超时仍等待真实退出，并持有本实验进程之间的独占锁；不会因超时释放锁、强制
  卸载或强制结束驱动。若显示 `quiescencePending`，保持窗口开启并处理已有系统提示。
- 任何失败保留文件与实际状态，不继续复验、清理或输出成功；失败后需要复核残留挂载状态，
  不直接重复运行。原始失败原因在收尾等待驱动之前先写入 `failed` 记录并输出；收尾返回后另记
  `failureHandlingFinished`。证据目录不可写时仍在终端输出 `failed` 并标记 `journalRecorded=false`。成功后卷保持卸载，但本脚本不推出整盘，也不声明可以拔出。
- 用户首次运行在设备类型检查处误拒绝；2026-09-10 修正后第二次运行报告 `blocked/OSError`，
  两次均未执行磁盘变更。新增只读诊断已采集到 `bootDeviceOpen/EBUSY`，确认已挂载块设备
  不能按原方式打开。改为严格配对的原始设备只读读取后，2026-09-10 00:57 管理员复测返回
  `deviceReadVerified/bootBytes=512/diskMutationsPerformed=false`。设备读取已通过，完整
  USB 写删、重挂载和 Windows 复核仍未通过。
  正式 App、生产依赖批准目录及 Gate 状态均不改变。
- 16:02 原终端完整运行已生成 `usb-run-eeqo4enw`，完成 `nativeUnmountVerified` 后发生
  `failed/mountProcessExited`；驱动和系统日志指向 local 扩展查找失败。已执行原生卸载与
  可写挂载尝试，尚未进入测试文件写入。数据卷保持卸载，直接重跑会被
  `initialNativeReadOnlyMountRequired` 拒绝。诊断进展见前述 FSKit 记录。
