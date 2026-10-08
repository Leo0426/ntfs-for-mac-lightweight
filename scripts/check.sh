#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"

# Build every product once before running checks against its Release binary.
swift build -c release -Xswiftc -warnings-as-errors
binary_dir=$(swift build -c release --show-bin-path)
"$binary_dir/NTFSLiteCoreChecks"
python3 scripts/check-app-store-observation.py
standalone_checks=$(mktemp -d "${TMPDIR:-/tmp}/ntfslite-standalone-checks.XXXXXX")
trap 'rm -rf "$standalone_checks"' EXIT
swiftc -parse-as-library -warnings-as-errors \
    Sources/NTFSLiteProtectedInstall/SecureHelperDeployment.swift \
    Tests/SecureHelperDeploymentChecks/SecureHelperDeploymentChecks.swift \
    -o "$standalone_checks/NTFSLiteSecureHelperDeploymentChecks"
"$standalone_checks/NTFSLiteSecureHelperDeploymentChecks"
swiftc -parse-as-library -warnings-as-errors \
    Sources/NTFSLiteHelperExecution/BoundedMainRunLoopWait.swift \
    Tests/BoundedMainRunLoopWaitChecks/main.swift \
    -o "$standalone_checks/NTFSLiteBoundedMainRunLoopWaitChecks"
"$standalone_checks/NTFSLiteBoundedMainRunLoopWaitChecks"
swiftc -parse-as-library -warnings-as-errors \
    Sources/NTFSLiteHelper/HelperIdleExitGate.swift \
    Tests/HelperIdleExitGateChecks/main.swift \
    -o "$standalone_checks/NTFSLiteHelperIdleExitGateChecks"
"$standalone_checks/NTFSLiteHelperIdleExitGateChecks"
swiftc -parse-as-library -swift-version 6 -warnings-as-errors \
    Sources/NTFSLiteHelperExecution/RuntimeProbeCoordinator.swift \
    Tests/RuntimeProbeChecks/main.swift -o "$standalone_checks/RuntimeProbeChecks"
"$standalone_checks/RuntimeProbeChecks"
swiftc -parse-as-library -swift-version 6 -warnings-as-errors \
    Sources/NTFSLiteHelperExecution/RuntimeProbeCoordinator.swift \
    Sources/NTFSLiteHelperExecution/RuntimeProbeChildWaiter.swift \
    Tests/RuntimeProbeChildChecks/main.swift -o "$standalone_checks/RuntimeProbeChildChecks"
"$standalone_checks/RuntimeProbeChildChecks"
swiftc -parse-as-library -swift-version 6 -warnings-as-errors \
    Sources/NTFSLiteHelper/RuntimeProbeSeed.swift \
    Tests/RuntimeProbeSeedChecks/main.swift -o "$standalone_checks/RuntimeProbeSeedChecks"
"$standalone_checks/RuntimeProbeSeedChecks" AppResources/FSKitRuntimeProbe.ntfs.zlib
python3 scripts/check-gate1-cli-input.py
python3 -m unittest discover -s scripts/write-validation -p 'test_*.py'

# The builder checks source/package boundaries and verifies the signed bundle.
scripts/build-local-read-only-app.sh
scripts/check-local-read-only-app-negative-fixtures.sh

print -r -- "PASS: 严格 Release、行为、CLI、只读边界和本地 App 检查全部通过。"
