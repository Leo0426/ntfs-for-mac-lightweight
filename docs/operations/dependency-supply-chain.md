# 依赖供应链记录

更新时间：2026-09-08（依赖版本复查；macFUSE 5.4.0 已发布但仍为 **pre-release**，
版本监视触发器未满足，无新可批准版本）

## 当前批准状态

当前没有任何依赖被批准进入真实磁盘变更路径。正式 App 因此保持 macFUSE/NTFS-3G 信任
策略为空、授权未知、冲突 `activeScope` 未批准且环境基线未实证；Setup 显示未就绪是
预期安全结果。候选 scope 与 installed-footprint provider 的软件实现已完成，但不等于批准。

代码侧现状（2026-09-08 复查，无变化）：`SetupProbePolicy.current` 仍为
`activeScope == nil`、`environmentBaselineSatisfied == false`；`TrustedBundleVersionReader`
与 `TrustedNTFS3GArtifactResolver` 的生产 policy 仍为空/未注入。这是正确的失败关闭结果，
在取得 Gate 2 镜像证据前不得填入任何 `activeScope`、`approvedVersions` 或哈希目录。
macFUSE 5.4.0 虽已在源码层包含 #1181 / #1187 / #1188 的修复，但仍是 pre-release，
不改变上述任何一项。

macFUSE 可信读取器已强制“精确版本 → 唯一签名策略”目录；目录键必须与 allowlist 完全一致，
每个版本的 requirement、Team Identifier、Code Directory 二进制标识与同一 `SecStaticCode` 的
secured Info.plist identifier/version 共同核对。未知更新、跨版本 identity 复用或产物漂移都失败关闭。
这只是核对能力，不是生产批准；正式策略的批准值和 Gate 2 镜像证据仍为空。
Security framework 的一手来源依据、实现边界和未验证项见
[`docs/research/macos-code-signing-evidence.md`](../research/macos-code-signing-evidence.md)。

| 依赖 | 调研候选 | 状态 | 阻塞原因 |
|---|---|---|---|
| macFUSE | 5.4.0（2026-09-07，**pre-release**）；5.3.3（2026-07-04）仍是官方 latest 稳定版 | unapproved-candidate | 5.4.0 release note 已确认 FSKit 数据面回归 #1181 / #1187 / #1188 的修复包含在本版，但它仍标记为 pre-release，不满足版本监视触发器；另有 #1180（sshfs 卸载残留）仍 open。DMG 内 FSKit 模块的代码签名 identity 未核对，也无镜像矩阵证据。5.3.3 作为唯一稳定版仍带这三项回归，继续 rejected-for-production。 |
| NTFS-3G | 2026.7.7（2026-07-15 安全发布） | unapproved-candidate | 已固定上游源码归档 URL 与 SHA-256/SHA-512（见下），但尚未固定本项目构建工具链、构建参数、最终产物摘要与字节数，也没有 macFUSE FSKit 后端下的兼容与卸载证据。 |

候选事实和一手来源见[`docs/research/ntfs-for-mac-landscape.md`](../research/ntfs-for-mac-landscape.md)。
“最低版本”只用于纯逻辑兼容检查，不能替代精确批准目录。

### 2026-09-01 候选制品出处快照

只做在线元数据只读核对（GitHub Releases API、上游 release note）；没有下载 DMG、没有
mount、没有安装或加载任何组件，也没有核对 DMG 内代码签名 identity。

**macFUSE 5.3.3**（[releases](https://github.com/macfuse/macfuse/releases/tag/macfuse-5.3.3)）

- 官方 `latest`，发布 2026-07-04，非 pre-release；5.3.0–5.3.2 均标记 pre-release。
- `macfuse-5.3.3.dmg`：15,802,030 字节，SHA-256
  `7a0b7b66c0e7f8932707d1215dc9cf486e178d097ae0a2dcdf17d8530566aa15`
- `macfuse-5.3.3-debug.tbz`：SHA-256
  `057c58c16a7a1610acfd379a5d79aada17143262c4d1c69c64b4083946a32baf`
- release note 含 FSKit 相关生命周期改进（延迟真正 mount 到首次会话、`fuse_daemonize()`
  不再 fork、信号处理改走正常 unmount 路径、多线程 teardown 先中断 `MFChannel`）；
  但 #1181（FSKit 挂载上 `exec()` 返回 EIO 直到文件被读过一次，closed 2026-08-30）与
  #1188（对非零 READ 回 0 字节的合法短读使模块扩展崩溃、整卷丢失，closed 2026-08-10）
  的 milestone 均为 **5.4.0**，当前 releases 列表无 5.4.0。
- 待核对（Gate 2）：DMG 内 FSKit 模块（`io.macfuse.app.fsmodule.macfuse-local`、
  `io.macfuse.app.fsmodule.macfuse`）与安装组件的 Team ID、指定需求、Code Directory
  identity 和 secured Info.plist identifier/version；本轮未取得。

**NTFS-3G 2026.7.7**（[release](https://github.com/tuxera/ntfs-3g/releases/tag/2026.7.7)）

- 官方 `latest`，发布 2026-07-15，非 pre-release；上一稳定功能发布为 2026.2.25（2026-04-21）。
- 源码归档：`https://tuxera.com/opensource/ntfs-3g_ntfsprogs-2026.7.7.tgz`
  - SHA-256 `d67b769025d32860549d35c2147e45024d172f81c540d750390ce3602c059dab`
  - SHA-512 `5b0a866c3c556f97b1c712fd09b148ecfd194429620e1b45f0630f6b4dee6a087496ff9bbe36bfa1a3e7c58483c43d45bb1e03956e0386aebe8b66522d90cdc2`
- git tag `2026.7.7` → commit `d327833ec1d5eb1358b6f2c37139f10a3460944d`
- 内容为安全发布，修复 9 项处理恶意/损坏文件系统时的堆破坏、越界读、缓冲区溢出
  （CVE-2026-42616/42617/42618/46569/46570/46571/46572/56135/56136）。再次印证 NTFS
  元数据必须作为不可信输入，模糊测试与崩溃隔离是长期维护项。
- 待固定（Gate 2）：本项目采用的构建工具链与参数、最终 `ntfs-3g` 可执行文件 SHA-256
  与字节数、“哈希 → 语义版本”目录、以及“用户独立安装 vs. 本地自建”的决定。

### 2026-09-08 候选制品出处快照

只做在线元数据只读核对（GitHub Releases API、上游 release note、issue 状态）；没有下载
DMG、没有 mount、没有安装或加载任何组件，也没有核对 DMG 内代码签名 identity。

**macFUSE 5.4.0**（[releases](https://github.com/macfuse/macfuse/releases/tag/macfuse-5.4.0)）

- 发布 2026-09-07T12:48:34Z，**`prerelease = true`**；官方 `latest` 仍为 5.3.3（非 pre-release）。
  `target_commitish = release/macfuse`。
- 资产（摘要为 GitHub Releases API 提供的 asset digest，本轮未下载核对）：
  - `macfuse-5.4.0.dmg`：16,512,456 字节，SHA-256
    `861814f0ac7fa8f6547ea40cdd49a36ac84bcc7d34f38a1fa74e8cf68b0401c5`
  - `macfuse-5.4.0-debug.tbz`：40,795,301 字节，SHA-256
    `315fa8d7d483960478605252eaa722010daf6e0605bede3c5c10dd5affb9e3f9`
  - `macfuse-5.4.0.sha256`：262 字节，SHA-256
    `33101b5993f5c10c2ca74f5a44f05297c47ed6e3d63966b92f4c67c78f55c689`
  - `macfuse-5.4.0.sha256.sig`：594 字节（对上面 `.sha256` 的分离签名）
- release note「`FSModule`（`FSKit` Backend）」明确列出并归属以下修复：
  - #1188（对非零 READ 回 0 字节的合法短读崩溃模块扩展、整卷丢失）— closed 2026-08-10，milestone 5.4.0。
  - #1187（1–14 字节的 `write(2)` 到达时被零填充、静默数据损坏）— closed 2026-08-25，milestone 5.4.0。**这是本项目之前未单独记录的第三项 FSKit 数据面回归。**
  - #1181（FSKit 挂载上 `exec()` 返回 EIO 直到文件被读过一次）— closed 2026-08-30，milestone 5.4.0。
  - 另含 #1178（libfuse/libfuse3 daemonize 父进程等待并回报挂载结果）、#1190、#1191 等。
- 其他与本项目相关的变化：FSKit 后端改用 Xcode 27.0 / macOS 27 SDK 构建，新增 macOS 27
  FSKit 卷操作 API（保留对更早 macOS 的兼容），新增基于服务端超时的属性缓存；
  `MFMount.framework` 移除对 AppKit 的直接依赖、加入含简/繁中文在内的本地化，并声明其
  API「未来版本仍可能变化」。
- #1180（sshfs 卸载残留，5.3.3 引入的回归）仍 **open**、无 milestone；不是 NTFS-3G 直接
  复现，但同属 libfuse/macFUSE 生命周期路径，Gate 2/3 必须单独验证退出、卸载与残留清理。
- 待核对（Gate 2）：DMG 内 FSKit 模块（`io.macfuse.app.fsmodule.macfuse-local`、
  `io.macfuse.app.fsmodule.macfuse`）与安装组件的 Team ID、指定需求、Code Directory
  identity 和 secured Info.plist identifier/version；本轮未取得。

**NTFS-3G**：无变化，官方 `latest` 仍为 2026.7.7（2026-07-15），摘要与出处见上一节。

### 版本监视触发器

在以下任一情况出现前，Gate 2 的依赖批准无法推进，应保持本记录与 Setup 失败关闭不变：

- macFUSE 发布 **5.4.0 或更新的正式版**（非 pre-release），且 release note 确认 #1181、
  #1187、#1188 已包含在该版本中。届时把它作为**新的精确候选**重新走出处核对、DMG
  代码签名 identity 核对和 Gate 2 镜像矩阵，不因版本号更高自动接受。
  **当前状态（2026-09-08）：5.4.0 已发布但 `prerelease = true`，release note 已确认三项
  修复；触发器仍未满足，等 5.4.0（或更新版）去掉 pre-release 标记后再推进。**
- NTFS-3G 发布新版：同样新建独立候选记录。
- 上述任一制品 URL 返回不同摘要 / 版本 / 安装路径，或出现新的 extension 类型。

## 每个批准条目的必填字段

- 项目、精确版本、上游发布页和源码归档 URL。
- 源码归档 SHA-256、构建工具链、构建参数、产物 SHA-256 和字节数。
- 许可证及本项目采用“用户独立安装”还是“本地自建”的决定。
- macOS/架构、FSKit 标识、bundle identifier、Team ID、指定需求、Code Directory identity、
  同一 `SecStaticCode` secured Info.plist identifier/version 及权限要求；必须记在所选精确版本
  的同一批准条目中。
- 运行时 trust policy 如何固定上述精确版本、身份和摘要，以及对应的失败关闭 fixture。
- Gate 2 镜像证据编号、批准日期、批准人和停止条件。
- 上一个批准版本、回滚步骤与回滚后重新验证项。

任何字段缺失、摘要不一致、来源变化或版本超出目录时，`SystemSetupReport` 必须返回
`notConfigured` 或 `failedClosed`，不能自动接受“更新版本”。

“最低版本”只用于解释兼容下限。只有版本、身份与摘要全部出现在同一批准条目且运行时核对
一致时，才能形成 Dependency Trust Evidence；版本号更高不能替代新的候选记录和 Gate 证据。

## 升级与回滚

1. 新版本先建立独立候选记录，旧批准目录保持不变。
2. 重新完成可信读取、镜像内容/卸载/异常矩阵和 Windows 复核。
3. 只有证据通过后才原子替换批准目录；不得同时接受未知旧版和新版。
4. 回滚时恢复上一份完整目录和对应制品，不只改显示版本。
5. 回滚后重新检查 Setup、只读边界和镜像生命周期；任何失败继续保持只读。
