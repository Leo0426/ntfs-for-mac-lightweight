# 验证结果

2026-09-08，当前工作区无 Git 元数据。

- 严格 Release CoreChecks：207 PASS、退出 0；包括 8 项新增行为检查。
- 完整 warnings-as-errors Release 构建与证据工具单独构建：通过。
- scripts/check-read-only-boundary.sh：依赖、负向样例与源码边界通过。
- 本地 App 构建、正向验包：通过；仅 ad-hoc 签名。
- 本地 App 5 组负向 fixture：全部按预期拒绝。
- python3 scripts/check-gate1-cli-input.py：3 组通过。
- 真实 U 盘 canonical capture / 独立 verify：成功；incomplete、0/100、最终 verified。
- 真实只读 observer → presenter：检测到 1 个 NTFS 卷、只读、用途未确认、零变更资格。
- 原生窗口自动化：连接超时，未取得窗口截图/键盘/VoiceOver 人工验收。

read-only-projection.swift 仅连接本轮正式 Core/System/ReadOnlyProbing/Presentation 产物，
链接对象从各 target 当前 output-file-map.json 选取，避免旧 .o 文件混入。编译目标为
arm64-apple-macosx15.4。探针的 SetupAssessment 固定为未就绪，只验证真实观察与展示映射；
不声称验证了真实 Setup 或窗口交互。
