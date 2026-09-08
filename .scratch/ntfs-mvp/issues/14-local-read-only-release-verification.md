# 强化本地只读 App 结构与平台校验

Status: resolved
Labels: bug, resolved
Assignee:
Blocked-by:

## 问题

创建本 Issue 时，脚本能验证主程序、Info.plist、arm64 和 ad-hoc 签名，但“单一主程序”计数
不会发现额外符号链接或其他特殊文件，最低系统版本也只读取 Info.plist，未与 Mach-O load
command 核对。

## 验收

- App 包内任何未批准的符号链接、特殊文件、额外可执行入口或 helper/插件/XPC 目录均失败。
- Mach-O 架构和 deployment target 与 arm64、macOS 15.4 策略及 Info.plist 一致。
- 负向 fixture 覆盖额外符号链接、额外普通可执行文件、错误 deployment target 和声明不一致。
- 验证输出继续报告主程序与 Info.plist SHA-256，并明确 ad-hoc 签名不等于 Gate 5。
- 不安装 App、helper 或依赖，不改变磁盘状态。

## Resolution

2026-08-31：本地验证脚本改为固定 `Contents`/`MacOS` allowlist，拒绝任何符号链接和额外
入口，并用 Mach-O `LC_BUILD_VERSION` 核对 macOS 平台及与 Info.plist 一致的 15.4 deployment
target；非目录、非普通文件也在签名检查前显式失败关闭。

新增 `scripts/check-local-read-only-app-negative-fixtures.sh`，在自动清理的 `mktemp` 目录中
验证额外符号链接、FIFO 特殊文件、额外普通可执行入口、Info.plist/Mach-O target 不一致，
以及二者同为错误 15.5 target 五类负向 fixture。每项都核对专门的拒绝原因；正向构建与
二次验证同时通过。验证输出继续报告主程序与 Info.plist SHA-256，并明确签名仍为本地
ad-hoc，不构成 Developer ID、公证或 Gate 5 证据。流程未安装或启动 App，也未改变磁盘状态。
