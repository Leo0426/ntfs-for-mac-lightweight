---
status: accepted
---

# 以组合证据划定具名 DeviceFS 非物理观察范围

日期：2026-10-09。用户要求修复 NTFSLAB 不展示；只读复现证明 Apple CoreDevice DeviceFS 同时返回 network=false、没有 BSD 名的 DA 事件，触发全局 unidentifiedDiskEvent 并移除真实 NTFS 候选。

## 决定

保持 match-all DA 回调和独立 IOMedia 精确集合覆盖核对。仅对具名 file-backed DeviceFS 采用有限组合证据：

- 两次相同且类型一致的非空 DA 原始描述；任何原始物理属性或 DAVolumeUUID 键存在（含类型错误）都拒绝。逻辑 BSD major/minor 必须是严格、非浮点、合法范围的 CFNumber，它们本身不是物理身份。
- type=devicefs、network 为严格 false；BSD 名、父盘、whole/internal、介质属性和身份均不存在。两次 IOMedia 查询没有返回对象，只是组合证据，不能单独证明非物理。
- 连续两个完整稳定挂载表完全一致；唯一对应的规范无链接挂载点为 local FSKit DeviceFS，有非零且一致的 fsid，来源是有限 `devices -- file:///...` 文件目录格式。设备来源、远程 authority、查询/fragment、dot segments、可能截断和任意其他类型均拒绝。
- mounted directory 的只读描述符 fstatfs 前后结果及重新打开当前路径的结果，与完整表的 fsid/type/typeName/source/mountPoint/flags 全部一致。读失败、替换与类型矛盾均不排除。

范围外事件不进入物理 inventory；所有其他未知事件仍永久失败关闭。消失时没有当前挂载证据仍拒绝，不缓存历史排除资格、不清除已经出现的未知 latch。任何真实 IOMedia 项被遗漏仍使覆盖集合不一致，不能得到完整观察。

## 其他方案

仅根据缺 BSD、devicefs 字符串、network=false 或 IOMedia 空值忽略事件：不足以证明范围，拒绝。用 DA mountable/unformatted 匹配过滤：会丢失物理边界所需事件且不能排除该卷，拒绝。关闭 Xcode、卸载 DeviceFS 或停止用户其他任务：不作为产品修复。

## 依据与边界

一手 API/源码和日期见 [研究记录](../research/devicefs-physical-observation-scope.md)。这是有限组合证据的工程范围决定，不是 Apple 的永久 DeviceFS 安全契约，不扩大到所有 FSKit 或非/dev来源。未知消失事件恢复需重订阅重新核验；未定义跨回调缓存授权。

此次不改变 Mutation、Data Volume Declaration、依赖 Gate 状态、helper 路径、特权接口或可牺牲介质限制。自动测试与本机只读烟测不能替代实盘与 Windows 验证。
