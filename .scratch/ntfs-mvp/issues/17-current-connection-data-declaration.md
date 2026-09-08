# 定义当前连接的一次性数据卷声明契约

Status: resolved
Labels: enhancement, resolved
Assignee:
Blocked-by: 16-read-only-unknown-role-candidate

## 问题

Apple 系统事实不能区分普通外置 NTFS 数据卷和外置 Windows 系统卷。若个人 MVP 仍要提供写入，
必须把用户的用途声明建模为显式、短生命周期的策略输入，不能伪装成系统角色或持久 allowlist。

## 验收

- typed declaration 表达固定语义“选中卷是数据卷且不是 Windows 启动/系统卷”，不接受自由文本。
- declaration 绑定当前 `VolumeInstanceID`、`DiskInstanceID`、精确 sibling identity 集合、
  Data Declaration Observation Revision 和一次性请求；不接受裸 BSD 名、路径或可复用
  operation ID。
- 只有 fresh candidate 与声明完全一致，且位置 external、NTFS、角色不冲突、同盘无 protected
  事实时，纯逻辑 resolver 才能产生当前请求的 data-role approval。
- 重插、应用重启、睡醒重订阅、目标/拓扑变化、重复消费或旧声明全部拒绝；internal、protected、
  conflicting 与任何不完整事实始终覆盖声明。
- fixture 覆盖外置数据声明成功、外置 Windows 系统盘默认 unknown、用户未确认、克隆/UUID 复用、
  重插、同盘拓扑变化、protected sibling 和重放。
- 本 Issue 不接真实 MountEngine、helper、XPC 或磁盘变更 UI；正式接线仍由 Gate 1–3 与 Issue 12 阻塞。

## 评论

该模型不能消除用户误认外置 Windows 系统盘的残余风险。若此风险不可接受，产品必须保持
unknown 并永久不开放写入，而不能退回自动分类。

## Resolution

2026-08-31 已按 ADR 0005 完成纯 Core 垂直切片：

- `DataVolumeDeclarationRequest` 仅能生成固定 typed 语义“所选卷是数据卷且不是 Windows
  启动/系统卷”，不接受自由文本；声明、session、revision 和 nonce 均无 `Codable` 或持久化路径。
- actor resolver 在内存中绑定当前 session、observation revision、完整 `VolumeInstanceID` 与
  `DiskInstanceID`、精确 sibling identity `Set` 和独立的一次性 request nonce；nonce 不是
  `OperationID`。
- resolver 只对 fresh `ReadOnlyVolumeCandidate` 与完整当前 sibling role/topology facts 签发
  `DataRoleApproval`；目标必须为 external + NTFS，sibling 必须唯一、同盘、非 internal、非
  protected、非 conflicting。
- approval 没有公开构造入口，不是 `VolumeSnapshot`、System Evidence 或 mutation capability；
  正式 Gate 4 仍必须重新读取并核对 fresh 系统事实。
- 公共行为测试覆盖成功路径、未确认、应用重启、wake/resubscribe session 轮换、旧 revision、
  重插代次、UUID 克隆但实例变化、目标与 sibling 拓扑变化、不完整事实、internal/protected/
  conflicting sibling 和重复消费。
- 未连接正式 UI、System adapter、`VolumeCoordinator`、`MountEngine`、helper 或 XPC，未执行任何
  真实磁盘变更。

残余风险不变：用户仍可能把外置 Windows 系统盘误认并声明为数据盘。Gate 1–3 未完成前，
该 approval 不得接入写入流程。
