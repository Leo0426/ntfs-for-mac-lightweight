# helper 进程扫描与僵尸进程

核对日期：2026-09-30，macOS 27.0.1（26A434），Xcode macOS 27 SDK。

## 本机可复现问题

正式 App 已安装为 0.1.1（2），v2 launchd 服务运行且固定签名 XPC 健康检查成功。
在用户已授权的 NTFSLAB 只读挂载上，复用 helper 系统读取器的管理员只读探针，
重复得到同一错误：完整稳定的 PID 表包含一个僵尸进程，`proc_pidpath` 返回 ESRCH，
`kill(pid, 0)` 仍成功。旧逻辑仅接受后者 ESRCH，因此整个 owned-mount 扫描返回 nil，
拓扑预检拒绝为 factsUnavailable，界面显示“磁盘已变化或无法确认是同一个卷”。

`ps` 显示该进程为 Z/defunct；独立 `proc_pidinfo(pid, PROC_PIDTBSDINFO, 1, ...)`
返回完整 136 字节、精确目标 PID、`pbi_status == SZOMB`（5）。NTFS 卷 UUID 和
IOMedia 拓扑在相同只读检查中均可取得。本轮未以改盘来复现。

## 一手依据

- [Apple XNU proc_info.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/proc_info.c)：
  PROC_PIDTBSDINFO 的非零 arg 允许查找 zombie；普通 PIDPATH 查询不会启用该查找。
- [Apple XNU kern_exit.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_exit.c)：
  SZOMB 为退出后的状态，等待父进程回收。
- 本机 SDK `sys/proc_info.h` 的 `proc_bsdinfo`、`PROC_PIDTBSDINFO` 与
  `sys/proc.h` 的 SZOMB，与本机实际查询结果一致。

公开 XNU main 不是此 macOS 构建的精确源码；以上接口语义已用本机调用核对，
不据公开源码宣称当前内核的其他未测行为。

## 最小修复与失败关闭边界

路径查询 ESRCH 且 kill 检查仍成功时，额外读取包含 zombie 的 BSD-info。
只有返回长度完整、目标 PID 一致并明确为 SZOMB，才允许扫描略过该进程。
活跃状态、权限失败、截断、PID 不符或读取失败仍保持未知；不略过无法解释的进程。
整盘/分区/UUID 绑定、完整稳定 PID 表、驱动持有关系和挂载核对没有放宽。

公共策略回归先 RED：确认 zombie 时仍阻止扫描；GREEN 后覆盖确认 zombie、已退出、
活跃、未知、权限不足和矛盾错误。管理员只读原始场景在相同 zombie 仍存在时，
从两个分区 owned=nil 变为完整空集合。严格 Release、仓库检查与边界检查通过。

本修复只证明此进程扫描误拒绝已消除，不能替代实际 NTFS 挂载/写删、整盘推出、
快速拔插竞态验证或 Windows 复核。
