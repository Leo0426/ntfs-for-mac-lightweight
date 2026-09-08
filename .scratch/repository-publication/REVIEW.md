# 首次仓库提交审查

日期：2026-09-08

## 范围

本地原无 Git 历史，目标远程无 refs，因此以空树到当前工作区作为首次导入范围。
纳入源码、脚本、产品/领域文档、本地工单和已脱敏 Gate 证据；排除 `.build/`、根目录
Swift 编译产物及本机配置。原有证据保持原样，不把历史报告重写成当前版本的验证结果。

采用独立 Standards / Spec 两轴审查，主审复核原始证据后实施修复。初审固定快照包含
139 个文本文件；修复后对 10 个改动文件再次独立复核，并确认工作区与审查快照一致。

## 发现与修复

| 项目 | 初审类别 | 修复与验证 |
| --- | --- | --- |
| 不同盘复用 BSD 名仍可累计同一 Gate target | Standards blocking、Spec blocking | 会话内固定规范化候选 UUID 清单；同连接和重插换身份均原子拒绝，不写出原始身份 |
| 直接进程退出但输出未取得 EOF 仍报成功 | Standards blocking | stdout、stderr 都必须完成 EOF；未完成返回 `outputUnreadable`，保留时间上界与原有失败优先级 |
| Setup 冲突成功提示未限定范围 | Spec suggestion | 明确为批准范围内无冲突，展示断言固定语义 |

三项修改均先通过公共接口/已有行为检查观察到 RED，再以最小实现达到 GREEN。
补充回归覆盖失败 artifact 封存与核验、原始身份隐私、正常成功/非零退出，以及两路输出
各自出现延迟尾部的情形。另增加 `scripts/check.sh` 统一现有检查，README 提供代码导航，
`.gitignore` 排除生成文件。

最终审查：Standards blocking 0 / suggestion 0；Spec blocking 0 / suggestion 0。

## 验证

本地 `scripts/check.sh` 完整退出 0：

- 全量 Release 构建，warnings-as-errors。
- 209 项行为检查。
- CLI 开放 stdin、部分输入、畸形行、显式 seal、EOF 和读取失败回归。
- 只读依赖/源码边界与包图负向样例。
- 本地 arm64 App 构建、ad-hoc 签名、allowlist 和 deployment target 验证。
- 5 组篡改 App 负向样例。

导入文件扫描未发现凭据或真实用户路径；命中的 `/Users/...` 字符串是隐私测试和原型的
虚构样例。Markdown 本地链接检查通过。日志留在本机临时目录，不把构建日志中的本机路径
纳入本次记录。

## 验证边界

本次没有执行磁盘变更或新增实物 Gate 证据。UUID 克隆、真实物理盘连续性、100 轮插拔、
Windows 完整性复核、人工 UI/VoiceOver 和正式签名仍按实施计划处理。匿名 schema 2 不能
独立证明原始盘身份，旧 artifact 不会自动获得本次新增的采集期身份保证。
