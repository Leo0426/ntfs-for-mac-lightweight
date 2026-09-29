# 正式应用写入能力：实施地图

PRD：[PRD.md](PRD.md) · 决策：[ADR 0010](../../docs/adr/0010-enable-writable-mount-in-formal-app.md)

先用 02 验证最大的未知（Apple Development 签名下 SMAppService daemon + XPC 能否在本机工作），
再按纵向切片接通 helper 执行、App 接线和 UI，最后在可牺牲 U 盘上实物验收。

| # | Issue | 依赖 | 状态 |
|---|---|---|---|
| 01 | [规则与依赖边界更新](issues/01-boundary-rules.md) | — | resolved |
| 02 | [SMAppService + XPC 签名可行性 tracer](issues/02-helper-tracer.md) | 01 | resolved |
| 03 | [helper：目标复核、健康检查与可写挂载](issues/03-helper-writable-mount.md) | 02 | ready-for-agent |
| 04 | [helper：标准卸载与推出整盘](issues/04-helper-unmount-eject.md) | 03 | ready-for-agent |
| 05 | [App：helper 状态进入 Setup，XPC 作为 MountEngine executor](issues/05-app-helper-client.md) | 02 | ready-for-agent |
| 06 | [协调器与数据卷声明接线](issues/06-coordinator-wiring.md) | 05 | ready-for-agent |
| 07 | [UI：启用写入与安全推出](issues/07-write-eject-ui.md) | 06 | ready-for-agent |
| 08 | [打包与签名：helper、LaunchDaemon、固定驱动](issues/08-packaging-signing.md) | 02 | ready-for-agent |
| 09 | [可牺牲 U 盘上的正式应用实物验收](issues/09-hardware-acceptance.md) | 03 04 07 08 | ready-for-human |
