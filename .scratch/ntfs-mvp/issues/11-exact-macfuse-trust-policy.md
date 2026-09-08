# 固定 macFUSE 精确版本 allowlist

Status: resolved
Labels: bug, resolved
Assignee:
Blocked-by:

## 问题

创建本 Issue 时，可信 bundle 读取器已核对路径、owner、权限和 bundle identifier，但还不能
拒绝只满足最低版本、却没有出现在精确批准目录中的 macFUSE 版本。

## 验收

- typed policy 包含非空的精确 `approvedVersions` allowlist。
- 版本更高但未列入批准记录、空 allowlist 或非法版本均失败关闭。
- 本地 fixture 覆盖 exact match、未知更新版本、空目录和证据矛盾。
- 正式生产策略在 Issue 03 完成批准前继续保持为空；本 Issue 不宣称任何版本已获批准。

## Resolution

2026-08-31：`TrustedBundleVersionPolicy` 已加入非空精确版本 allowlist，可信读取器只接受目录
内的版本；完整 Release 行为检查已通过。签名身份、产物摘要的 typed 证据另由 Issue 15
跟踪，实际生产批准条目仍由 Issue 03 取得。
