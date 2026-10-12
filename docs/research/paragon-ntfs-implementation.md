# Paragon NTFS for Mac 实现依据

核对日期：2026-10-09。仅核对官方公开资料；未检查用户安装包、加载状态或磁盘，不改变项目依赖与安全策略。

## 已确认事实与版本范围

- Paragon 的旧版 NTFS for Mac 9 官方手册将产品描述为底层文件系统驱动，并明确说明基于其 UFSD（Universal File System Driver）技术，提供 NTFS 读写并供 macOS 应用透明访问。这是历史实现依据，不能单凭旧手册证明当前全部版本的内部架构。[官方手册，第 3 页](https://www.paragon-software.com/export/sites/paragonsoftware.com/docs/manual_ntfs-mac_9_eng.pdf)
- 官方安装知识库明确描述 KEXT-based 实现，并说明其内核扩展加载要求；但文章截图标识 15.10.485，标签为 `ntfs15`，因此本笔记将证据限定为该文档覆盖的版本，不推断所有新版本仍使用 KEXT。[官方安装说明](https://kb.paragon-software.com/article/4482)
- 官方 NTFS for Mac 15 挂载故障说明列出内核扩展路径 `/Library/Extensions/ufsd_NTFS.kext`，并列出后台组件 `com.paragon-software.ntfsd` 与 `com.paragon-software.ntfs.loader`。这些是版本 15 的公开组件证据，不代表本机存在或已加载。[官方版本 15 挂载故障说明](https://kb.paragon-software.com/article/4797)
- 当前产品页面提及版本 17；产品名称、兼容性或性能营销信息本身不能验证下载包究竟采用 KEXT、FSKit 还是其他架构。[当前官方产品页](https://www.paragon-software.com/home/ntfs-mac/)

## 解释与未验证项

基于上述历史证据，可将对应版本理解为由 Paragon 的 UFSD 驱动负责 NTFS 文件系统读写，管理界面及后台组件辅助管理驱动。这与本项目采用 NTFS-3G 加 macFUSE FSKit 的实现路线不同；不能把 Paragon 视作本项目依赖的替代安装包。该解释是对公开组件与手册的归纳，不是源代码审计。[UFSD 官方手册](https://www.paragon-software.com/export/sites/paragonsoftware.com/docs/manual_ntfs-mac_9_eng.pdf)、[版本 15 官方组件说明](https://kb.paragon-software.com/article/4797)

未验证：用户安装的具体版本与加载状态；版本 17 的二进制架构及依赖；闭源内部算法；实际吞吐、稳定性与数据一致性。未执行安装、卸载、挂载、推出或任何安全设置变更，也未照搬官方故障文档中的系统修改步骤。

## 实现路线比较（2026-10-09）

- macFUSE 官方后端文档把 FSKit 描述为 macOS 15.4 引入的用户态 API，并列出通知 API、上下文、挂载选项等限制，注明 FSKit I/O 性能尚不及其内核扩展后端。页面最后编辑时间为 2025-10-30，不能据此量化本项目固定版本与 Paragon 的速度差距。[官方后端文档](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)
- NTFS-3G 上游提供源码与许可证，支持 macOS；源码可检查和修改不等于 macFUSE 全部组件开放，也不自动证明本项目组合可靠。[上游仓库](https://github.com/tuxera/ntfs-3g)
- 工程建议：本项目继续固定 NTFS-3G + macFUSE FSKit，与 ADR 0010 的不使用内核扩展、不降低启动安全性及已有本机验证一致。该建议不批准依赖更新，不改变 Gate 状态，也不宣称数据一致性优于 Paragon。
- 未验证：同机同盘性能对比、Windows 复核、长期异常矩阵、Paragon SDK 的 macOS 接口与项目授权条件。自行从零实现 NTFS 或直接编写 FSKit 适配均是新路线，需要独立设计与验证；本次不实施。
