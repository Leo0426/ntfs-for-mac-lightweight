# 本机旧服务注销与受保护更新

日期：2026-09-30（Asia/Shanghai），macOS 27.0.1（26A434）。

用户本轮明确授权删除旧服务、重新注册启动；先前“稍后批准”不再阻止本次服务维护。

## 已验证

1. 对历史 tracer App 与 tracer 可执行文件核对 Apple generic、Team NP3U2GYHWL、App 标识的固定签名要求。
2. 原 tracer `status` 为 enabled，执行 `SMAppService.unregister()` 返回 unregistered/notRegistered，随后独立查询仍为 notRegistered。
3. 系统后台记录中旧 `com.leolu.ntfslite.helper` 变为 disabled/allowed；旧、新 launchd 服务均不存在。完整成功的进程/挂载枚举未发现 App/helper/NTFS-3G 进程或 FSKit/macFUSE 挂载。
4. 新 pkg 离线核验通过，SHA-256 为 `ad797a5a7d4ada82fcca57a92f2ff769386702fabf6e05e186268e160f6bbbe8`。一次性管理员维护命令在 root 下再次检查权限、签名、后台记录、服务、进程、挂载和包摘要；将原 App 移入 root-only 回退目录后由系统 Installer 安装。
5. 安装后逐文件 SHA-256 与核验过的源 App 相同，完整 root:wheel 树、无不安全模式/ACL/链接、固定签名均通过；版本为 0.1.1（2）。独立 `scripts/verify-protected-install.sh` 通过。
6. 已启动 `/Library/PrivilegedHelperTools/NTFSLite.app`，进程路径与新版安装位置一致。

回退 App：`/private/var/tmp/ntfslite-maintenance-432kgtq2/previous-NTFSLite.app`。回退目录为 root 所有、0700，保留包与旧 App；未自动删除。

## 注册与健康检查

界面控制工具读取初始窗口成功，但点击“运行环境”时报 `Sky Computer Use native pipe closed before response`；重建工具会话仍失败。应用进程继续运行，此现象不能判为 App 崩溃。

已请用户在新版运行环境中点击注册并完成系统批准。此时 v2 尚未出现在 launchd，签名的只读健康探针返回 connectionInvalidated；未宣称 helper 可用。

健康探针只有 `healthCheck:withReply:`，没有磁盘动作，固定服务器签名要求与随机 16-byte challenge，要求完整精确回复。本次未执行实盘挂载、卸载、推出或写删；NTFS 写入与 Windows 复核仍待验收。
