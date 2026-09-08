## Agent skills

本项目以 Codex 为主要开发代理。Codex 在修改代码前先读取本文件、根目录
`CONTEXT.md` 和当前任务直接相关的 ADR；新增行为使用测试驱动的红、绿、重构循环，
并在交付前运行仓库现有检查与严格 Release 构建。

### Codex working agreement

- 默认使用中文沟通，状态、风险和验证边界优先使用清晰文字表达。
- 只处理当前任务范围内的文件，保留用户已有和无关改动。
- 在 Gate 1–3 取得真实硬件证据前，只开发只读观察、纯逻辑、协议、展示和诊断；
  不执行真实挂载、卸载、推出、修复、格式化或其他磁盘变更。
  2026-09-09 用户明确授权的例外：允许独立实验工具在一次性镜像和已确认的可牺牲 U 盘上
  验证 macOS 写入闭环，使用已接受的 macFUSE 5.4.0 候选；Windows 复核由用户在功能完成后
  手动执行，不阻塞该实验开发。例外不适用于其他数据盘或正式应用，且不自动改变 Gate 状态。
  实验边界见 ADR 0009；每次磁盘操作仍须核对当前目标和失败关闭条件。
- 所有未知、矛盾、截断、超时或不完整的系统事实都必须失败关闭，不能推断为安全。
- UI 不拼接命令、路径或挂载参数；变更能力只能通过结构化领域接口进入协调器。
- 不使用强制卸载、`recover`、`remove_hiberfile`、内核扩展回退、关闭 SIP 或降低启动安全性。
- 研究当前版本、平台能力与第三方依赖时，只采用一手来源，并把日期和未验证项写入仓库文档。
- 没有可牺牲测试盘、Windows 复核、固定依赖和签名条件时，明确报告阻塞门槛，不在用户数据盘上试验。
- 涉及 package 或系统边界的修改还必须运行 `scripts/check-read-only-boundary.sh`；只读应用依赖图不得进入 mutation/helper target，固定 Setup 探针之外不得新增 `Process`。

### Issue tracker

Issues 和 PRD 使用本地 Markdown，存放在 `.scratch/<feature>/`。见 `docs/agents/issue-tracker.md`。

### Triage labels

使用 ForgeFlow 默认类别和状态标签。见 `docs/agents/triage-labels.md`。

### Domain docs

本仓库采用单一上下文：根目录 `CONTEXT.md` 与 `docs/adr/`。见 `docs/agents/domain.md`。
