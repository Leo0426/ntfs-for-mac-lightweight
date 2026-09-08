# 本轮验证记录

2026-09-08，操作者：Codex；检查结果来自本轮实际运行。

| 检查 | 结果 |
|---|---|
| swift run -c release -Xswiftc -warnings-as-errors NTFSLiteCoreChecks | 199 PASS、退出 0 |
| swift build -c release -Xswiftc -warnings-as-errors | 通过 |
| 严格 Release 单独构建 NTFSLiteGate1EvidenceTool | 通过 |
| scripts/check-read-only-boundary.sh | 三个只读 root、负向依赖样例、源码检查通过 |
| scripts/build-local-read-only-app.sh | 通过，本地 ad-hoc 包 |
| scripts/verify-local-read-only-app.sh .build/NTFSLiteReadOnlyApp.app | 通过 |
| scripts/check-local-read-only-app-negative-fixtures.sh | 5 组拒绝通过 |
| python3 scripts/check-gate1-cli-input.py | 3 组通过：开放管道/封存、观察进度/非法输入恢复、EOF/读取失败 |

UI 自动化原生连接返回 Sky Computer Use native pipe closed before response，未取得窗口证据。
工作区没有 Git 元数据；验证对象为当前工作区与严格构建产物，未声称完成 Git diff 审查。
