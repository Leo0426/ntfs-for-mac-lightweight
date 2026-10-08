# macFUSE 按 App 开关不响应

核对日期：2026-09-30（Asia/Shanghai）。状态：只读诊断完成，按类别操作待用户验证。

## 当前证据

- 用户截图显示系统设置的 macFUSE Extensions 弹窗，属于 By App 入口；两个 FSKit 开关显示关闭，用户报告点击不响应。
- 当前系统为 macOS 27.0.1（26A434）。
- 只读 `pluginkit -m -A -D -v -i io.macfuse.app.fsmodule.macfuse-local` 成功，返回一个正式安装路径中的 local 模块。该结果证明模块已注册，不证明启用状态或可写挂载能力。
- 沙箱内首次查询返回 Connection invalid；读取系统注册状态的同一查询在获准越过沙箱后成功。前者不是模块缺失证据。

## 一手依据与下一步

macFUSE 维护者在 [issue #1194 的回复](https://github.com/macfuse/macfuse/issues/1194#issuecomment-5470510841) 中确认，By Application 与 By Category 使用不同 Apple 系统组件；其诊断发现前者的启用请求因缺少权限而被拒绝，并建议通过 By Category 启用。该回复由 GitHub 公开 API 直接核对，作者为维护者 bfleischer。

用户当前症状与该报告一致，但未通过当前系统日志或按类别操作最终确认同一根因。下一步：关闭弹窗，切换 By Category，打开 File System Extensions，启用本项目使用的 macFUSE (local)，再核对系统状态。

本轮未更改系统设置、注册 helper、重启系统服务或操作磁盘。此 macFUSE 模块与本项目 v2 特权 helper 的注册是两个独立条件。

## 用户操作后的状态

同日用户确认两个模块均已开启。该确认记录为用户完成系统设置操作，不等于正式 App 的 FSKit 挂载验收。

随后只读复核：受保护路径的 App 仍为 0.1.0 (1)，launchd system 域找不到 v2 helper；后台任务记录仍包含旧 v1 helper 的 enabled/allowed 状态，没有 v2 记录。剩余事项是旧服务的安全迁移、受保护 App 更新、v2 注册/批准和 XPC 核验。
