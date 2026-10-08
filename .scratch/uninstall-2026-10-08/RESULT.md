# 彻底移除受保护安装（2026-10-08）

状态：脚本已就绪，等待用户以 root 执行。

## 背景

0.1.6 安装后 v2 仍报 `fullPath is nil, container=(null)`，launchd 启动失败（EX_CONFIG）。用户决定彻底移除后重装。

## 只读盘点（执行前）

- 受保护 App `/Library/PrivilegedHelperTools/NTFSLite.app`（0.1.6（7）），安装收据
  `com.leolu.ntfslite.local-installer`。
- root-only 维护备份 `/private/var/tmp/ntfslite-maintenance-*` 共 5 个，诊断目录
  `/private/var/tmp/ntfslite-readonly-diag-*` 共 3 个；无运行时探针目录。
- launchd 中有 v2（spawn failed）；BTM 中有 v1、v2 daemon 记录，另有 2 条容器记录（UID 0 指向
  `.build/NTFSLiteHelperTracer.app`，UID 501 指向受保护路径）。
- 用户 Library 下无 `com.leolu.*` 偏好、容器或缓存；没有 NTFS、FSKit 或 macFUSE 挂载，也没有相关进程。

## 脚本 `root-uninstall.sh`

前置条件（不满足即失败关闭）：root；无 NTFSLite/ntfs-3g 进程；无非只读 FSKit/macFUSE 挂载；无维护锁。
执行内容：对固定的两个 label 做 `launchctl bootout`；删除受保护 App、维护/诊断残留和探针目录；
执行 `pkgutil --forget`；最后打印剩余 BTM 记录。
不做的事：不碰磁盘，不用 `sfltool resetbtm`，不改其他 App 的后台项。BTM 记录没有逐条删除的接口，
只能看删除 bundle 并重启后系统是否自行清理。
