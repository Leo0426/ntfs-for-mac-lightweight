# helper：标准卸载与推出整盘

Status: ready-for-agent
Labels: enhancement, ready-for-agent
Assignee:
Blocked-by: 03

## 范围

`unmountVolume`、`unmountDisk`、`ejectDisk` 三个固定动作：Disk Arbitration 标准卸载/推出，
FSKit 可写挂载的标准卸载（以挂载用户身份，等待驱动退出），卸载后移除空挂载点。
不使用 force；超时继续等待并返回“静止未确认”。

## 验收

- 行为检查覆盖：卸载被占用（busy）返回原因、不强制；驱动未退出保持租约；推出前同盘所有卷已卸载。
- 一次性镜像上真实卸载/推出通过；最终系统事实复核整盘消失。
