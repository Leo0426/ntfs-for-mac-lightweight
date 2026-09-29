# FSKit 运行时写入前检查

核对日期：2026-09-29。来源仅限本机 Xcode 27.0 的 macOS SDK `FSKit.framework` 头文件
`FSClient.h`、`FSModuleIdentity.h`，以及本机只读 API 调用。本文不批准磁盘变更。

## 可证明的事实

`FSClient.fetchInstalledExtensions` 返回当前调用方可观察到的文件系统扩展
`FSModuleIdentity` 列表；`bundleIdentifier` 标识模块，`isEnabled` 报告已返回模块的状态。
Apple 的公开接口没有保证其他 Team 的模块对当前调用方可见。因此，**观察到目标模块且
`isEnabled == true` 是正信号；未观察到它不能证明系统没有安装或启用它**。现有 helper
暂以该正信号作为卸载前门禁：出错、超时、缺项、重复或未启用时均保持原生只读挂载。
这保证失败关闭，但可能拒绝实际可用的环境。驱动与健康探针另由 helper 核对固定签名，
目标磁盘拓扑在异步检查后重新核对。

## 本机只读结果与边界

同日使用本项目 Apple Development Team 签名的只读探针，以当前 uid 501 调用上述 API，
返回 Apple 自带模块，没有返回目标 macFUSE 模块；`pluginkit` 能列出目标模块，但没有显式
`use` 标记。此前[一次性镜像诊断](../../.scratch/write-delete-validation/FSKIT-DIAGNOSIS.md)
记录了同样无 `use` 标记且 ad-hoc FSClient 未观察到目标模块时，uid 501 仍成功完成 FSKit
镜像挂载。两种枚举都不能单独证明目标模块不可用。此次仅运行只读 API 探针，未运行真实
挂载、卸载、推出或写入。受保护部署后的 helper 用户子进程是否有不同可见范围尚未验证。

`isEnabled` 只描述返回列表中的模块，不保证驱动能成功挂载或安全卸载，也不证明
NTFS 数据完整性。当前正信号门禁会使本机写入路径保持关闭；不能把这种拒绝写成
“扩展未安装”或“扩展已禁用”。仍未验证受保护安装后的 helper/FSKit 端到端流程、可牺牲介质上的
挂载与推出、Windows 复核及其他 macOS 版本；这些测试不能在用户数据盘上补做。
