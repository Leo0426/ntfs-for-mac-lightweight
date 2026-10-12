# NTFS for Mac Lightweight

个人自用的轻量 macOS NTFS 助手，使用 SwiftUI、NTFS-3G 和 macFUSE FSKit。支持识别外置 NTFS 卷、手动启用写入、标准卸载与安全推出，并提供运行环境检查和脱敏诊断。

## 当前状态

0.1.18（19）已通过本机 Release 检查及可牺牲 U 盘的写入、读回、删除和整盘推出验证。Windows 复核、长期稳定性、完整异常矩阵及人工 UI 验收仍未完成，暂用于实验性个人使用。

操作前由签名特权 helper 重新核对磁盘身份、健康和挂载条件；未知或矛盾事实停止操作。重要数据请先备份，开发测试仅使用一次性镜像或已授权的可牺牲磁盘。不提供强制卸载、自动恢复、内核扩展回退或降低系统安全性的方案。

## 构建与安装

需要 Apple Silicon、macOS 15.4 或更高版本、Swift 工具链、本机 Apple Development 签名身份，以及脚本固定摘要的 NTFS-3G 制品。依赖准备见[供应链记录](docs/operations/dependency-supply-chain.md)；实际写入另需已配置的 macFUSE FSKit。

完整本机检查与安装包构建：

```sh
scripts/check-release.sh
```

首次安装（管理员授权）：

```sh
scripts/install-local-installer.sh
scripts/verify-protected-install.sh
open /Library/PrivilegedHelperTools/NTFSLite.app
```

安装后在“运行环境”页注册帮助程序，并按系统提示批准。安装脚本拒绝覆盖已有目标；更新与卸载边界见 [ADR 0012](docs/adr/0012-protected-local-install-and-live-helper-check.md)。本机包尚不是 Developer ID 签名或公证的分发制品。

仅进行开发检查可运行 `scripts/check.sh`。`.build/NTFSLite.app` 用于构建和界面检查，真实磁盘操作须使用受保护安装件。

## 文档

- [本机验证与剩余限制](docs/release/local-validation.md)
- [Gate 定义与当前状态](docs/engineering/implementation-plan.md)
- [未完成验收](.scratch/ntfs-mvp/MAP.md)
- [Gate 验证手册](docs/operations/gate-validation-runbook.md)
- [领域模型](CONTEXT.md) · [架构决策](docs/adr/README.md)
- [产品范围](docs/product/mvp-prd.md) · [UI 指南](docs/design/ui-guidelines.md)
- [开发约定](AGENTS.md)

正式应用与 helper 位于 `Sources/`，回归检查位于 `Tests/` 和 `scripts/`。临时排查日志、快照及本机制品保留本地。
