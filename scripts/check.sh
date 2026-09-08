#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"

# Build every product once before running checks against its Release binary.
swift build -c release -Xswiftc -warnings-as-errors
binary_dir=$(swift build -c release --show-bin-path)
"$binary_dir/NTFSLiteCoreChecks"
python3 scripts/check-gate1-cli-input.py

# The builder checks source/package boundaries and verifies the signed bundle.
scripts/build-local-read-only-app.sh
scripts/check-local-read-only-app-negative-fixtures.sh

print -r -- "PASS: 严格 Release、行为、CLI、只读边界和本地 App 检查全部通过。"
