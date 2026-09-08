# Apple 只读系统事实能否识别 Boot Camp 卷

检索日期：2026-08-31\
结论适用范围：macOS 26.5 SDK 的公开 Disk Arbitration / IOKit 接口，以及检索日可见的
Apple 开源实现和支持文档。

## 结论

没有找到 Apple 一手资料支持仅凭公开 Disk Arbitration 或 IOKit 只读事实，稳定区分
“Windows/Boot Camp 系统卷”和“普通 NTFS 数据卷”。公开事实可以证明介质是否位于内部设备、
分区/内容类型、文件系统类型和挂载状态；它们没有定义 Boot Camp 或 Windows system-role 字段。

因此当前生产映射只作以下保守声明：

- `kDADiskDescriptionDeviceInternalKey == true` 只映射为通用 `protected`，不声明精确
  `bootCamp` 身份；这是项目“内部卷受保护”的安全规则。
- 外部 NTFS 即使卷名是 `BOOTCAMP`，角色仍为 `unknown`，记录保持 incomplete，不生成可进入
  写入或整盘推出协调器的 `VolumeSnapshot`。
- `trustedData` 只作为类型化接口和纯测试夹具存在。当前 Disk Arbitration / IOKit 生产路径
  不会产生它；其可信来源必须由 Gate 1 后续 Apple 一手资料与专用测试盘证据另行建立。
- 缺失或相互矛盾的角色事实分别保持 `unknown` / `conflicting`，均失败关闭。

这意味着当前实现不能精确声称识别了 Boot Camp。它能声称的是：内部 NTFS 永远受保护；
外部 NTFS 在没有额外可信角色证据时不会被授权写入或整盘推出。

## 一手证据

### Disk Arbitration 没有公开 system-role 键

本机 macOS 26.5 SDK 的
`DiskArbitration.framework/Headers/DADisk.h` 声明了 volume kind/name/type、media content、
ejectable/removable/whole 和 device internal 等描述键，但没有 Boot Camp、Windows system role
或 protected-volume role 键。Apple 的公开
[Disk Arbitration constants](https://developer.apple.com/documentation/diskarbitration/diskarbitration-constants)
列表与该头文件一致。

`DeviceInternal` 可以稳定支持本项目的“内部介质一律受保护”规则，但 `false` 只表示设备不是内部介质，
不能反向证明其 NTFS 分区是普通数据卷。

### IOMedia content/hint 是内容类型，不是系统角色

本机 macOS 26.5 SDK 的 `IOKit.framework/Headers/storage/IOMedia.h` 对
`kIOMediaContentKey` 和 `kIOMediaContentHintKey` 的定义说明：它们是介质内容的描述/提示，
字符串形态类似 `Apple_HFS` 或 UUID；`Content` 还可能被探测客户端覆盖。
Apple 的公开 [IOMedia defines](https://developer.apple.com/documentation/iokit/iomedia_h_user-space/defines)
没有定义 Boot Camp 或 Windows system-role 属性。

这类键可以用于识别内容或分区类型，但文档没有赋予它们“系统卷”语义。

### MBR 的 NTFS 类型与 active 位不足以区分系统卷和数据卷

本机 SDK 的 `IOFDiskPartitionScheme.h` 定义 MBR `bootid` 为 active-boot 标记，并把分区类型
`0x07` 映射为 `Windows_NTFS`。Apple 开源实现
[IOFDiskPartitionScheme.cpp（固定提交）](https://github.com/apple-oss-distributions/IOStorageFamily/blob/7edb88fbae296fb7c8ce2f64e115e116e566d51c/IOFDiskPartitionScheme.cpp#L479-L595)
只用 `bootid` 检查分区表结构是否有效，并仅按 `systid` 查找 IOMedia content hint。
创建出的分区 IOMedia 没有附加 Windows system-role 或 Boot Camp 角色。

`Windows_NTFS` 同时适用于系统卷和数据卷；active 位也不是 Apple 文档定义的稳定 Boot Camp
身份。当前代码不得把二者组合成系统角色推断。

### GPT 类型 UUID、属性和名称也没有给出 Boot Camp 身份

本机 SDK 的 `IOGUIDPartitionScheme.h` 中，GPT 条目包含 type UUID、partition UUID、通用属性位
和 36 个 UTF-16 code unit 的名称。Apple 开源实现
[IOGUIDPartitionScheme.cpp（固定提交）](https://github.com/apple-oss-distributions/IOStorageFamily/blob/7edb88fbae296fb7c8ce2f64e115e116e566d51c/IOGUIDPartitionScheme.cpp#L628-L704)
把 `ent_type` 格式化成 IOMedia content hint，把 `ent_name` 单独设置为可显示名称，并原样暴露
GPT attributes；没有计算 Boot Camp 或 Windows system-role。

因此 GPT 类型只能说明分区类型，名称只是独立文本，通用属性也没有公开的 Boot Camp 角色语义。

### `BOOTCAMP` 是安装流程中的分区名称，不是可信身份字段

Apple 的
[使用 Boot Camp Assistant 安装 Windows 10](https://support.apple.com/en-us/102622)
要求在 Windows 安装器中选择并格式化名为 `BOOTCAMP` 的分区。该支持文档说明了安装流程中的名称，
却没有把这个名称定义为不可修改的身份或 Disk Arbitration / IOKit 角色事实。

所以卷名 `BOOTCAMP` 只能作为展示文字，不能参与授权判断；BSD 名同样只是设备标识，不能用模式
推导角色。

## 已验证与未验证边界

已验证：公开键集合、IOMedia content/hint 语义、Apple MBR/GPT 分区对象创建逻辑，以及 Boot Camp
安装流程对分区名称的使用。检索同时覆盖本机 SDK 头文件和 Apple 固定提交的开源实现。

未验证：不存在公开 API 之外的 Apple 私有 system-role 数据；也没有专用内部 Boot Camp、外部
Windows 系统盘和普通外部 NTFS 数据盘的 Gate 1 硬件对照。因而本笔记不证明“任何外部 NTFS
都是数据卷”，也不批准任何生产 `trustedData` 来源。
