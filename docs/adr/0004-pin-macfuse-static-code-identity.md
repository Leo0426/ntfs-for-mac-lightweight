---
status: accepted
---

# 用组合式静态代码证据固定 macFUSE 身份

macFUSE 的版本、bundle identifier、owner 和权限只能说明安装形状，不能证明当前字节就是
Gate 2 批准的制品。本项目把每个精确版本映射到唯一的指定代码需求、Team Identifier 和
`kSecCodeInfoUnique` Code Directory 二进制标识，并通过 Security framework 严格验证静态代码；
同一 `SecStaticCode` 返回的 secured Info.plist identifier/version 还必须与文件系统读取结果及
所选版本目录项一致。没有完整生产策略时保持 `notConfigured`，任何已配置证据的缺失、矛盾、
漂移或跨时点拼接都失败关闭。这样把平台签名格式和 sealed resources 校验隐藏在一个 typed
reader 后面，也避免新增命令行解析或通用进程入口。

## Considered Options

- 只核对路径、owner、权限、bundle identifier 和版本：拒绝，因为同版本目录仍可能被替换，
  也无法绑定批准签名身份与具体产物。
- 用一个版本集合搭配单一签名身份：拒绝，因为 pathname 可在版本读取与签名验证之间被替换，
  从而把版本 A 与签名制品 B 拼成一个从未批准的组合。
- 执行 `codesign` 并解析文字输出：拒绝，因为它会新增进程和易漂移的文本协议，并扩大当前
  固定只读探针边界。
- 自行定义整个 bundle 的递归摘要：拒绝作为运行时签名身份，因为元数据与资源规范化规则会
  形成第二套签名语义；源码归档和构建产物 SHA-256 仍保留在 Gate 2 供应链记录中。
- 使用 Security framework 的静态代码验证和结构化签名信息：接受，因为系统负责验证所有
  架构、嵌套代码与 sealed resources，调用方只需比较批准的 typed identity。

## Consequences

- 签名目录必须非空，键集合与版本策略的批准版本完全相等；每个版本对应唯一 Code Directory
  标识，不允许两个版本共享同一静态代码身份。
- 精确版本、指定需求、Team ID、Code Directory 标识，以及 Code Signing Services 看到的
  secured bundle identifier/version 必须来自同一个批准条目，不能独立拼接。
- `SecCodeCopySigningInformation` 必须复用已经严格验证的同一 `SecStaticCode`；secured Info.plist
  缺失、格式非法，或与文件系统版本/identifier及所选目录项不一致时失败关闭。
- `kSecCodeInfoUnique` 保持原始 `Data` 精确比较，不假设固定哈希算法；批准新版本必须生成新的
  完整策略和 Gate 2 证据。
- 签名验证结果只对未被后续修改的代码有效；未来真实执行器仍需关闭验证到启动之间的 TOCTOU，
  本 ADR 不授权 helper、依赖安装或真实磁盘变更。
- 生产策略在一手来源与镜像矩阵完成前保持为空，测试 provider 只用于验证失败关闭契约。
- Apple API 依据和当前未验证项见
  [`docs/research/macos-code-signing-evidence.md`](../research/macos-code-signing-evidence.md)。
