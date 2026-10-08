# 受保护更新到 0.1.6（7）

日期：2026-10-08（Asia/Shanghai）。状态：安装包已构建；等待用户先在系统设置关闭后台项，再执行更新。

## 变更

0.1.5 的 v2 注册后 BTM 丢失容器记录，helper 无法启动（见 `../protected-update-2026-10-08/RESULT.md`）。
0.1.6 新增 `unreachable` 状态：系统报告服务 enabled、但签名 XPC 健康检查失败时，运行环境页提供
“重新注册帮助程序”，确认后由受保护 App 自身 `unregister()`（等待异步完成）→ 复核受保护安装件与
notRegistered/notFound → `register()`。有磁盘操作进行中、状态未知或安装件无法核验时不提供，失败关闭。

## 已完成

- `scripts/check.sh` 与 `scripts/check-read-only-boundary.sh` 通过；新增检查覆盖重新注册只对
  `unreachable`、系统仍报 enabled 且无忙碌磁盘时开放。
- `scripts/build-local-installer.sh` 构建并离线核验 pkg；摘要、大小与逐文件摘要见 `package-metadata.json`。
- 只读核对：已安装 0.1.5（6）逐文件摘要与 `../protected-update-2026-10-08/package-metadata.json` 一致。
- `root-update.py` 与 0.1.5 的脚本逻辑相同，只换了包摘要、大小、新旧文件摘要和版本。

## 更新前置条件

`root-update.py` 的 `idle()` 要求 BTM 中所有 `16.com.leolu.ntfslite.helper*` 记录为 disabled（ADR 0012：
更新前先停用旧服务，不能只替换文件）。当前 v2 为 enabled，0.1.5 又没有注销入口，所以需要用户先在
“系统设置 → 通用 → 登录项与扩展”关闭 NTFS 轻量助手的后台项，再由只读复核确认 disposition 已变为 disabled。
不放宽这项检查。

## 首次执行：在 BTM 检查处失败关闭

用户已在系统设置关闭后台项。只读复核：v1 为 `[disabled, disallowed, not notified]`，v2 为
`[enabled, disallowed, not notified]`。也就是说，系统设置的开关只改“允许”位，v2 仍处于已注册状态。
脚本在 `idle()` 的 BTM 检查处退出（尚未取得维护锁）。复核结果：仍为 0.1.5（6），无维护锁，
launchd 中无 v1、v2，无 App/helper/驱动进程。

## 用户决定：本次放宽 BTM 检查

0.1.5 无法自行注销，0.1.6 又装不上，用户因此决定只对本次脚本放宽：每条 helper 记录必须恰好有一行
Disposition，且含 `disabled` 或 `disallowed`。launchd 查无服务、无相关进程、无可写 FSKit/macFUSE 挂载
这几项检查照旧。这偏离了 ADR 0012“更新前先注销”的要求，理由是：已不允许运行的记录不能被 launchd 启动，
而注销入口只能随本次更新到位。安装后由 0.1.6 的“重新注册帮助程序”补做注销与重新注册。
对当前 BTM 的只读试算显示，两条记录都满足放宽后的条件。
