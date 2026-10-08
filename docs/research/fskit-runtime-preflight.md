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

## 2026-09-30 受保护安装后实测

macOS 27.0.1（26A434），正式安装 0.1.1（2）的 helper 用户子进程执行固定
`fskit-ready` 探针退出 1；同 Team 的普通用户只读 FSClient 探针成功返回，但两个目标模块均未观察到。
用户已确认在系统设置中开启两个模块，PlugInKit 仍能列出正式安装的 local 模块。
核对 vendor App 签名后，仅对它以当前用户 `lsregister -f` 更新注册，结果未改变。
不能由此认定扩展禁用，尚未通过真实可写挂载证明可用性。

macFUSE 维护者对 FSKit/PluginKit 不一致的类似报告给出
[回复](https://github.com/macfuse/macfuse/issues/1192#issuecomment-5409800952)，建议依照
[官方排查页面](https://github.com/macfuse/macfuse/wiki/Troubleshooting) 重建当前用户的
LaunchServices 登记数据库并立即重启；其步骤影响整位用户的应用、扩展与打开方式目录。
本轮没有执行该全局删除或重启，等待用户选择。具体记录见
[本机诊断](../../.scratch/write-identity-bug/RESULT.md)。

## 2026-09-30 重启后镜像对照

用户正常重启后，启动时间已更新；新版 0.1.2（3）的 v2 helper 注册、运行且签名 XPC
challenge 通过。用户再次确认按类别中的 local 开关开启。受信 vendor 的扩展组件经官方
`macfuse install --components file-system-extensions --force` 局部重登记后，PlugInKit 可见
两个正式模块；普通用户签名 FSClient 查询仍未观察到它们，安装 helper 的固定用户
`fskit-ready` 子进程退出 1。本轮没有执行全局 LaunchServices 数据库删除，重启不证明已重建该库。

现有独立镜像协调器在 uid 501 下对固定种子的新副本通过真实 local FSKit 可写挂载、
来源/持有核对、标准卸载、驱动退出和卸载后健康查询；前后物理测试盘事实相同。
证据在原工作区 `.build/write-validation/context-probe-5cs1g91y/`。
这证明当前硬门禁会在实际可用的镜像场景误拒绝，不能继续把“需要用户开启开关”作为唯一解释。
没有执行物理盘挂载、卸载、推出或写删。正式签名驱动的相同路径和 Windows 仍须分别验证。

建议以正式 helper 自身完成的、固定一次性镜像挂载与完整收尾正证据代替外部 Team 枚举硬门禁。
[设计](../../.scratch/fskit-runtime-preflight-fix/DESIGN.md) 已获用户批准；正式实现按
[ADR 0013](../adr/0013-verify-runtime-with-disposable-image.md) 改为每次独立镜像预检。
0.1.4（5）不再用跨 Team 模块枚举作为写入硬门禁；安装件实测结果另列。
