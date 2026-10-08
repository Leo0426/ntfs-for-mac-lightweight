#!/bin/zsh
# Read-only post-install check. No helper registration or disk operation.
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"
swift build -c release --product NTFSLiteProtectedInstallVerifier -Xswiftc -warnings-as-errors >/dev/null
binary_dir=$(swift build -c release --show-bin-path)
"$binary_dir/NTFSLiteProtectedInstallVerifier"
