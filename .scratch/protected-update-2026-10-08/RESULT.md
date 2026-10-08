# 受保护更新到 0.1.5（6）

日期：2026-10-08（Asia/Shanghai）。状态：待安装。

## 已完成

- `main` 合并受保护安装分支与恢复的 Codex 快照后，`scripts/check.sh` 与
  `scripts/check-read-only-boundary.sh` 通过。版本提升为 0.1.5（6），因为它在 0.1.4（5）之外还含诊断摘要与
  检查器修复。
- `scripts/build-local-installer.sh` 构建并离线核验 pkg；摘要、大小与逐文件摘要见 `package-metadata.json`。
- 更新前只读核对：已安装 0.1.3（4）逐文件摘要与 `../fskit-runtime-preflight-fix/root-update.py` 的
  `OLD_FILES` 一致，固定签名通过；无 App/helper/驱动进程、FSKit/macFUSE 挂载或运行时探针目录；
  v1、v2 均不在 launchd。
- `root-update.py` 与 0.1.4 的一次性维护脚本逻辑相同，仅替换包路径、摘要、大小、预期文件摘要与版本。

## 首次执行

用户报告已执行脚本，但随后只读复核：安装件仍为 0.1.3（4）、修改时间未变，没有新的 root 暂存或回退
目录，也没有维护锁。脚本在变更前退出或未以 root 运行；失败原因待取得原始输出，不推断为安全或成功。
