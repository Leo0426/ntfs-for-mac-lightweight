# 受保护更新到 0.1.5（6）

日期：2026-10-08（Asia/Shanghai）。状态：已安装；v2 已注册但 helper 无法启动，重启后未恢复，阻塞。

## 已完成

- `main` 合并受保护安装分支与恢复的 Codex 快照后，`scripts/check.sh` 与
  `scripts/check-read-only-boundary.sh` 通过。版本提升为 0.1.5（6），因为它在 0.1.4（5）之外还含诊断摘要与
  检查器修复。
- `scripts/build-local-installer.sh` 构建并离线核验 pkg；摘要、大小与逐文件摘要见 `package-metadata.json`。
- 更新前只读核对：已安装 0.1.3（4）逐文件摘要与 `../fskit-runtime-preflight-fix/root-update.py` 的
  `OLD_FILES` 一致，固定签名通过；无 App/helper/驱动进程、FSKit/macFUSE 挂载或运行时探针目录；
  v1、v2 均不在 launchd。
- `root-update.py` 与 0.1.4 的一次性维护脚本逻辑相同，仅替换包路径、摘要、大小、预期文件摘要与版本。

## 首次执行

用户报告已执行脚本，但随后只读复核：安装件仍为 0.1.3（4）、修改时间未变，没有新的 root 暂存或回退
目录，也没有维护锁。脚本在变更前退出或未以 root 运行；失败原因待取得原始输出，不推断为安全或成功。

## 重跑结果

用户在自己的终端重跑，脚本输出 Installer `The upgrade was successful` 与 0.1.5（6）的 PASS；回退件为 root-only
`/private/var/tmp/ntfslite-maintenance-t51n1_pu/previous-NTFSLite.app`（0.1.3（4），13:24:49 创建）。

随后独立只读复核：版本 0.1.5（6），9 个文件摘要与 `package-metadata.json` 一致，整树 root:wheel、无组/其他可写、
无 ACL 或链接，App 与 helper 固定签名通过；维护锁已释放，v2 未注册，无 App/helper/驱动进程或 FSKit/macFUSE 挂载。
本次未注册服务，也未操作任何磁盘。

## v2 注册后 helper 无法启动

13:26:19 打开受保护 App，SMAppService status 0（notRegistered）。13:26:30 用户点击启用：BTM `registerLaunchItem`
复用 0.1.3 时期的既有记录 `4A742151…`（此前 disposition disabled），launchd `Submit job succeeded`，status 变为 1
（enabled）。随后 BTM 对 v2 与旧 v1 记录均报 `no container item`，`effectiveDisposition` 报
`FATAL ERROR - fullPath is nil, container=(null)`；launchd 每次按需启动都报
`The specified path is not a bundle: Contents/MacOS/NTFSLiteHelper` 并置为 inactive。plist 无 KeepAlive，App
挂起的 XPC 连接使 launchd 约每 10 秒重试。App 显示 `.unavailable`，未开放磁盘操作，属预期失败关闭。

只读复核：同一核验函数 `SecureHelperDeployment.verifyInstalled` 对安装件返回 true；LaunchServices 已于 13:26
登记 `/Library/PrivilegedHelperTools/NTFSLite.app`（版本 6）。另有 4 个 `.build/` 下用户可写包使用相同标识符
`com.leolu.ntfslite.readonly`，其中 `.build/NTFSLite.app` 同为版本 6；helper 启动时核对自身受保护路径，误关联也会
失败关闭。

推断（未证实）：BTM 记录原先关联的 App 容器随旧包移入回退目录而失效，复用记录时没有重建到新包的关联。
2026-09-30 更新到 0.1.3 时同类流程成功，差异未查明。App 没有注销入口；不使用 `sfltool resetbtm`（全局重置所有
登录项批准）。下一步：退出 App 停止重试，重启让 BTM 重新解析，再在运行环境页重新检查。

## 重启后只读复核

14:05:28 重启。App、helper 未运行；`launchctl print system/com.leolu.ntfslite.helper.v2` 与 v1 均为
`Could not find service`，launchd disabled 表中两者为 enabled。启动后 BTM 仍查询 `4A742151…`，14:18 对 v1、v2
报 `no container item`，launchd 中查无该 job。重启没有修复。

`sfltool dumpbtm`（只读）显示：v1（`CC78F5AC…`，disabled）与 v2（`4A742151…`，enabled）记录在 UID -2 分区，
`Parent Identifier` 为 `2.com.leolu.ntfslite.readonly`，但 UID -2 分区内没有这个容器记录。对照组 Surge、UU远程、
macFUSE 的 daemon，其容器都在同一分区并带 `Embedded Item Identifiers`。同一标识符的容器只出现在：
UID 0，指向 `.build/NTFSLiteHelperTracer.app`（2026-09-29 tracer 实验遗留）；UID 501，指向受保护路径，
没有内嵌项。由此可确认 launchd `copy_bundle_path` 失败的直接原因：daemon 记录找不到所属容器，所以无法解析
`BundleProgram`。容器为何在升级后丢失仍未查明。

可选修复都会改变 BTM 状态，须用户决定：由受保护 App 自身调用 `SMAppService.unregister()` 后再 `register()`
（目前 App 没有该入口，需要新增并重新发布）；或在系统设置“登录项与扩展”中关闭再开启该后台项（未验证能否重建
容器）。不使用 `sfltool resetbtm`；不用 `.build/` tracer 注销，它会在用户可写副本上再造一条容器记录。
