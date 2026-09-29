## Agent skills

本项目以 Codex 为主要开发代理。Codex 在修改代码前先读取本文件、根目录
`CONTEXT.md` 和当前任务直接相关的 ADR；新增行为使用测试驱动的红、绿、重构循环，
并在交付前运行仓库现有检查与严格 Release 构建。

### Codex working agreement

- 默认使用中文沟通，状态、风险和验证边界优先使用清晰文字表达。
- 只处理当前任务范围内的文件，保留用户已有和无关改动。
- 2026-09-29 用户决定（ADR 0010）：正式应用接入外置 NTFS 数据卷的可写挂载与安全推出，
  不再以 Gate 1–3 通过为前置；Gate 定义与状态不因此改变。开发与验证中的真实挂载、卸载、
  推出、格式化等磁盘操作仍只允许在一次性镜像和用户已授权的可牺牲 U 盘上执行，不得在
  用户数据盘上试验；每次磁盘操作仍须核对当前目标和失败关闭条件。
  ADR 0009 的独立实验工具保留用于回归和新候选验证。
- 所有未知、矛盾、截断、超时或不完整的系统事实都必须失败关闭，不能推断为安全。
- UI 不拼接命令、路径或挂载参数；变更能力只能通过结构化领域接口进入协调器。
- 不使用强制卸载、`recover`、`remove_hiberfile`、内核扩展回退、关闭 SIP 或降低启动安全性。
- 研究当前版本、平台能力与第三方依赖时，只采用一手来源，并把日期和未验证项写入仓库文档。
- 没有可牺牲测试盘、Windows 复核、固定依赖和签名条件时，明确报告阻塞门槛，不在用户数据盘上试验。
- 涉及 package 或系统边界的修改还必须运行 `scripts/check-read-only-boundary.sh`；正式应用可进入的 mutation/helper target 以 ADR 0010 与边界检查的允许集合为准，特权执行只在 helper 内，App 进程固定 Setup 探针之外不得新增 `Process`。

### Issue tracker

Issues 和 PRD 使用本地 Markdown，存放在 `.scratch/<feature>/`。见 `docs/agents/issue-tracker.md`。

### Triage labels

使用 ForgeFlow 默认类别和状态标签。见 `docs/agents/triage-labels.md`。

### Domain docs

本仓库采用单一上下文：根目录 `CONTEXT.md` 与 `docs/adr/`。见 `docs/agents/domain.md`。
