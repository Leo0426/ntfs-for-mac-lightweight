# 可执行路径失效时的设备句柄核对

核对日期：2026-10-10（初次核对 2026-10-09）。范围：本机 macOS 27.0.1、Xcode SDK 的公开 libproc 接口与当前正式 helper。

Apple XNU 的 `proc_pidpathinfo_internal` 从进程的 text vnode 取得路径，并再次执行 vnode lookup；
仍存活的进程在应用更新、迁移或文件删除后可能无法完成路径 lookup。ENOENT 不能表示进程退出，
也不能证明它是 NTFS 驱动。实物只读复现中，Orca daemon 存活，proc_pidpath 返回 ENOENT，
而完整卷 UUID、分区拓扑读取正常；旧 helper 把整个挂载占用扫描降为 unknown。

来源：[Apple XNU proc_info.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/proc_info.c)、
[Apple libproc.h](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.h)、
[Apple kern_resource.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_resource.c)。
`RUSAGE_INFO_V0.ri_uuid` 由内核的 executable UUID 填入；严格参数解码拒绝未知 argc、缺 NUL、非法 UTF-8 和 argv0/exec path 矛盾。
运行系统与开源 main 版本并非严格一一对应；本机实际行为另以只读预检记录，不从源码推断运行结果。

修复只对 ENOENT 且当前仍存活的进程使用另一套正证据：连续两份完整 FD/vnode 元数据快照相等，
每份快照前后的 PID、启动时间、非零内核可执行映像 UUID、进程绝对启动时刻及完整内核 exec path/参数一致，长度、容量、描述符唯一性和类型都已核对。
所有 vnode 都须是 regular file、directory、独立绑定的 /dev/null，或经完整当前内核证据核对的 PTMX master。
PTMX 必须与当前 /dev/ptmx 的 devfs、精确路径、inode、fsid、root:tty 0666、链接数与动态设备 major 匹配；
clone minor 由当前 kern.tty.ptmx_max 约束。两份完整 FD/可执行映像/lifecycle 快照一致，参考节点前后不变。
不打开或读写现有终端。其他字符设备、块设备、未知类型、读取失败、权限错误、截断、进程或 FD 变化均拒绝。
潜在 NTFS 驱动参数也不提供排除证据，保留尚未打开设备的启动窗口保护。
不依赖进程名、应用名、历史路径或清理其他应用；owned 与 orphan 扫描采用相同恢复边界。

这只证明本次观测未持有存储设备句柄，不证明进程未来不会打开设备，不授权任何磁盘变更。
既有驱动打开设备的快速拔插竞态、长期兼容性与 Windows 复核限制不因此消失。
真实磁盘身份、精确分区集合、NTFS 健康、每次独立镜像证明与挂载后检查仍各自执行。
本次管理员只读复查在 Orca daemon 持续运行时对两个目标分区取得 Optional([])。
没有实盘挂载、卸载、推出或文件写删；不能宣称本次实盘写入验证通过。


2026-10-10：本机 Orca 活进程的完整 PROC_PIDFDVNODEPATHINFO 返回 /dev/ptmx，旧规则因此误拒绝；
独立自身 PTY fixture 复现 before=true/master=nil/closed=true。修复后同一活进程只读检查通过。
一手依据：[Apple XNU tty_ptmx.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/tty_ptmx.c)
的动态 major 注册、devfs clone 节点及 minor 分配；设备 ABI 采用当前 SDK，并用本机 native fixture 核对。
开源 main 与安装系统未严格版本匹配，未验证其他 macOS、其他终端家族或 Windows。
全局 PID 枚举最多三次新鲜尝试，每次仍要求两份完整集合相同；阶段日志只有固定代码，不记录 PID/路径。
驱动退出单独采用 alive/exited/unknown 事实：只接受 ESRCH 或完整精确 PID 的 zombie；短读、权限或身份异常不证明退出。
