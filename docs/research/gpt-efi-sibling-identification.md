# GPT EFI 与 NTFS 同盘分区的只读识别边界

检索与本机只读核对日期：2026-09-29。资料范围：本机 macOS 27.0 SDK、Apple 开源
`IOStorageFamily` 固定提交 `7edb88fbae296fb7c8ce2f64e115e116e566d51c`、
`DiskArbitration` 固定提交 `a542bda934211dc3c301bfdcc7f21349c4164a85`，以及
UEFI 2.11 GPT 规范。本笔记记录系统字段能证明什么；不批准任何磁盘变更。

## 问题与结论

本机实验 U 盘为 GPT + EFI + NTFS。应用只展示 NTFS 卷，但整盘安全判断也必须覆盖同盘 EFI
分区。若把 EFI 分区的 `unknownVolumeRole` 和缺少 `VolumeSnapshot` 一律解释为“同盘系统事实
不完整”，正常的 GPT + EFI + NTFS 组合也会被挡住；若直接忽略该分区，则会丢失整盘拓扑核对。
这里的 EFI 只能作为**已核对的结构性同盘分区**单独识别，不能当作普通数据卷、NTFS 写入目标，
也不能从它推断同盘 NTFS 是数据卷。后者仍需一次性的用户数据卷声明和 fresh 系统事实，见
[ADR 0005](../adr/0005-separate-observed-volume-from-data-declaration.md)、
[ADR 0010](../adr/0010-enable-writable-mount-in-formal-app.md) 与
[ADR 0011](../adr/0011-atomic-helper-enable-writing.md)。

## 一手系统事实

### EFI 的 GPT 类型必须与运行时内容分开

UEFI 2.11 的 [GPT 类型表](https://uefi.org/specs/UEFI/2.11/05_GUID_Partition_Table_Format.html)
将 EFI System Partition 的分区类型 GUID 定义为
`C12A7328-F81F-11D2-BA4B-00A0C93EC93B`。Apple 的
[GPT 解析器（固定提交）](https://github.com/apple-oss-distributions/IOStorageFamily/blob/7edb88fbae296fb7c8ce2f64e115e116e566d51c/IOGUIDPartitionScheme.cpp#L643-L703)
把 GPT 条目的 `ent_type` 格式化后传给分区 IOMedia 的 `contentHint`，并把另一字段
`ent_uuid` 写入 IOMedia UUID。二者是不同的 GUID：前者声明**分区类型**，后者标识
**分区表项**，均不声明 Windows/NTFS 数据角色。

Apple 的 [IOMedia 定义（固定提交）](https://github.com/apple-oss-distributions/IOStorageFamily/blob/7edb88fbae296fb7c8ce2f64e115e116e566d51c/IOMedia.h#L43-L73)
说明 `Content Hint` 在 IOMedia 对象创建时设置、该对象生命周期内不变；`Content` 则可能被
探测客户端覆盖。[Disk Arbitration 源码（固定提交）](https://github.com/apple-oss-distributions/DiskArbitration/blob/a542bda934211dc3c301bfdcc7f21349c4164a85/diskarbitrationd/DADisk.c#L367-L374)
直接把 IOMedia `Content` 放进 `kDADiskDescriptionMediaContentKey`。因此单独看到 DA
`MediaContent == EFI GUID` 不能证明它仍等于 GPT `ent_type`；应从该分区的 IOMedia 读取
`Content Hint`，并核对其 GPT 父节点、分区身份和同盘关系。EFI 卷名或 `diskXs1` 命名模式
也不能代替这些事实。[Apple Disk Arbitration 编程指南](https://developer.apple.com/library/archive/documentation/DriversKernelHardware/Conceptual/DiskArbitrationProgGuide/ManipulatingDisks/ManipulatingDisks.html)
允许通过 `DADiskCopyIOMedia` 读取 DA 字典之外的 I/O Registry 属性，并提醒各设备提供的
描述键集合不一定相同；[API 文档](https://developer.apple.com/documentation/diskarbitration/dadiskcopyiomedia%28_%3A%29)
要求调用方对返回的 IOMedia 引用执行 `IOObjectRelease`。

### MediaUUID、VolumeUUID 与 Registry Entry ID 不是同一个身份

Apple 的 [GPT 解析器（固定提交）](https://github.com/apple-oss-distributions/IOStorageFamily/blob/7edb88fbae296fb7c8ce2f64e115e116e566d51c/IOGUIDPartitionScheme.cpp#L696-L700)
把 `ent_uuid` 放进 IOMedia UUID；Disk Arbitration 又把该属性暴露为
[`MediaUUID`（固定提交）](https://github.com/apple-oss-distributions/DiskArbitration/blob/a542bda934211dc3c301bfdcc7f21349c4164a85/diskarbitrationd/DADisk.c#L512-L525)。
UEFI [GPT 规范](https://uefi.org/specs/UEFI/2.11/05_GUID_Partition_Table_Format.html)
要求复制 GPT 磁盘或分区的软件生成新的 GUID，否则重复 GUID 的结果不确定；因此此值不能
单独证明当前连接的物理介质实例。DA 的 `VolumeKind` 来自
文件系统探针，`VolumeUUID` 由同一探针单独返回；探针可不提供 UUID，因此 EFI 分区身份
不应依赖 `VolumeUUID`，更不能拿 `MediaUUID` 补 NTFS 文件系统 UUID。
来源：[Apple DA 探针阶段（固定提交）](https://github.com/apple-oss-distributions/DiskArbitration/blob/a542bda934211dc3c301bfdcc7f21349c4164a85/diskarbitrationd/DAStage.c#L708-L837)、
[ADR 0008](../adr/0008-supplement-candidate-identity-from-mounted-filesystem.md)。

Apple 的 [IORegistryEntryGetRegistryEntryID 文档](https://developer.apple.com/documentation/iokit/1514719-ioregistryentrygetregistryentryi)
定义 Registry Entry ID 为跨进程可识别**同一 I/O Registry 条目**的 ID，且只在本次系统启动
期间有效。因此它适合与实时 IOMedia 对象、GPT 父子关系和当前 BSD/DA 事实交叉核对；它
不是磁盘序列号、分区 UUID、文件系统 UUID、持久化授权，也不因数字相同就证明磁盘状态安全。
重新插拔或系统重启后必须重新枚举和核对，不能复用缓存的条目 ID 或 BSD 名。

## 2026-09-29 本机只读核对

仅使用只读 `diskutil list/info`、`DADiskCopyDescription` 与 `DADiskCopyIOMedia`/IORegistry
属性读取检查此前用于隔离写入实验的 U 盘，
没有执行挂载、卸载、推出或格式化。当前临时 BSD 名为 `disk6`，是约 124 GB 的外置 USB
GPT 物理盘；`disk6s1` 为约 209.7 MB 的 EFI/FAT32 分区，当前未挂载，DA `VolumeKind=msdos`，
`MediaContent` 为上述 EFI GUID；`disk6s2` 为约 124.4 GB 的 `NTFSLAB` NTFS 分区，当前由
macOS 只读挂载，`MediaContent` 为 Microsoft Basic Data GPT 类型 GUID
`EBD0A0A2-B9E5-4433-87C0-68B6B72699C7`。两者的 DA 父 BSD 名均为 `disk6`，
`DeviceInternal=false`，设备协议为 USB。DA 对 EFI 返回了 `VolumeUUID`，对 NTFS 则未返回
`VolumeUUID`；这再次说明两种 UUID 字段不能混用。`disk6` 与卷名只是当次显示和检查线索，
不构成跨重插身份。上述观察是一次性即时读取，未封存为独立 Gate 证据，也没有从这些读数
推断写入或整盘推出资格。此前可牺牲介质的写入实验记录见
[USB 本机结果](../../.scratch/write-delete-validation/USB-RESULT.md)。

后续同日只读核对确认：整盘 DA `MediaContent` 为 `GUID_partition_scheme`；EFI 与 NTFS
分区的 IOMedia `Content Hint` 分别匹配上述 EFI 和 Microsoft Basic Data GUID，且各自与
DA `MediaContent` 一致。三个 IOMedia 对象均能读取非零 `UInt64` Registry Entry ID，两个
分区均有 DA `MediaUUID`。另一次只读 IOService 父链核对发现两个分区最近的整盘 IOMedia
祖先均与当前 `disk6` 的 Registry Entry ID 一致。尚未做快速拔插的前后 ID 比对；这些事实
必须由正式 helper 在每次变更前重新核对。

## 识别和验证边界

- 结构性 EFI 判断应要求 GPT 父子关系、EFI 类型 `Content Hint`、有效分区 `MediaUUID`、
  当前完整的物理盘/分区身份、预期的 FAT 文件系统探针及**未挂载**事实相互一致；它只解决
  “同盘分区是什么”，不授权修改 EFI，也不把同盘 NTFS 升级为数据角色。DA `Content`
  若与这些事实矛盾，应失败关闭。
- 对整盘操作，目标和每个同盘分区均需 fresh 枚举并精确匹配；新增、缺失、重复、父子关系
  不符、未知类型、已挂载 EFI 或任何截断/超时均应阻止操作。App 展示阶段的识别不能代替
  helper 在变更前的再次读取。参见 [ADR 0005](../adr/0005-separate-observed-volume-from-data-declaration.md)
  与 [ADR 0011](../adr/0011-atomic-helper-enable-writing.md)。
- 未验证：快速拔插及跨进程对 Registry Entry ID/MediaUUID 的重新绑定；真实标准卸载与整盘
  推出后的完整消失证据；更复杂 GPT 拓扑和其他 macOS 版本；Windows 对 NTFS 写入结果的
  复核。这些都不能由本次只读检查或本文的一手 API 阅读替代，尤其不得用用户数据盘补测。
