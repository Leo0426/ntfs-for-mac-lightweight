# Triage Labels

## 类别角色

| ForgeFlow role | 本仓库 label |
|---|---|
| `bug` | `bug` |
| `enhancement` | `enhancement` |

## 状态角色

| ForgeFlow role | 本仓库 label |
|---|---|
| `needs-triage` | `needs-triage` |
| `needs-info` | `needs-info` |
| `ready-for-agent` | `ready-for-agent` |
| `ready-for-human` | `ready-for-human` |
| `wontfix` | `wontfix` |
| `resolved` | `resolved` |

## 规则

- 每个已分诊 issue 恰好包含一个类别角色和一个状态角色。
- `needs-info` 补齐后回到 `needs-triage`。
- Agent 只领取 `ready-for-agent`。
- `ready-for-human` 不得由 Agent 领取。
- `wontfix` 和 `resolved` 是终态。
