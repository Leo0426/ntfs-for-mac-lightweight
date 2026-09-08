# 从物理盘 inventory 排除明确网络卷

Status: resolved
Labels: bug, resolved
Assignee: Codex
Blocked-by:

## 问题

Disk Arbitration 的 match-all appeared 回调会包含没有 BSD 身份的网络卷对象。原实现把任何无
BSD 身份事件永久记录为 `unidentifiedDiskEvent`；因此当前 Mac 即使最终 IOKit 枚举与 DA 本地
介质集合完全一致，Gate 1 显式封存仍稳定产生 `finalObservationUnverified / failedClosed`。

网络卷不属于本产品的物理介质范围，但也不能仅凭“无 BSD”或无法取得 IOMedia 就猜测其为
网络卷，否则可能隐藏真实物理盘事件。

## 验收

- 从 Apple `kDADiskDescriptionVolumeNetworkKey` 解码 typed 可选网络卷事实。
- 该键只接受真正的 CFBoolean；数字、字符串、缺失或其他类型保持 unknown。
- 只有 `isNetworkVolume == true` 的事件不进入物理盘 inventory。
- `false` 或 `nil` 且无 BSD 身份的事件仍永久记录 `unidentifiedDiskEvent`。
- 即使带物理介质 BSD 身份的事件被错误标记为网络卷，独立 IOKit 集合不一致仍阻止完整观测。
- 当前 Mac 的 live observer 必须取得顶层 issues 为空的覆盖观察；新的立即 seal artifact 应为
  无失败码的 `incomplete`，而不是 `finalObservationUnverified`。
- 严格 Release、warnings-as-errors、只读边界、App 验包与 CLI capture/verify 全部通过。
- 不记录原始网络路径、卷名、BSD 名或其他新身份信息，不执行任何磁盘变更。

## 评论

2026-08-31 最小复现连续 3/3：每次 24 个 observation，最终帧只剩
`unidentifiedDiskEvent`。临时无身份诊断仅输出事件类型及布尔事实，确认唯一来源为
`appeared / IOMedia=false / VolumeNetwork=true`；诊断日志随后已删除。

## Resolution

2026-08-31：按公共 inventory 接口完成 RED、GREEN、重构。

- `DiskArbitrationDescription` 新增 typed `isNetworkVolume`；live decoder 只接受真实 CFBoolean，
  `NSNumber(1)`、字符串和缺失值都保持 unknown。
- inventory 只排除明确 `true`；`false/nil + no BSD` 的失败关闭语义保持不变。
- 独立 IOKit 组合回归证明，错误标成网络卷的物理样式 BSD 身份会产生集合不一致，不能升级为
  Complete Observation。
- live smoke 现在要求顶层 issues 为空，不再只检查枚举标记消失。

严格 Release CoreChecks、完整 warnings-as-errors 构建、只读源码/依赖边界、本地 App 正向验包
和 5 组篡改包负向样例全部通过。收紧 CFBoolean 后连续 3 个新的 live capture 均为 24 帧、失败码
`none`、verdict `incomplete`，artifact 全部通过独立 verifier，`verify stdout` 为 0 字节且隐私
模式命中为 0；capture 的 canonical artifact 保持独立输出。EOF 返回 65 且 artifact 为 0 字节。
本地 App 主程序 SHA-256 为
`d1fe456f2fb5a23727782430f2404e0366c90e5c3c576d30ba791ebfd34fa684`。

本修复只恢复物理介质观察范围，不提供任何真实硬件 Gate 证据；Gate 1 仍未通过。全程未执行
挂载、卸载、推出、修复、格式化或写盘。
