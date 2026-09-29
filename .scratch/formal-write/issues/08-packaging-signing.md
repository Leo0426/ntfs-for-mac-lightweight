# 打包与签名：helper、LaunchDaemon、固定驱动

Status: ready-for-agent
Labels: enhancement, ready-for-agent
Assignee:
Blocked-by: 02

## 范围

构建脚本产出签名 .app：主程序、`Contents/MacOS/<helper>`、`Contents/Library/LaunchDaemons/<plist>`、
`Contents/Helpers/` 下固定摘要的 NTFS-3G v2 驱动与 probe。使用本机 Apple Development 身份签名，
Hardened Runtime 开启；验证脚本与负向 fixture 更新为新的 allowlist。

## 验收

- 验包脚本核对全部文件、摘要、签名与 Team ID；额外/替换文件失败关闭。
- 回滚说明更新：注销 helper、删除 app。
