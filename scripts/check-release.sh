#!/bin/zsh
# Formal LOCAL deliverable gate. Developer ID/notarized distribution remains Gate 5.
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"
stage=development
trap 'print -u2 -r -- "BLOCKED: 正式本机发布检查未通过（阶段：$stage）；不得报告正式发布通过。签名或固定依赖缺失须先解决。"' ZERR

scripts/check.sh
stage=signedInstallerBuild
scripts/build-local-installer.sh
stage=offlineInstallerVerification
python3 scripts/verify-local-installer.py .build/NTFSLite-local.pkg .build/NTFSLite.app
stage=installerRegression
python3 -m unittest discover -s scripts -p 'test_*local_installer.py'

print -r -- "PASS: 正式本机发布制品（签名 App/helper/driver/seed/daemon/pkg）及离线安装检查通过；外部分发、公证与磁盘实测不在此结论内。"
