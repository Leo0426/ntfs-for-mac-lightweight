# 本地只读开发包发布与回滚

当前流程只生成个人本机使用的只读开发包，不是 Gate 5 候选，也不包含 helper、XPC、磁盘
变更接口、Developer ID 或公证。

## 构建与验证

在仓库根目录运行：

```sh
scripts/build-local-read-only-app.sh
```

脚本会依次检查只读依赖边界、执行严格 Release 构建、组装最小 App、临时签名，并验证当前
已经实现的项目：

- bundle identifier、三段版本、构建号和 macOS 15.4 最低版本；
- 固定 `Contents`/`MacOS` allowlist、无符号链接或特殊文件、单一 arm64 主程序，以及没有 helper/插件/XPC 目录；
- Mach-O `LC_BUILD_VERSION` 的 macOS 平台和 deployment target 与 Info.plist 的 15.4 声明一致；
- 严格代码签名；
- 主程序与 Info.plist 的 SHA-256，并明确本地 ad-hoc 签名不构成 Gate 5 证据。

上述结构与平台强化已由已解决的
[`14-local-read-only-release-verification`](../../.scratch/ntfs-mvp/issues/14-local-read-only-release-verification.md)
记录。它仍只证明本地只读 ad-hoc 包符合当前 allowlist，不证明 Developer ID、Hardened Runtime、
公证、helper 或 Gate 5 已完成。

负向回归检查会在唯一的 `mktemp` 目录复制已验证 App，依次构造额外符号链接、FIFO 特殊
文件、额外普通可执行入口、Info.plist/Mach-O deployment target 不一致，以及二者同为错误
15.5 target 的 fixture。每项必须命中对应的失败关闭原因；退出时删除整个临时目录，不安装
或启动 App：

```sh
scripts/check-local-read-only-app-negative-fixtures.sh \
    .build/NTFSLiteReadOnlyApp.app
```

也可只读复核现有包：

```sh
scripts/verify-local-read-only-app.sh .build/NTFSLiteReadOnlyApp.app
```

## 本地安装与回滚

- 退出正在运行的旧版本。
- 在 Finder 中保留上一份已验证 App 副本，再复制新包到个人选择的位置。
- 首次启动确认窗口明确显示“只读观察阶段”，且没有启用写入或安全推出按钮。
- 若启动、观察或诊断异常，退出新版本并恢复上一份 App；依赖和磁盘状态不应由本包改变。

## 卸载与诊断数据

- 在应用的“诊断摘要”页先使用“清除诊断”；只有界面确认本地存档已清除才算成功。
- 退出应用后把 App 移到废纸篓。
- 当前只读包没有 helper、启动项或自带驱动；用户独立安装的 macFUSE/NTFS-3G 不属于本包，
  不得在回滚时静默移除。

## 已知限制

- 签名为 ad-hoc，`TeamIdentifier` 不存在，未启用 Hardened Runtime，也未公证。
- Setup 生产信任策略尚未批准，因此运行环境保持未就绪。
- 只读观察的 callback 静默仅表示界面收敛，不证明全量枚举覆盖。顶层枚举覆盖已验证、
  mount table 稳定且没有未识别磁盘事件时，正常 Mac 无外置 NTFS 会显示“未检测到 NTFS 磁盘”；
  顶层事实不可信，或有未完整读取的可移动物理盘时，仍显示失败关闭标题。
