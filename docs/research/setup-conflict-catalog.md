# Setup 冲突驱动精确目录与 Gate 2 候选范围

调研日期：2026-08-31\
证据范围：Apple 文档、厂商公开文档、厂商当前官方下载制品\
当前结论：候选目录可以按明确版本和制品闭合；不能据此宣称“已穷举全部商业 NTFS 驱动”

## 结论

1. 对 2026-08-31 取得的三个当前厂商制品，已确认以下精确 kext identifier：
   - Paragon：`com.paragon-software.filesystems.ntfs`
   - Tuxera：`com.tuxera.filesystems.tuxera_ntfs`
   - iBoysoft：`com.iboysoft.filesystems.ms_ntfs`
2. 这三个精确制品都包含传统 kext，没有发现现代 `.systemextension` 或 FSKit
   文件系统模块。因此，本候选范围的 system extension 和 FSKit **冲突** identifier
   集合为空；这不是对未来版本或其他厂商的全局断言。
3. Gate 2 不应以“全市场所有商业驱动均已穷举”为完成条件。可关闭的条件应改为：
   对一个具名、带日期、目标平台和制品摘要的候选范围，目录中的每个产品都已有精确
   identifier 与安装 footprint，且测试环境与该范围一致。
4. 调研当时的代码只检查已加载 kext 和已登记 system extension，因而无法发现已安装但
   尚未加载的厂商驱动。该软件缺口后由 Issue 18 的具名范围与只读 installed-footprint
   provider 关闭；仅凭 `kmutil showloaded --list-only` 无匹配项仍不能证明全局无冲突。
5. Issue 18 落地后，`SetupProbePolicy.current` 仍保持 `activeScope == nil` 且环境基线未批准。
   软件 scope/provider 完成不代表 Gate 2 通过；只有真实镜像环境、active scope 批准和全部
   证据同时满足才能产生完整 Setup 事实。

## 标识口径

Apple 将 system extension 的 `bundleIdentifier` 定义为扩展 bundle 的
`CFBundleIdentifier`。目录因此只记录扩展本体的精确 bundle identifier，不用应用名、
文件名、守护进程 label 或安装包 identifier 代替。[Apple System Extensions](https://developer.apple.com/documentation/systemextensions/ossystemextensionproperties/bundleidentifier)

Apple 的设备管理文档也把 system extension 和 kernel extension 的批准单位分别描述为
具名 extension 与 Team ID；Team ID 证明签名主体，但不是 extension identifier。
[System Extensions policy](https://support.apple.com/en-gb/guide/deployment/dep5d1584ca4/web)；
[Kernel Extension Policy](https://support.apple.com/en-gb/guide/deployment/dep88f99b98a/1/web/1.0)

本目录使用三类字段：

- **loaded identifier**：`systemextensionsctl` 或 `kmutil` 输出中用于匹配的 bundle identifier。
- **installed footprint**：厂商制品安装到的精确 bundle 路径及其 `CFBundleIdentifier`；用于发现
  “已安装、未加载”。
- **provenance**：制品 SHA-256、版本、Team ID 和 Code Directory hash；用于说明结论来自哪个
  厂商制品，不用作“没有冲突”的替代证明。

## 2026-08-31 精确候选目录

| 厂商候选 | kext 路径与 loaded identifier | 文件系统 bundle footprint | system extension | FSKit 模块 | 签名主体 |
|---|---|---|---|---|---|
| Paragon NTFS for Mac 17.0.488 | `/Library/Extensions/ufsd_NTFS.kext`；`com.paragon-software.filesystems.ntfs` | `/Library/Filesystems/ufsd_NTFS.fs`；`com.paragon-software.filesystems.ntfs.fsbundle` | 制品中未发现 | 制品中未发现 | `LSJ6YVK468` |
| Tuxera installer 2026.2.0；kext 2023.5.23 | `/Library/Filesystems/tuxera_ntfs.fs/Contents/Resources/Support/10.9/tuxera_ntfs.kext`；`com.tuxera.filesystems.tuxera_ntfs` | `/Library/Filesystems/tuxera_ntfs.fs`；`com.tuxera.filesystems.util.tuxera_ntfs` | 制品中未发现 | 制品中未发现 | `PPNVCC9Z68` |
| iBoysoft NTFS for Mac 8.0；driver 4.5 | `/Library/Extensions/ms_ntfs.kext`；`com.iboysoft.filesystems.ms_ntfs` | `/Library/Filesystems/iboysoft_NTFS.fs`；`com.iboysoft.filesystems.util.ntfs` | 制品中未发现 | 制品中未发现 | `EY7538DH4K` |

“未发现”只表示完整枚举下表固定制品的 payload 后，没有 `.systemextension` 或 FSKit
模块；厂商替换制品、版本升级或运行期另行下载组件时，必须重新核验。

### Paragon

Paragon 当前产品页把 NTFS for Mac 17 列为当前产品。2026-08-31 从其官方试用下载链接
取得的制品中，安装器版本为 `17.0.488`；flat package 的 `PackageInfo` 和实际 kext
`Info.plist` 都给出 `com.paragon-software.filesystems.ntfs`，签名 Team ID 为
`LSJ6YVK468`。[产品页](https://www.paragon-software.com/home/ntfs-mac/)；
[官方制品](https://dl.paragon-software.com/demo/ntfsmac17_trial.dmg)

- 原始 DMG SHA-256：
  `2934127f75fb79b7be7c1b890320d7a67bfa34d56e58cf3460c15b086a75dc16`
- kext `CFBundleShortVersionString`：`17.0.488`
- kext Code Directory hash：`f58c286a764be51ade3910a568a2505f1a10afa4`
- 签名时间：2026-01-31

这也更新了早期证据边界：旧知识库已公开同一个 identifier，但页面标注 NTFS for Mac
14；当前官方 17.0.488 制品现在提供了版本内的直接证据。
[Paragon 旧版知识库](https://kb.paragon-software.com/article/2883)

`com.paragon-software.ntfsd` 与 `com.paragon-software.ntfs.loader` 是服务 label，
不是 kext identifier，不能加入 kext 冲突集合。Paragon 自己的安装与排障文档同时给出
kext 路径、服务 label 和 Team ID，可验证这些概念必须分开。
[安装文档](https://kb.paragon-software.com/article/4482)；
[排障文档](https://kb.paragon-software.com/article/4797)

### Tuxera

Tuxera 2026-04-08 更新的部署文档明确说明其驱动安装到 `/Library/Filesystems`，公开
Team ID `PPNVCC9Z68` 和 kext 精确路径。该页的厂商附件还直接显示
`com.tuxera.filesystems.tuxera_ntfs (2023.5.23)`。
[部署文档](https://macsupport.tuxera.com/hc/en-gb/articles/360021071460-How-do-I-license-and-deploy-NTFS-for-Mac-in-an-organization-or-for-multiple-users)；
[官方 kextstat 附件](https://macsupport.tuxera.com/hc/article_attachments/10684571855260)

2026-08-31 下载的当前官方 DMG 中，安装器版本为 `2026.2.0`，三个兼容目录里的
`tuxera_ntfs.kext` 都使用上述 identifier；10.9 目录 kext 的签名 Team ID 也是
`PPNVCC9Z68`。[产品页](https://ntfsformac.tuxera.com/)；
[官方制品](https://download.tuxera.com/mac/tuxerantfs_latest.dmg)

- 原始 DMG SHA-256：
  `3da0a23ca7e297f5ff9be8ea772dfb15977b3b7b1f6072620466a5dfd174c61a`
- 安装器版本：`2026.2.0`；kext 版本：`2023.5.23`
- 10.9 kext Code Directory hash：`e9b4eed21e466fe1c948d1c4632c5ac83ee9ddb9`
- 签名时间：2026-08-06

Tuxera 的卸载文档把 2018 至当前版本的 filesystem bundle 路径固定为
`/Library/Filesystems/tuxera_ntfs.fs`，并另列旧版 `fusefs_txantfs.fs`。本轮没有取得旧版
kext 的当前一手 identifier，因此旧版只作为**范围外已知 footprint**：发现它时应阻止或
要求人工清理，不能猜测其 loaded identifier。
[Tuxera 卸载文档](https://macsupport.tuxera.com/hc/en-gb/articles/360021236379-How-to-uninstall-NTFS-for-Mac-using-the-provided-command-line-script)

### iBoysoft

iBoysoft 当前产品页列出 V8.0；在线帮助公开两个安装 footprint：
`/Library/Filesystems/iboysoft_NTFS.fs` 与 `/Library/Extensions/ms_ntfs.kext`。
[产品页](https://iboysoft.com/ntfs-for-mac/)；
[在线帮助](https://iboysoft.com/ntfs-for-mac/online-help.html)

2026-08-31 取得的官方 V8.0 制品包含嵌套 `kext-installer.pkg`。其中签名 kext 的
`CFBundleIdentifier` 是 `com.iboysoft.filesystems.ms_ntfs`，版本是 `4.5`，签名
Team ID 为 `EY7538DH4K`。这使精确 identifier 不再是未知项。
[官方制品](https://download.iboysoft.com/download/downloadfile.php?d=notrial_product&p=ntfsformac)

- 原始下载 ZIP SHA-256：
  `f327aa8a023295377c75dbf695c3975236d74a4070e661bed4e08d2cfe38f2c9`
- ZIP 内 DMG SHA-256：
  `f8266f255094c5b3fe4d3fd58db82a7c24e0fb3fe51a67579594fed22d3d9b5a`
- 嵌套 `kext-installer.pkg` SHA-256：
  `99c3b48d7563b6d482a58c7bf2e74d5a0abac99902264f8c2b0f61840cc32fa5`
- kext Code Directory hash：`7feadca9bdcf3369e519b67c4901c8a660d0c50c`
- 签名时间：2025-07-24

iBoysoft 文档把 UI 文案写成 “System Extension”，但其 Apple Silicon 指南实际要求
Reduced Security 并允许 kernel extensions；当前制品也确实包含 kext，而非现代
`.systemextension`。因此不能从营销或 UI 文案反推出 system extension identifier。
[Apple Silicon 指南](https://iboysoft.com/howto/enable-system-extension-m1-mac.html)

## 可关闭的 Gate 2 候选范围

建议建立具名记录：

`gate2-macos15.4-arm64-commercial-conflicts-2026-08-31`

它只表达下列命题：

> 在 macOS 15.4.0、Apple Silicon 的 Gate 2 一次性镜像测试环境中，针对上表三个精确
> 厂商制品及 Tuxera 已公开的旧版 footprint，Setup 能可靠发现已加载或已安装的已知冲突；
> 环境若不满足范围或证据不完整，保持未就绪。

候选范围只有同时满足以下条件才可标记为完整：

1. 记录范围 ID、证据日期、目标 macOS/架构、厂商产品版本、原始制品 URL 与 SHA-256。
2. 每个范围内制品都有精确 kext、system extension、FSKit 三类结论；空集合必须来自完整
   payload 枚举，不能来自“网页没写”。
3. loaded scan 的命令成功、输出未截断、所有记录都能严格解析；任一异常失败关闭。
4. installed footprint scan 对每个精确绝对路径返回三态之一：
   - `absent`：逐层无符号链接检查后确认不存在；
   - `presentConflict`：存在并命中预期 bundle identifier，或该路径存在任何其他内容；
   - `incomplete`：权限、竞态、符号链接、类型、读取、签名或元数据无法确认。
5. Gate 2 测试机有一份具名环境基线：未安装范围外 NTFS 工具；若发现旧版
   `fusefs_txantfs.fs`、不明 NTFS 工具或用户声明与基线不符，则为 `scopeMismatch`，不得把
   “目录内无匹配”显示成“没有其他 NTFS 驱动”。
6. 任一厂商 URL 返回不同 SHA-256、版本变化、安装路径变化、目标 macOS/架构变化，或出现
   新 extension 类型时，自动使该候选记录过期并重新调研。

这一定义避免两个极端：既不要求穷举全市场，也不把三个 allowlist 没命中误报为系统全局安全。
UI 只能显示“已检查 Gate 2 候选范围”，不能显示“未安装任何其他 NTFS 驱动”。

## 实现状态（2026-08-31）

上述调研当时发现的软件缺口已由
[`Issue 18`](../../.scratch/ntfs-mvp/issues/18-candidate-scoped-conflict-footprint-probe.md)
关闭：

- `ConflictCatalogScope` 已绑定 scope ID、目标 macOS/架构、证据日期、三个候选制品的
  版本与 SHA-256、精确 loaded identifier 和固定 installed footprint。
- Paragon、Tuxera 与 iBoysoft 的三个精确 kext identifier 均已进入候选范围；
  filesystem bundle ID、package ID、service label 与 Team ID 没有混入 loaded identifier。
- 只读 footprint provider 不使用 `Process`，逐层使用 `openat` 与 `O_NOFOLLOW`，区分
  `absent`、`presentConflict` 与 `incomplete`；符号链接、权限、类型、竞态或元数据异常均失败关闭。
- Setup 只有在 active scope 与 candidate scope 精确一致、目标平台匹配、环境基线满足，
  且 loaded/footprint 两类扫描都完整时才会产生完整事实。

`SetupProbePolicy.current` 仍保持 `activeScope == nil` 且环境基线未批准，因此生产状态
继续失败关闭。Gate 2 的具名镜像环境、真实授权、固定依赖批准和 adapter 证据仍未取得；
本文不宣称 Gate 2 已通过。

## 本轮验证边界

- 只下载厂商公开制品并做离线、只读的镜像/归档/plist/代码签名元数据检查。
- 没有 attach 或 mount 任一 DMG，没有打开安装器，没有执行 package script，没有安装、加载或
  卸载任何 kext/system extension，也没有改变启动安全、SIP 或磁盘状态。
- 制品 URL 中的 `latest` 或动态下载端点可能被厂商原地替换；本文的 SHA-256 是使本次结论可复核
  的必要边界，不是未来版本的自动批准。
