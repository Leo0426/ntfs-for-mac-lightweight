# 固定依赖并完成 Gate 2 镜像验证

Status: ready-for-human
Labels: enhancement, ready-for-human
Assignee:
Blocked-by: 02-gate1-hardware-evidence, 07-bounded-setup-probes, 08-ejectability-facts, 10-mount-engine-contract, 11-exact-macfuse-trust-policy, 15-macfuse-signing-evidence-policy, 17-current-connection-data-declaration, 18-candidate-scoped-conflict-footprint-probe, 22-bind-macfuse-version-and-signature-same-entry

## 验收

- 从一手来源批准精确 macFUSE、NTFS-3G 版本、身份与摘要；不自动接受更新版本。
  macFUSE 的所选精确版本、requirement、Team ID、CodeDirectory identity 与同一已验证
  `SecStaticCode` 的 secured identifier/version 必须位于同一批准条目，不允许跨版本复用 identity。
- 批准具名、带目标平台和制品摘要的有限冲突目录；loaded identifier、固定 installed footprint
  与环境基线共同完整，且任何范围/版本/摘要变化会重新打开验证。
- 写入前的当前连接声明必须与 fresh candidate、精确 sibling 拓扑和本次请求一致；声明不替代
  健康、挂载、身份或依赖等系统证据。
- 一次性 NTFS 镜像完成健康、dirty、休眠、超时、崩溃和卸载残留矩阵。
- 执行器关闭最终路径 TOCTOU，且没有 kext、Reduced Security、SIP 降级或恢复写入选项。
- 取得新 ADR 后才允许 XPC、helper 安装或真实执行。

## 评论

当前正式 App 的信任策略故意为空，Setup 必须保持未就绪。
