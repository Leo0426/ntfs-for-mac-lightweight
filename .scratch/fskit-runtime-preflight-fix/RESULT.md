# 正式 helper 每次一次性镜像预检

日期：2026-09-30。状态：代码与签名包已完成，正式安装件实测等待 macOS 管理员验证。

## 实现

每次启用写入由正式 helper 新建固定空白 NTFS 种子的独占 128 MiB 副本。
受保护资源必须匹配解压前后大小和 SHA-256，副本从持有描述符再次读回核对摘要。
同一受信驱动使用固定 FSKit local 参数，并永久使用 UID 501/GID 20。
完整稳定挂载表、FSKit 虚拟来源、驱动身份/参数/文件持有与实际可写状态共同证明挂载。
标准用户卸载、waitpid 回收、挂载消失与仅清理本次身份匹配资源全部通过后，才可操作目标卷。

不使用 FSClient 的跨 Team 枚举作为硬门禁，也不缓存镜像通过结果。
探针资格在进程中和 root 持久目录中共同约束所有后续变更和 idle exit；未知现场不自动清理。
镜像检查的用户子进程也由探针保留并 waitpid，不使用强杀或将超时视为已回收。
预检结束后重新确认物理代次、同盘集合、卷 UUID、原生只读挂载点和无 owned mount。

## 验证

- 协调器成功与挂载自行消失两个行为 RED→GREEN；每次新预检、归属未知、卸载失败、
  驱动未回收、并发、取消、清理失败全部 GREEN。
- 种子解码与 exact manifest RED→GREEN；摘要篡改、截断、追加、user-owned 输入、缺失及链接拒绝。
- 真实无害 false/sleep 子进程 waitpid RED→GREEN；超时保持存活，已回收后的 ECHILD 不能当作成功。
- 独立审查发现两处 Important：持久资格未进入其他变更/idle 检查，以及预检期间目标资格变化
  未在卸载前拒绝；均新增回归 RED→GREEN，已修复。没有 Critical/Minor。
- `PATH=/opt/homebrew/bin:$PATH scripts/check.sh`：退出 0，包括严格 Release、CoreChecks、
  实际 App Store 观察回归、安全安装树、协调器、种子、真实子进程、83 个 Python 实验回归、
  CLI、边界与 7 组只读包负例。系统 Python 3.9 缺少既有测试需要的 enterContext；使用本机 3.14。
- 安装离线检查 14 项通过，包含种子篡改/缺失/链接，既有额外 payload、缺少 preinstall、
  adhoc 签名及不安全父路径负例。
- 修复审查问题后重新构建签名 0.1.4（5）并完整离线核验 pkg。
- `scripts/check-read-only-boundary.sh` 与 `git diff --check` 通过。

## 安装状态与边界

旧 0.1.3（4）完整逐文件摘要与前次验证记录一致；没有运行中的 App/helper/driver。
旧 v2 服务已注销，独立 status 为 notRegistered。物理 NTFSLAB 仍是原生只读挂载，未变更。
系统更新认证返回 `-60005`（管理员用户名或密码不正确），Installer 未执行，安装件仍为 build 4。
已请求用户在系统授权界面重新验证，不接受聊天中的密码。

新包：`.build/NTFSLite-local.pkg`，SHA-256：
`5708d93a878a3de4820e76312d551205b77599b10f303787bdaddbc6a7b057b2`。
一次性 root 更新脚本固定包字节并逐文件后验，只供本轮已授权维护，不作为生产更新器。

正式 root helper 镜像闭环、可牺牲 NTFSLAB 的正式写入/写删/标准推出与 Windows 复核尚未通过。
不能由自动检查或签名包核验推断这些结果。Gate 状态保持原有定义。
