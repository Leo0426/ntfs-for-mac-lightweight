# 取得 Gate 1 外置盘证据

Status: ready-for-human
Labels: enhancement, ready-for-human
Assignee:
Blocked-by: 01-complete-observation-proof, 09-trusted-protected-volume-role, 16-read-only-unknown-role-candidate, 17-current-connection-data-declaration

## 验收

- 专用外置盘插拔 100 次，无幽灵卷且介质代次单调轮换。
- 多分区父子关系与系统事实逐次一致。
- 可信内部位置逐次映射为通用 `protected`；外置 NTFS 默认保持 unknown，只以无变更资格的
  candidate 显示，不按卷名或位置声称精确识别 Boot Camp/data。
- candidate 的 `coordinatorInventory` 始终为空；当前连接声明在重插、睡醒重订阅、应用重启、
  sibling 拓扑变化和一次消费后失效，不能复用为 System Evidence。
- 睡眠、唤醒和应用重启均完成对照。
- 证据中确认没有 mount、unmount、eject 或写入调用。

## 评论

需要专用硬件和人工观察；当前 Mac 的 smoke test 不能关闭本 Issue。

2026-08-31 已有独立 `NTFSLiteGate1EvidenceTool` 可辅助记录匿名、有界的 100 次连接生命周期、
封闭检查点和 canonical SHA-256 artifact，并可通过 `verify` 严格重放核验。工具不执行系统清单
或 mount table 人工对照，也不证明测试盘专用、截图真实或全程零磁盘变更；其最高结论
`readyForHumanReview` 绝不等于 pass。本 Issue 因此继续保持 `ready-for-human`，必须由操作者在
专用外置盘上完成验收并签署 Evidence。

2026-09-08：用户已明确提供可牺牲 USB 盘。取得一次真实插入状态的匿名只读取证，独立 verify
成功，最终 coverage verified，但系统未提供 NTFS Volume UUID，未形成 candidate，循环仍为
0/100。修复取证 CLI 的开放管道响应和等待输入阻塞观察问题（Issue 28）；卷身份兼容性见
Issue 29。没有执行插拔周期、睡眠、写入或格式化；Windows 复核与 Gate 2 固定依赖仍未验证。
本 Issue 状态保持不变，证据为
[incomplete](../evidence/G1-5354DF11B2C047289A1862B41EAC2300.md)。

2026-09-08 后续：Issue 29/30 已完成已挂载文件系统 UUID 补充与缺失身份展示。USB-1 已形成一个
只读、用途未确认的 candidate，原始 DA UUID 仍缺失且未改写；新的
[证据](../evidence/G1-599DFC215DBB4D6CBA982D72F91CBF50.md)验证成功、coverage verified、0/100。
采集开始和结束时均已连接，尚未完成 absence baseline、物理重插与旧选择失效实物验证；
本 Issue 保持 ready-for-human。
