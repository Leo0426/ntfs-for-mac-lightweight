# 可牺牲 U 盘上的正式应用实物验收

Status: ready-for-human
Labels: enhancement, ready-for-human
Assignee:
Blocked-by:

## 范围

在已授权的可牺牲 U 盘（XMUP22YM）上，通过正式应用完成：插入 → 启用写入 → Finder 写入并
校验一个文件 → 安全推出 → 重新插入 → 原生只读读回校验。保存证据；不得使用其他盘。

## 验收

- 每步系统事实与界面状态一致；证据写入 `.scratch/formal-write/evidence/`。
- 失败保留现场，不强制卸载。

## 当前覆盖与剩余项

0.1.18 已完成正式 App 写入、4 MiB 读回校验、删除与安全推出，见[本机验证](../../../docs/release/local-validation.md)。此前版本和独立实验的重插验证不能冒充此版本证据；仍需同一被测签名版本在安全推出后重新插入，以原生只读挂载读回验证。执行前须重新确认当前授权测试盘，不沿用旧设备号。
