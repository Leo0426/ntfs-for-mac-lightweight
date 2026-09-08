# Gate 1 命令输入保持响应且不阻塞观察

Status: resolved
Labels: bug, resolved
Assignee: Codex
Blocked-by:

## 问题

2026-09-08 专用 USB 盘实测时，开放 stdin 管道中的短 `status` / `seal` 命令不能及时处理。
`FileHandle.read(upToCount:)` 在本机管道上等待更多字节；关闭输入端后才完成封存。即使改成
一次 POSIX read，同步读取仍占用 main actor，导致等待操作者输入时观察转发任务无法推进。

## 验收

- stdin 保持打开时，完整 status 行能返回状态，seal 能自然退出并产生可独立 verify 的 artifact。
- 没有输入或只有半行输入时，磁盘观察继续推进；输入命令不是触发观察的前提。
- UTF-8、256 字节行上限、超长行丢弃与后续命令恢复、CRLF、EOF 和读取失败仍失败关闭。
- EOF 没有显式 seal 时退出 65，读取失败退出 74，两者均无 canonical 输出。
- 既有严格 Release、CoreChecks、只读边界和验包检查通过。

## Resolution

RED 1：真实 CLI 管道回归在 stdin 保持打开时无法得到 status。GREEN 1：使用有界 POSIX
read，并处理 EINTR，避免等待填满 Foundation 缓冲区。

RED 2：半行命令等待后补齐 status，观察数仍为 0。GREEN 2：串行 DispatchQueue 独占
输入解析状态，使用 continuation 异步交付一条命令，释放 main actor；不在 cooperative executor
中执行阻塞读取，不预取无界命令队列。解析器、固定命令协议、stop-and-drain 和证据 schema
保持原契约。所有可变读取状态都只由该队列访问。

新增 `python3 scripts/check-gate1-cli-input.py`，经真实可执行入口覆盖两项回归、非法编码、
16 KiB 超长行跨缓冲区恢复、同批命令、CRLF、四类 EOF 和目录 FD 读取失败。fixture 应用身份
仅存在临时输出中，不作为硬件证据。

199 项 CoreChecks、严格 Release 全构建及证据工具构建、三个只读 root 边界检查、本地 App
正向验包、5 组负向 fixture 和 3 组 CLI 检查全部通过。重新实测开放管道时 status 已有 26 帧，
seal 后有 29 帧，独立 verify 成功；Gate 仍为 incomplete，详见
[实物证据](../evidence/G1-5354DF11B2C047289A1862B41EAC2300.md)。
