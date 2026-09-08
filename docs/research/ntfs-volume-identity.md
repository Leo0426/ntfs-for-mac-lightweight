# NTFS 卷 UUID 的公开来源与实物核对

证据日期：2026-09-08。范围：本机 macOS 26.6.2 (25G83)、arm64、用户授权的 USB-1。

## 已确认

Apple 的 [Disk Arbitration 指南](https://developer.apple.com/library/archive/documentation/DriversKernelHardware/Conceptual/DiskArbitrationProgGuide/ManipulatingDisks/ManipulatingDisks.html)
明确说明设备不保证提供相同的描述键集合。因此单个 DA UUID 键缺失本身不足以诊断介质损坏。

Foundation 的 [volumeUUIDString](https://developer.apple.com/documentation/foundation/urlresourcevalues/volumeuuidstring)
表示文件系统卷的持久 UUID，不可用时允许 nil；它与
[volumeIdentifier](https://developer.apple.com/documentation/foundation/urlresourcevalues/volumeidentifier)
不同，后者在本机 SDK 的 NSURL.h 注释中明确不跨系统重启持久。

Apple 发布的 [getattrlist 手册源码](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/getattrlist.2)
将 ATTR_VOL_UUID 定义为文件系统 UUID，fgetattrlist 针对已打开的文件描述符操作。
本机 SDK 的 sys/attr.h 定义返回掩码和数据布局；实现必须检查实际返回属性，而非仅相信系统调用
返回 0。生产代码只请求 RETURNED_ATTRS、VOL_INFO 与 VOL_UUID，不请求文件内容或时间戳。

本机 SDK：CommandLineTools 的 MacOSX.sdk；相关声明为 DADisk.h、NSURL.h、sys/attr.h 和
getattrlist(2)。DA 的 MediaUUID 与 VolumeUUID 是不同键，不能互换。

## USB-1 实测与推断边界

- DA VolumeUUID 与 diskutil VolumeUUID 缺失，分区/介质 UUID 存在。
- 新建 Foundation URL 并读取 volumeUUIDString，返回有效 36 字符 UUID。
- 以只读目录 FD 调用 fgetattrlist，返回长度 40 字节且明确包含 ATTR_VOL_UUID；UUID 与 Foundation
  一致，与 diskutil 分区 UUID 不同。保存的诊断只包含存在性、相等性与固定结果，不保存 UUID 值。
- 因此本机有可用的公开文件系统身份来源；DA 缺失不能推断为整个系统没有卷身份。
- 额外检查本机 APFS 系统快照根目录时，Foundation 与 ATTR_VOL_UUID 的值并不相同。因此不能
  把本次 NTFS 的跨接口一致性推广到其他文件系统；生产补充读取仅针对 NTFS。
- 未确定 DA 未返回该值的内部原因；未证明所有 macOS/NTFS 都有相同表现，也未证明克隆唯一性、
  跨重插稳定性、卸载后可用性或卷健康。旧 Apple NTFS kext 源码不代表本机 FSKit 实现。

## 本轮采用范围

见 [ADR 0008](../adr/0008-supplement-candidate-identity-from-mounted-filesystem.md)：生产使用 FD 绑定的
ATTR_VOL_UUID 补充已挂载、外置、用途未知 NTFS 候选。读取前后核对当前挂载对象，两次原生 UUID
相同才提供补充事实。原始 DA 字段保持不变，两来源冲突拒绝，不对卸载后的请求缓存补值。
这不解决未来写入前的未挂载身份读取，也不改变 Gate 1–3 的验收要求。
