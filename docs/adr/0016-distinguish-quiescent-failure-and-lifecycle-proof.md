---
status: accepted
---

# 区分已静止失败、未知执行与服务维护证明

2026-10-10 完整审计证明：所有 postconditionFailed 永久冻结会让已回收的健康失败无法标准推出；
反过来，进程读取失败被当退出、App busy=false 被当服务空闲都不满足未知失败关闭。

决定：固定四种磁盘动作不变。响应 v1 增加非零 stateChangedQuiescent(22)：当前状态可能已改变，
但本次 helper 工作已确认停止。仅明确健康 false（子进程回收）、未启动 driver 的确定失败、已返回
DA dissenter 或已回收标准卸载的明确拒绝产生该结果。Bool adapter 的 false 默认 unknown；
callback deadline 产生 unknown，保留上下文，晚回调不能改写已交付结果。

postconditionFailed、超时、无效响应、未确认子进程等仍保留租约，禁止重发。已静止结果只释放执行租约，
App 保留原精确物理绑定用于新鲜核验后的标准整盘释放，不宣称可写、不按旧 UUID 重新授权写入。
同订阅的 Registry ID/MediaUUID/content 绑定推出不要求已卸载卷重新产生只读候选；隐藏行仍由 helper
独立完整拓扑复核。唤醒/App重启的会话恢复边界不变。

服务重注册不能从 UI 空闲推断静止。App 无 writable/releasePending/busy/unresolved 会话时，向签名
helper 发独立 challenge。helper 先原子关闭全部磁盘准入，再核对 runtime 资格、完整进程清单无
NTFS driver/probe、无 pending DA；全部成立才确认。失败仅撤销此次维护门，不清既有未知租约。
成功后该 daemon 不再准入磁盘动作，App 立即调用系统注销；未取得证明不注销。该入口不执行磁盘动作。

进程资源备用证明允许经当前 devfs/node/clone ABI 正证据核对的 PTMX master；不是应用白名单或字符
设备通行。进程退出单独三态，只接受确认 ESRCH/完整 zombie；元数据失败保持未知。

操作诊断记录实际一次性 request trace、匿名盘、动作/失败阶段、固定 helper code、确定性及耗时；
诊断不提供变更授权，测试与用户历史隔离。正式本机发布使用 check-release.sh，完整签名 App/pkg
与安装离线回归不能由 ad-hoc 只读包 PASS 替代。

永久 runtime 残留资格、跨源结束/唤醒/重启恢复、BSD driver 打开竞态、Windows 与长期兼容性未因
本决定通过。本次修改必须以 .scratch/full-repair-2026-10-10 的自动与实物结果分别证明，不从代码推断实测。

2026-10-10 实盘增量：DADiskCreateFromBSDName 对已不存在的 BSD 名仍可分配 reference，不能作为存在事实。标准推出后的缺席确认只接受两份完整且相同的当前内核快照：设备节点、IOMedia BSD 名集合与 Registry ID 集合；节点前后或枚举变化、失败均未知。原 Registry ID 或同名新设备仍存在时不得确认推出。

App 在操作 busy 期间观察到缺席仍立即撤销会话操作资格，但不把它归因为用户拔盘，也不推断推出成功；解释由真实 helper 终态决定。非 busy 断开仍报告无法确认安全推出。

实盘后置收敛增量：标准卸载、驱动退出与空目录清理均确认完成后，全局进程资源读取仍可短暂不可用。最终释放后置证明只对 factsUnavailable 重新取得至多五次独立新鲜完整拓扑/DA/资源事实，每轮之间等待250ms；期间保留执行租约，不重放任何变更。目标替换、挂载仍在或其他矛盾立即失败关闭；超限继续30未知冻结。未知卸载回调或未确认驱动退出不进入此窗口。
