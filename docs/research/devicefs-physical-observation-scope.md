# DeviceFS 与物理介质观察范围

研究日期：2026-10-09。只读研究；未挂载、卸载、推出或改变系统状态。
本地 SDK：`macosx27.0`。Apple DiskArbitration 公开源固定于
`a542bda934211dc3c301bfdcc7f21349c4164a85`（公开提交日期 2025-10-16），
不能据此宣称与当前 macOS 的私有实现逐字相同。

## 结论

保留 match-all DA 回调及独立 IOKit 全量覆盖核对。允许的改进是：在 source 边界为
**具名 DeviceFS 挂载对象**收集额外只读证据，证明它不属于当前 IOMedia inventory，
然后显式标为范围外事件。不得按缺少 BSD、路径位置、`devicefs` 类型或
`DADiskCopyIOMedia == IO_OBJECT_NULL` 中任何一项单独排除。

当前已报告事件的 BSD、父盘、whole、internal、registry ID 均缺失，
filesystem=devicefs、VolumeNetwork=false、mountPoint 位于 CoreDevice/DeviceFS。
这些 DA 描述**不足以排除**；真实完整稳定挂载表及其来源核对仍待采集。
这是范围判断，不产生可信卷快照、变更资格或 Gate 通过结论。

## 一手 API 与公开源证据

1. SDK `DiskArbitration.h` 将 MatchMediaUnformatted 描述为未格式化介质匹配，
   将 MatchVolumeMountable 描述为可挂载卷匹配。官方源码对应分别只设置
   `MediaSize=0`、`VolumeMountable=true`。前者遗漏普通卷，后者不能证明物理介质；
   MatchMediaWhole 也只覆盖 whole 对象，不能代替完整卷回调。
   [Apple 常量源码](https://github.com/apple-oss-distributions/DiskArbitration/blob/a542bda934211dc3c301bfdcc7f21349c4164a85/DiskArbitration/DiskArbitration.c#L93)
   与 [Apple API 文档](https://developer.apple.com/documentation/diskarbitration/kdadiskdescriptionmatchvolumemountable)。

2. daemon 的 `DADiskCreateFromVolumePath` 从 statfs 挂载对象创建 DA 对象：写入卷路径、
   类型、mountable=true；`VolumeNetwork` 来自 MNT_LOCAL 的反值。因此本地挂载的
   非 IOMedia 文件系统仍可能得到 network=false 和 mountable=true。
   该构造过程还从 fsid 写入 BSD major/minor；不能把 major/minor 的存在单独当物理身份证明。
   [Apple daemon 源码](https://github.com/apple-oss-distributions/DiskArbitration/blob/a542bda934211dc3c301bfdcc7f21349c4164a85/diskarbitrationd/DADisk.c#L985)。

3. SDK `DADisk.h` 将 DADiskCopyIOMedia 定义为获取该 DA 对象的 IOKit media，返回对象
   必须 IOObjectRelease。公开实现仅在内部 `_device` 存在时按 BSD 名查找服务；
   找不到服务也返回空。客户端 `_device` 仅在 DA ID 以 `/dev/` 开头时建立。
   因此空结果只能作为组合证据中的一项，不能区分无介质、查找失败或消失竞态。
   [Apple 客户端源码](https://github.com/apple-oss-distributions/DiskArbitration/blob/a542bda934211dc3c301bfdcc7f21349c4164a85/DiskArbitration/DADisk.c#L125)
   与 [Apple API 文档](https://developer.apple.com/documentation/diskarbitration/dadiskcopyiomedia(_:))。

4. `_DAVolumeCopyID` 对非 `/dev/` 来源使用挂载点与 owner 形成 ID；但 `lifs`
   有特殊设备解析分支。非 `/dev/` 字符串不是通用非物理文件系统契约，更不能排除全部
   FSKit/FUSE/URL 来源。该函数是内部源码，只用于解释行为，不应调用私有 API。
   [Apple ID 源码](https://github.com/apple-oss-distributions/DiskArbitration/blob/a542bda934211dc3c301bfdcc7f21349c4164a85/diskarbitrationd/DAInternal.c#L563)。

5. statfs 提供 fsid、数值 filesystem type、flags、filesystem type name、挂载点和来源。
   这些字段可用于前后挂载对象核对；固定长数组必须有 NUL 边界且完整解码，截断不得视为
   合法来源。fsid 是文件系统标识，不是本项目的物理盘实例身份。
   [Apple XNU 结构定义](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/mount.h#L104)。

6. Apple Xcode 27 Release Notes 明确提到 Device Hub 的 DeviceFS 功能，但未给出
   `devicefs` 的 IOMedia 身份、mount source 格式或永久非物理分类 API 契约。
   因而不能把名称与产品功能关联升级成安全事实。
   [Apple 发布说明](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)。

## 建议的有限范围规则（工程推论）

以下是由上述机制与仓库失败关闭约束推导的建议，不是 Apple 对 DeviceFS 的安全保证。

- 保留明确网络卷的现有分类；devicefs 分支严格解码为 network=false，未知/错类型继续失败关闭。
- 仅考虑 DA type 精确等于 `devicefs`、具名 canonical 本地挂载点的事件。
  不按路径前缀承诺 Apple 所有权；不排除任意其他未知本地文件系统。
- BSD 名（getter 与描述）、物理父盘、whole/internal 物理描述、media registry identity
  任何存在或矛盾都拒绝该分支。CopyIOMedia 非空也拒绝，并释放取得的对象。
  缺失字段应与类型错误分开；错误类型不能作为“无物理身份”。
- 获取连续两次完整且一致的真实挂载表，精确 mountPoint 只允许一个条目；该条目必须
  type=devicefs、完整来源、canonical 路径。拒绝 `/dev/`、BSD block/raw device 路径及
  可解析物理 disk URL；若采用具名 CoreDevice 来源模板，应根据**本机采集事实**绑定有限
  格式，不凭搜索结果硬编码或接受任意非 `/dev/` 来源。
- statfs 对该 mountPoint 的前后结果必须与挂载表的 fsid/type/typeName/source/mountPoint/flags
  一致；父目录所属 APFS 不能被当作 DeviceFS 证据。优先对打开的目录描述符进行 fstatfs
  并核对路径重新读取结果，避免挂载点替换。任何失败、变化、截断和矛盾均不排除。
- 分类只在当前回调与当前订阅中有效。范围外事件不写入物理 DA inventory，不污染
  unidentified latch；不要把过去未知事件永久 latch 直接清除为安全，也不跨重订阅缓存排除。
  disappear 期间挂载表已不存在时，不可猜测当前事件安全；若需要承接已证明的范围外对象，
  须明确对象身份与生命周期契约，否则失败关闭。
- 独立 IOMedia 枚举与物理 DA BSD 集合精确相等的覆盖规则保持不变。如果错误排除事件
  隐藏了实际 IOMedia，该核对仍须失败；不能为 DeviceFS 将 IOKit 集合补齐或跳过核对。

## 未验证项与验证边界

- 本研究没有直接读取本机 DeviceFS 的 statfs/source；当前事件仅来自任务提供的记录。
  完整来源、fsid、MNT_LOCAL、descriptor 可读性以及新旧回调顺序均待只读采集验证。
- 未找到 Apple 对 DeviceFS 非 IOMedia 身份的稳定公开 API 契约。范围规则需要具名实测证据，
  不能扩大为所有 synthetic/local/FSKit 文件系统的通用 allowlist。
- 公开 DA 源码不是 macOS 27 私有二进制证明；需支持平台的只读 smoke 验证。
- 实现需测试完整组合通过、物理 BSD/IORegistry 冲突、空挂载表、重复挂载点、来源为设备、
  截断、读失败、前后变化、unknown 字段与未知其他文件系统均失败关闭；真实物理事件仍保留。
- 本次仅交付研究笔记，未改代码，未运行 Release 构建，不构成运行时修复或实盘验证。
