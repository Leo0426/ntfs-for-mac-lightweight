# 建立 macFUSE 签名身份与产物摘要证据策略

Status: resolved
Labels: bug, resolved
Assignee:
Blocked-by:

## 问题

精确版本 allowlist 已能拒绝未知更新版本，但版本、bundle identifier、owner 和权限仍不能单独
证明安装内容就是 Gate 2 批准的 macFUSE 制品。生产 Dependency Trust Evidence 还需要签名
身份与适用的产物摘要，并与批准记录一致。

## 验收

- typed policy 能表达 Team ID、指定需求/CDHash 或经一手资料确认的等价签名身份，以及适用的
  产物摘要；字段缺失时保持 `notConfigured`。
- 使用 Security framework 等结构化系统 API或可注入 typed provider 读取证据，不新增通用命令
  或第二个 `Process`。
- 签名身份不一致、摘要/字节漂移、证据矛盾或读取不完整均返回 `failedClosed`。
- fixture 覆盖 exact match、身份不符、摘要漂移、未知和矛盾证据。
- 正式生产策略在 Issue 03 取得一手来源、批准值和 Gate 2 镜像证据前继续保持为空；本 Issue
  只交付失败关闭能力，不批准任何真实依赖。

## Resolution

2026-08-31：新增组合式 `TrustedMacFUSEPolicy`，当时把非空精确版本 allowlist 与一组指定需求、
Team Identifier 和 `kSecCodeInfoUnique` Code Directory 二进制标识组合成完整策略。该初版尚未
把每个版本与它自己的签名 identity 一一绑定；这个缺口后由 Issue 22 修正。
实时 provider 通过 Security framework 编译需求、严格验证所有架构、嵌套代码、sealed
resources 和符号链接约束，再读取结构化签名事实；任一读取失败、字段缺失、身份不符或
Code Directory 标识漂移都返回固定 `failedClosed` 原因。

fixture 已覆盖精确匹配、Team ID 不符、Code Directory 标识漂移、签名信息不可用、字段
不完整和非法策略；Setup 展示层只显示固定失败码，不泄露路径、需求内容或签名字节。没有
提供完整组合策略时仍为 `notConfigured`，提供了非法或矛盾策略时失败关闭。正式 App 的
生产策略继续为空；本 Resolution 不批准任何 macFUSE 版本，也不构成 Gate 2 镜像证据。

## 后续修订

2026-08-31：Issue 22 修复了本 Issue 初版把多个版本集合与单一签名策略组合时可能产生的
跨时点拼接。当前策略已改为版本专属签名目录，并核对同一 `SecStaticCode` 的 secured
Info.plist identifier/version；本 Issue 的生产策略为空和不构成 Gate 2 证据等边界保持不变。
