# 把 macFUSE 版本与签名绑定到同一批准条目

Status: resolved
Labels: bug, resolved
Assignee:
Blocked-by:

## 问题

原 `TrustedMacFUSEPolicy` 把多个批准版本与一个签名策略独立组合。版本 reader 先按 pathname
读取 Info.plist，签名 provider 再按同一路径建立 `SecStaticCode`；若路径在两次读取之间由批准
版本 A 替换为签名身份 B，reader 会把两个时点的证据拼成 `trusted(A)`，违反 ADR 0004 的
same-entry 不变量。

## 验收

- 策略使用非空的“精确版本 -> `TrustedCodeSignaturePolicy`”目录，目录键集合与
  `approvedVersions` 完全相同。
- 不同版本不得共享同一个 Code Directory identity；缺项、多项、重复 identity 或非法目录项
  均失败关闭。
- live provider 从完成严格验证的同一 `SecStaticCode` 的 `kSecCodeInfoPList` 读取 secured
  `CFBundleIdentifier` 与 `CFBundleShortVersionString`。
- secured identifier/version 缺失、格式非法，或与文件系统 reader 结果及所选目录项不一致时
  失败关闭。
- fixture 覆盖版本 A 读取后路径切换到签名 B、目录缺项/多项/重复 identity、错误 hash，以及
  secured plist 缺失、非法和不一致。
- 不配置生产批准值，不安装或启动依赖，不执行任何磁盘变更。

## Resolution

2026-08-31：按公共 `TrustedMacFUSEEvidenceReader` 完成 RED/GREEN/REFACTOR。

- RED：fixture 先从文件系统读取 5.3.3，再由签名 provider 把同一路径替换为 5.4.0 并返回
  5.4.0 的签名身份；旧实现错误返回 `trusted(5.3.3)`。
- GREEN：策略改为精确版本签名目录，严格要求目录完整且 Code Directory identity 一一对应；
  `TrustedCodeSignatureEvidence` 增加 secured identifier/version，并在 Team ID、Code Directory
  与版本目录项共同匹配后才返回 trusted。
- live provider 复用已经通过 `SecStaticCodeCheckValidity` 的同一静态代码对象，通过
  `SecCodeCopySigningInformation` 读取 `kSecCodeInfoPList`；任一缺失或矛盾保留 typed failure。
- REFACTOR：文件系统 Info.plist 与 secured Info.plist 共用同一严格三段版本解析规则，避免边界
  之间产生格式漂移。
- 严格 Release CoreChecks 覆盖 mixed epoch、目录缺项/多项/重复 identity、错 hash、secured
  plist 缺失/非法/不一致；生产策略继续为空，本 Issue 不构成 Gate 2 证据。
