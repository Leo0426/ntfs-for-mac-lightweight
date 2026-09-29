# 协调器与数据卷声明接线

Status: ready-for-agent
Labels: enhancement, ready-for-agent
Assignee:
Blocked-by: 05

## 范围

ReadOnlyAppStore 的观察结果 → fresh 候选 + 一次性数据卷声明 → `VolumeCoordinator.rebuildInventory`
→ `requestEnableWriting` / `requestEject` → `executeMutation` 经 helper executor → 结果后重新读取
系统事实更新状态。声明在重插、重订阅、拓扑变化、消费后失效。

## 验收

- 行为检查：声明缺失/过期/重放拒绝；同盘互斥；执行后必须以新系统事实结算状态。
- App 依赖边界检查通过。
