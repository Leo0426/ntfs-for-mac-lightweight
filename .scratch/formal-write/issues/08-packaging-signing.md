# 打包与签名：helper、LaunchDaemon、固定驱动

Status: resolved
Labels: enhancement, resolved
Assignee: Claude
Blocked-by: 02

## 范围

构建脚本产出签名 .app：主程序、`Contents/MacOS/<helper>`、`Contents/Library/LaunchDaemons/<plist>`、
`Contents/Helpers/` 下固定摘要的 NTFS-3G v2 驱动与 probe。使用本机 Apple Development 身份签名，
Hardened Runtime 开启；验证脚本与负向 fixture 更新为新的 allowlist。

## 验收

- 验包脚本核对全部文件、摘要、签名与 Team ID；额外/替换文件失败关闭。
- 回滚说明更新：注销 helper、删除 app。

## Resolution

2026-09-29：`scripts/build-local-app.sh` 产出 `.build/NTFSLite.app`：主程序、helper、LaunchDaemon plist、
`Contents/Helpers` 下复制前核对 SHA-256 的 v2 驱动与探针；驱动以固定标识符签名（不启用库校验以加载
macFUSE libfuse），helper 与 App 启用 Hardened Runtime。脚本核验精确文件清单、严格签名、四个标识符与
Team ID。回滚：在 App 中无卸载入口，需在系统设置“登录项”关闭或删除 App 后由系统清理；
`NTFSLiteHelperTracer` 仅为开发诊断工具。原只读 ad-hoc 包流程保留供 `scripts/check.sh`。
