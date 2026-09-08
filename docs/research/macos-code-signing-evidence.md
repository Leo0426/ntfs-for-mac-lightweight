# macOS 静态代码签名证据

调研日期：2026-08-31

## 结论

macFUSE 的本地信任不能只依赖版本字符串、bundle identifier、owner 或权限。当前失败关闭策略
使用非空的“精确版本 -> 签名策略”目录；每个批准条目同时固定指定代码需求、Team Identifier、
`kSecCodeInfoUnique` 返回的 Code Directory 二进制标识，以及 Code Signing Services 看到的
secured bundle identifier/version。生产目录当前仍为空，本笔记和实现只提供核对能力，不批准
任何 macFUSE 版本。

这里的运行时“产物摘要”专指 Apple 返回的 Code Directory 二进制标识，并与严格 sealed
resources 验证组合使用；它不替代上游源码归档 SHA-256、构建可复现性或 Gate 2 镜像记录。

## Apple 一手来源事实

- [`SecStaticCodeCheckValidity`](https://developer.apple.com/documentation/security/secstaticcodecheckvalidity%28_%3A_%3A_%3A%29)
  会验证静态代码签名、所有 sealed components（包括资源）并应用调用方给出的
  `SecRequirement`。Apple 同时明确指出：结果只在底层代码不再被修改时有效。
- [Static Code Validation Flags](https://developer.apple.com/documentation/security/static-code-validation-flags)
  定义了 `kSecCSCheckAllArchitectures`、`kSecCSCheckNestedCode`、`kSecCSStrictValidate` 和
  `kSecCSRestrictSymlinks`。当前 provider 组合使用这些只读验证标志，不关闭 executable 或
  resource 验证。
- [`kSecCodeInfoUnique`](https://developer.apple.com/documentation/security/kseccodeinfounique)
  是识别特定静态代码的二进制值，并绑定当前代码版本；Apple 提醒算法未来可能改变，但既有
  签名的值稳定。因此策略保存原始 `Data` 并精确比较，不把它固定解释成某一种哈希算法。
- [Signing Information Dictionary Keys](https://developer.apple.com/documentation/security/signing-information-dictionary-keys)
  将 `kSecCodeInfoTeamIdentifier`、`kSecCodeInfoUnique` 和 designated requirement 列为
  `SecCodeCopySigningInformation` 的结构化签名事实。
- [`kSecCodeInfoPList`](https://developer.apple.com/documentation/security/kseccodeinfoplist)
  返回 Code Signing Services 看到的 secured `Info.plist` 字典；该值可能缺失，且不应被替换为
  `CFBundle` 自行补充后的字典。
- [`SecCodeCopySigningInformation`](https://developer.apple.com/documentation/security/seccodecopysigninginformation%28_%3A_%3A_%3A%29)
  对 `SecStaticCode` 返回磁盘签名信息。Apple 明确要求先成功调用 validity check，才能确保只
  返回有效数据并让无效数据产生错误；当前实现复用完成严格验证的同一静态代码对象。
- [Code Signing Requirement Language](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html)
  说明 requirement 可精确约束 identifier、证书 Team Identifier 和 `cdhash`；Code Directory
  是主程序页面及特殊资源哈希的主目录，可用于识别一个具体产物版本。

## 本项目采用的边界

1. `TrustedMacFUSEPolicy` 的签名目录必须非空，键集合与 `approvedVersions` 完全一致，并且每个
   版本使用不同的 Code Directory identity；缺少 composite policy 时 `SystemSetupFactsLoader`
   返回 `notConfigured`。
2. requirement 先由 Security framework 编译；然后对固定 bundle 路径创建
   `SecStaticCode`，严格验证所有架构、嵌套代码、资源和符号链接约束。
3. 只有验证成功后才从同一 `SecStaticCode` 读取 Team Identifier、Code Directory 标识和
   `kSecCodeInfoPList`。secured identifier/version 必须存在、严格解析，并与文件系统 reader
   已核对的 identifier/version及所选版本目录项一致。
4. 路径逐层 `O_NOFOLLOW`、owner 和写权限检查继续保留。它们降低验证后的替换风险，但不能把
   pathname 验证扩大解释为未来执行器的 FD-bound 启动保证。
5. 目录缺项、多项、重复 identity，任一 secured 字段缺失或格式非法，签名无效、requirement
   不满足、Team ID/Code Directory/identifier/version 不一致，都返回固定失败类型；诊断与 UI
   不显示路径、requirement 内容、secured plist 内容或签名原始数据。

## 未验证项

- 尚未从上游一手发布材料取得可批准的 macFUSE 精确 requirement、Team Identifier 与
  Code Directory 标识。
- 尚未完成 Gate 2 镜像矩阵，也没有生产 `TrustedMacFUSEPolicy`。
- 本能力不安装依赖、不启动代码、不授权真实挂载，也不替代 Developer ID、公证或 Gate 5。
