# ADR 索引

本目录记录难以逆转、存在真实权衡且脱离上下文会令人费解的架构决策。ADR 解释“为什么采用这条边界”，不定义 Gate 编号，也不维护 Gate 当前状态；Gate 的唯一来源是[分阶段实施计划](../engineering/implementation-plan.md)。

## 已接受

- [0001 — 在实物 Gate 前保持只读系统观察边界](0001-read-only-system-observation-boundary.md)
- [0002 — 使用结构化、一次性 helper 协议](0002-structured-one-shot-helper-boundary.md)
- [0003 — 诊断只持久化私有、有界、可验证的结构化快照](0003-private-bounded-diagnostic-snapshots.md)
- [0004 — 用组合式静态代码证据固定 macFUSE 身份](0004-pin-macfuse-static-code-identity.md)
- [0005 — 把只读卷候选与数据卷声明分开](0005-separate-observed-volume-from-data-declaration.md)
- [0006 — 把 Setup 冲突完整性绑定到具名候选范围](0006-scope-setup-conflict-evidence.md)
- [0007 — 把有界 Gate 证据工具链与正式应用分开](0007-separate-bounded-gate-evidence.md)
- [0008 — 用已挂载文件系统 UUID 补充只读候选身份](0008-supplement-candidate-identity-from-mounted-filesystem.md)

后续若引入真实 XPC、helper 安装、提权、应用签名/公证或磁盘执行器，应先判断是否形成新的
难以逆转边界；满足 ADR 条件时按顺序新增 `0009-*.md`，不得用修改本索引代替决策记录。
