# 启用写入被错误的磁盘身份提示拦截

日期：2026-09-30。Status: in-progress。Labels: bug, in-progress。

## 原始症状与复现

用户在 0.1.1（2）对可牺牲 NTFSLAB 启用写入后，卷保持只读，提示未进行任何更改、磁盘已变化或无法确认同一个卷。
当时 v2 服务已经注册运行，固定签名的随机 challenge XPC 健康检查通过。

复用正式 helper 的系统读取器做管理员只读预检，完整 PID 表采样稳定，两个分区的 ownedFSKitMounts 都返回 nil。
最小诊断定位到同一个已退出、尚未被父进程回收的 zombie：路径读取 ESRCH，而 kill(pid, 0) 成功。
独立 BSD-info 返回完整 136 字节、对应 PID 和 SZOMB。旧逻辑没有区分 zombie 与不可读活跃进程，拒绝整个扫描。

## 修复与验证

- 先加入失败的公共策略回归，实际观察到 CHECK FAILED（确认 zombie 仍阻止完整扫描）。
- helper 在路径 ESRCH/kill 成功时，读取包含 zombie 的精确 BSD-info；只有完整长度、PID 一致、状态 SZOMB 的正证据才可略过。
- 权限失败、未知、活跃或矛盾结果仍拒绝，不改动磁盘拓扑或 UUID 校验。
- 回归 GREEN；相同 zombie 仍在时，原始管理员只读场景两个分区变为 Optional([])。临时 D-LITE 未进入 Sources。
- `PATH=/Users/heyonepiece/.local/bin:$PATH scripts/check.sh` 通过：严格 Release、CoreChecks、独立检查、83 个 Python 用例、边界与包 fixture。
- 构建、离线核验和固定摘要 root 安装新版 0.1.2（3）成功。安装后逐文件摘要、root:wheel、权限/ACL/清单及固定签名通过。
- 更新前关闭正式 App，签名 tracer 注销 v2，独立 status 为 notRegistered，系统后台记录 disabled、无 helper/driver 进程、仅原生只读 NTFS 挂载。更新操作没有卸载或写入磁盘。
- 回退安装：`/private/var/tmp/ntfslite-maintenance-y8qnpbnd/previous-NTFSLite.app`，root-only 目录保留。

## 当前剩余门槛

已安装 helper 的只读 FSKit 用户探针退出 1。普通用户签名 FSClient 查询成功但目标模块列表为空，PlugInKit 能列出正式 macFUSE local 模块。
已核对 vendor App 固定 Team/签名，并仅对该 App 用当前用户 `lsregister -f` 刷新登记；目标模块仍未出现在 FSClient。
此结果不能推断用户未开启扩展。macFUSE 维护者对相似问题建议重建当前用户 LaunchServices 数据库并立即重启；全局数据库删除与重启尚未执行，等待用户选择。

来源：[维护者回复](https://github.com/macfuse/macfuse/issues/1192#issuecomment-5409800952)、[官方排查步骤](https://github.com/macfuse/macfuse/wiki/Troubleshooting)。

新版 App 已启动；工具重建会话可以读取窗口和截图，但 AX/坐标点击均使原生控制连接中断。已请用户点击新版注册入口，后续要复核真实 XPC。

本轮没有执行实盘挂载、卸载、推出或文件写删。NTFS 可写、快速拔插竞态及 Windows 复核尚不能报告通过。

临时只读探针、构建输出、原始本机事实及一次性维护命令留在本目录供当前会话复核，含原始身份的材料不进入提交。

## 重启后补充（2026-09-30）

0.1.2（3）v2 helper 已由用户重新启用，实际签名 XPC 核验通过。macFUSE 两个正式模块已
通过 vendor 官方局部组件命令重登记，用户再次确认 local 开关开启。普通签名用户枚举
仍缺目标，已安装 helper 的实际 `fskit-ready` 子进程退出 1。

现有独立一次性镜像协调器本次通过真实 FSKit local 可写挂载、标准卸载、驱动退出与
卸载后健康检查，前后物理目标相同。当前运行时枚举门禁误拒绝被实际对照证实。
证据为原工作区 `.build/write-validation/context-probe-5cs1g91y/`。
没有全局缓存删除或物理盘变更；正式产品的后端预检仍未修复。
设计提案见 `../fskit-runtime-preflight-fix/DESIGN.md`，待用户确认。
