# 可牺牲 U 盘上的正式应用实物验收

Status: ready-for-human
Labels: enhancement, ready-for-human
Assignee:
Blocked-by: 03, 04, 07, 08

## 范围

在已授权的可牺牲 U 盘（XMUP22YM）上，通过正式应用完成：插入 → 启用写入 → Finder 写入并
校验一个文件 → 安全推出 → 重新插入 → 原生只读读回校验。保存证据；不得使用其他盘。

## 验收

- 每步系统事实与界面状态一致；证据写入 `.scratch/formal-write/evidence/`。
- 失败保留现场，不强制卸载。
