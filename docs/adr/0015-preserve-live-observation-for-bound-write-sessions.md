---
status: accepted
---

# 绑定写入会话的复查保留当前观察源

2026-10-10：正式应用在 helper 验证可写后调用完整 refresh，重新订阅 Disk Arbitration 并创建
新 inventory。新订阅分配新 MediaGeneration，会话 ledger 却保留原 DiskInstanceID，因而把仍
有相同 IOMedia Registry Entry ID 的物理盘和运行中的驱动误报为断开。

决定：操作结束后的复查、以及 writable/busy/unresolved 会话存在时的手动复查，向当前 capture
的串行输入队列提交只读 refresh。刷新收敛和枚举修订，重新读取稳定挂载表与独立 IOMedia 覆盖；
不更换事件源，不清空连接代次，也不继承旧的覆盖成功。失败仍保持未验证。

没有绑定会话的只读手动刷新仍可重建订阅；唤醒仍重建，保持原有撤销边界。已结束的 capture
不能因 refresh 被恢复，也不能为已有操作会话重建并静默重绑。源失效、唤醒或 App 重启后的
会话恢复仍未提供独立验证方案；不能据 BSD 名、卷标或旧卷 UUID 推断是原物理实例。

不采用按 BSD/UUID 归一化代次或忽略 ledger 缺项。真正的 disappeared/重新出现仍由原 inventory
轮换代次，原有 target、注册表身份、精确分区集合、授权及推出校验不变。

UI 保留实时扫描/失败说明，仅说明本次会话的操作记录仍保留。历史记录本身不是当前已验证
可写或可拔出的证据。此决策不改变 Gate 状态或 Windows 复核限制。
