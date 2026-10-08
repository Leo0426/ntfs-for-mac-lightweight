# 一次性镜像运行时预检实施计划

> 使用 superpowers:executing-plans 在本会话逐项实现；按用户“把这个实现了吧”的执行授权推进。

Goal：每次写入前获得正式 helper 的真实 FSKit 镜像挂载及完整收尾证据。
Architecture：纯逻辑 RuntimeProbeCoordinator 持有一次探针系统与全局资格；helper 适配器只处理固定种子的独占副本。
Tech Stack：Swift 6、Darwin、CryptoKit、Foundation、现有固定 NTFS-3G 与 FSKit local。
Spec：[已批准设计](DESIGN.md)。

## 全局约束

固定 128 MiB 种子、受保护签名资源、UID 501/GID 20、原驱动参数；不缓存成功、不碰真实盘做探针；只标准卸载，未知收尾保留资源并拒绝后续写入和 idle exit。

## 审查重点

未知挂载与完整的“未挂载”必须区分；驱动确实 waitpid 回收；取消不跳过收尾；只清理由本次独占创建且身份仍匹配的文件；后台检查不并发、不因 XPC 断线或 daemon idle exit 丢失资格。

### 1. 纯逻辑协调器

创建 Sources/NTFSLiteHelperExecution/RuntimeProbeCoordinator.swift、Tests/RuntimeProbeChecks/main.swift。
接口 RuntimeProbeSystem（prepare/start/mountObservation/driverCompletion/standardUnmount/remove/pause）、RuntimeProbeCoordinator.run(system:) -> RuntimeProbeResult。
- [x] 成功收尾 RED → GREEN。
- [x] 失败挂载、归属未知、卸载失败、未回收、并发、每次重新检查、取消收尾回归。
- [x] 接入 scripts/check.sh 独立检查。

### 2. 固定种子与 helper 系统适配器

创建 AppResources/FSKitRuntimeProbe.ntfs.zlib、Sources/NTFSLiteHelper/LiveRuntimeProbeSystem.swift。
独占 root 临时目录，no-follow 输入、固定摘要/大小、描述符绑定；仅固定安装驱动；完整稳定挂载表、虚拟来源、UID/GID/镜像持有核对；标准用户卸载子进程与 waitpid 回收；未知时保持资源。
- [x] 种子字节与篡改/链接/权限/摘要回归 RED → GREEN。
- [x] 正式 fsKitRuntimeReady 接入；IdleExit 检查 probe 资格；保留原有目标重核对。

### 3. 安装与资料

更新 SecureHelperDeployment、build-local-app.sh、verify-local-installer.py 与对应 manifest fixture。
新增 ADR 0013，更新运行时文档和设计状态，版本 0.1.4（5）。
- [x] 完整清单和资源篡改/缺失负例，严格 Release 与全仓库检查。
- [ ] 签名 pkg 离线核验及安装；正式 helper 镜像闭环。
- [ ] fresh 核对授权 NTFSLAB 后正式写入/写删/标准推出；Windows 待用户复核。
