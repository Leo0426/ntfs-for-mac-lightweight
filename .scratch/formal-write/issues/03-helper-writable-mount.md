# helper：目标复核、健康检查与可写挂载

Status: ready-for-agent
Labels: enhancement, ready-for-agent
Assignee:
Blocked-by: 02

## 范围

helper 内的 `mountWritable` 执行器，把 `usb_lab.py` 已验证的流程改写为 Swift：
fresh 系统事实复核（外置/可移除/物理整盘、NTFS 分区、请求身份一致）→ 原生只读卷标准卸载 →
固定 `ntfs-3g.probe --readwrite`（no-recovery）→ 以独立会话启动固定摘要驱动
（`rw,no_def_opts,silent,backend=fskit,norecover,no_detach,local`）到新随机挂载点 →
验证可写 FSKit 挂载、4 KiB 虚拟来源、驱动持有目标分区（libproc，而非 lsof）→ 返回结果。

## 验收

- 执行器决策逻辑以注入的系统事实做行为检查：每个失败关闭条件有红测试。
- 驱动启动前核对 bundle 内制品摘要与签名；启动后驱动存活于独立会话。
- 失败时：已卸载原生卷而挂载失败，返回“需重新读取事实”，不强制、不重试。
- 在一次性镜像（附加为块设备）上通过 helper 完成真实挂载与卸载。
