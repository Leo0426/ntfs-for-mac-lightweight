# 彻底移除受保护安装（2026-10-08）

状态：已全部清除，重启后复核通过。

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

## 执行结果

用户执行后脚本输出 PASS：v1、v2 已不在 launchd 的 system 域；受保护 App、5 个维护目录与 3 个诊断目录已删除；
安装收据已 forget。

独立只读复核：上述路径都不存在，`pkgutil` 中已无 `leolu` 收据，launchd 查无 v1/v2，没有相关进程。
仍有残留：
- BTM：v1、v2 daemon 记录，以及 2 条 `2.com.leolu.ntfslite.readonly` 容器记录（一条指向 `.build` tracer，
  一条指向已删除的受保护路径）；
- LaunchServices：仍登记着已删除的受保护路径，以及 `.build/` 下的 4 个开发副本。

下一步：注销 LaunchServices 中的开发副本和失效路径，然后重启，复核 BTM 是否自行清理。

## 清理开发副本与 LaunchServices

用户要求全部删除。`.build/` 下 4 个 App 副本（`NTFSLite`、`NTFSLiteHelperTracer`、`NTFSLiteReadOnlyApp`、
`NTFSLiteScenarioPrototype`）已用 `/usr/bin/trash` 移入废纸篓（可恢复，未硬删）。用 `lsregister -u` 注销了
受保护路径、原 `.build` 路径和废纸篓中的路径；复核时 LaunchServices 已无 `com.leolu.ntfslite*` 标识或
`NTFSLite` 路径。`.build/NTFSLite-local.pkg` 保留，作为重装来源。

剩余：BTM 记录没有逐条删除的接口，需要用户以 root 执行 `sfltool resetbtm` 并重启（这会重置所有 App 的
后台项批准）。launchd disabled 覆盖表中的 v1/v2 键也会保留，没有可用的删除接口；它只是在服务加载时
提供启用标记，对其他服务没有影响。

## BTM 重置、launchd 覆盖表与重启复核

用户执行 `sudo sfltool resetbtm`（输出 `Database reset.`），只读复核 BTM 中已无 `leolu`/`NTFSLite`。
`.build/NTFSLite-local.pkg` 已移入废纸篓。用户备份 launchd `disabled.plist` 后，用 PlistBuddy 删除
`com.leolu.ntfslite.helper` 与 `.helper.v2` 两个键；与备份对比，差异只有这两个键。随后 16:51 重启。

重启后只读复核（16:52）：`disabled.plist` 与 `launchctl print-disabled system` 中都没有 `leolu`；BTM 中没有
`leolu`/`NTFSLite`；LaunchServices 中没有 `com.leolu.ntfslite*` 标识或 `NTFSLite` 路径；受保护 App、维护/诊断目录、
探针目录、安装收据都不存在；没有相关进程。备份 `~/disabled.plist.bak` 已移入废纸篓。重装时须先运行
`scripts/build-local-installer.sh` 重新构建，再做首次安装。
