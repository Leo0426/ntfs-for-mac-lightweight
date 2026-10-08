# 启用帮助程序后运行环境页面未刷新

日期：2026-09-30。Status: done。

## 复现与根因

用户确认按钮为“运行环境”的“启用帮助程序”。该页面 `ReadOnlySetupDetail`
仅 `@ObservedObject` 订阅 `ReadOnlyAppStore`，却直接读取内部 `WriteController` 的
`@Published helperState/helperMessage`。子对象变化不会自动通知外层 ObservableObject；
切换页面或外层磁盘数据变化引发重绘后，才显示正确结果。

自动复现编译实际三个 App 源文件及真实状态对象，只把 App 的入口注解替换为检查入口；
不注册 helper、不启动 UI、不做磁盘变更。对真实控制器运行只读 refresh，子对象成功发布，
外层页面观察对象却未通知。RED 实际失败于：
`the visible setup page must invalidate when helper refresh publishes, without navigation`。

## 修复

外层 Store 创建 WriteController 时持有 Combine 订阅，将其 `objectWillChange`
同步转发到外层；使用 weak self 防止相互持有。原有受保护安装、注册状态、签名 XPC 和
一次性检查 token 都保持原有判断。当前页面与后续检查均可收到状态变化。

## 验证

- `python3 scripts/check-app-store-observation.py`：RED 后 GREEN，真实观察对象收到
  首次及后续 helper 刷新通知，无需导航。
- `scripts/check.sh`：退出 0，包括严格 Release、全部 CoreChecks、新观察回归、
  独立安全/等待/idle 检查、83 个 Python 实验回归、CLI、边界与 7 组只读包负例。
- `scripts/build-local-installer.sh`：签名 0.1.3（4）及 pkg 离线核验通过。
- `git diff --check`：通过。

用户在已安装 0.1.3（4）的运行环境页面实际点击后确认“已自动更新”；独立签名 XPC
检查通过，launchd parent bundle version=4，helper 正在运行。
这项修复不改变 FSKit 枚举门禁，也不代表实盘写入问题已经解决。

一次性受保护维护脚本与原始安装输出仅供本机会话，未作为生产更新器或通用可提交工具。

## 正式安装件

0.1.3（4）已通过 root 暂存固定包摘要、Installer 与逐文件摘要核对完成更新。
独立受保护完整树核验通过，已打开正式安装 App，并请求用户在当前页面点击启用以核对 GUI。
包 SHA-256：`4badce39a64cd5940b04857b09bce6cd95abc3c1bea8dd7f0b698dc783068fdf`。
旧 0.1.2（3）回退件保留于 root-only `/private/var/tmp/ntfslite-maintenance-4acofs9w/previous-NTFSLite.app`。
服务已按既有维护授权注销，更新阶段无 helper/driver 进程，原生 NTFS 卷保持只读；
没有执行实盘挂载、卸载、推出或写删。用户已重新启用新版并确认当前页面自动更新，未切换页面。
