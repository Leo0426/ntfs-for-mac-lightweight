#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"

swift package describe --type json \
    | swift scripts/verify-read-only-package-boundary.swift

assert_package_boundary_rejects() {
    local fixture_name=$1
    local package_json=$2
    local expected_message=$3
    local output

    if output=$(print -rn -- "$package_json" \
        | swift scripts/verify-read-only-package-boundary.swift 2>&1)
    then
        print -u2 -r -- "FAIL: 包边界负向样例未被拒绝：$fixture_name"
        exit 1
    fi

    if [[ "$output" != *"$expected_message"* ]]; then
        print -u2 -r -- "FAIL: 包边界负向样例返回非预期原因：$fixture_name"
        exit 1
    fi
}

assert_package_boundary_rejects \
    "Evidence 进入 mutation" \
    '{"targets":[{"name":"NTFSLiteReadOnlyApp","target_dependencies":[]},{"name":"NTFSLiteGateEvidence","target_dependencies":["NTFSLiteMutationPreparation"]},{"name":"NTFSLiteGate1EvidenceTool","target_dependencies":["NTFSLiteGateEvidence"]},{"name":"NTFSLiteMutationPreparation","target_dependencies":[]}]}' \
    "NTFSLiteGateEvidence 依赖进入变更边界"

assert_package_boundary_rejects \
    "Evidence 间接进入 helper" \
    '{"targets":[{"name":"NTFSLiteReadOnlyApp","target_dependencies":[]},{"name":"NTFSLiteGateEvidence","target_dependencies":["EvidenceBridge"]},{"name":"NTFSLiteGate1EvidenceTool","target_dependencies":["NTFSLiteGateEvidence"]},{"name":"EvidenceBridge","target_dependencies":["NTFSLiteHelperProtocol"]},{"name":"NTFSLiteHelperProtocol","target_dependencies":[]}]}' \
    "NTFSLiteGateEvidence 依赖进入变更边界"

assert_package_boundary_rejects \
    "正式应用间接依赖 Evidence" \
    '{"targets":[{"name":"NTFSLiteReadOnlyApp","target_dependencies":["AppBridge"]},{"name":"AppBridge","target_dependencies":["NTFSLiteGateEvidence"]},{"name":"NTFSLiteGateEvidence","target_dependencies":[]},{"name":"NTFSLiteGate1EvidenceTool","target_dependencies":["NTFSLiteGateEvidence"]}]}' \
    "正式只读应用不得依赖 Evidence 工具链"

assert_package_boundary_rejects \
    "缺少 Evidence root" \
    '{"targets":[{"name":"NTFSLiteReadOnlyApp","target_dependencies":[]},{"name":"NTFSLiteGate1EvidenceTool","target_dependencies":["NTFSLiteGateEvidence"]}]}' \
    "缺少只读 root target：NTFSLiteGateEvidence"

assert_package_boundary_rejects \
    "Evidence Tool 进入 mutation" \
    '{"targets":[{"name":"NTFSLiteReadOnlyApp","target_dependencies":[]},{"name":"NTFSLiteGateEvidence","target_dependencies":[]},{"name":"NTFSLiteGate1EvidenceTool","target_dependencies":["NTFSLiteGateEvidence","NTFSLiteMutationPreparation"]},{"name":"NTFSLiteMutationPreparation","target_dependencies":[]}]}' \
    "NTFSLiteGate1EvidenceTool 依赖进入变更边界"

assert_package_boundary_rejects \
    "Evidence Tool 间接进入 helper" \
    '{"targets":[{"name":"NTFSLiteReadOnlyApp","target_dependencies":[]},{"name":"NTFSLiteGateEvidence","target_dependencies":[]},{"name":"NTFSLiteGate1EvidenceTool","target_dependencies":["NTFSLiteGateEvidence","ToolBridge"]},{"name":"ToolBridge","target_dependencies":["NTFSLiteHelperProtocol"]},{"name":"NTFSLiteHelperProtocol","target_dependencies":[]}]}' \
    "NTFSLiteGate1EvidenceTool 依赖进入变更边界"

assert_package_boundary_rejects \
    "Evidence Tool 绕过 Gate Evidence" \
    '{"targets":[{"name":"NTFSLiteReadOnlyApp","target_dependencies":[]},{"name":"NTFSLiteGateEvidence","target_dependencies":[]},{"name":"NTFSLiteGate1EvidenceTool","target_dependencies":["NTFSLiteSystem"]},{"name":"NTFSLiteSystem","target_dependencies":[]}]}' \
    "Gate1 Evidence Tool 必须直接依赖 Gate Evidence target"

assert_package_boundary_rejects \
    "缺少 Evidence Tool root" \
    '{"targets":[{"name":"NTFSLiteReadOnlyApp","target_dependencies":[]},{"name":"NTFSLiteGateEvidence","target_dependencies":[]}]}' \
    "缺少只读 root target：NTFSLiteGate1EvidenceTool"

assert_package_boundary_rejects \
    "正式应用间接依赖 Evidence Tool" \
    '{"targets":[{"name":"NTFSLiteReadOnlyApp","target_dependencies":["AppBridge"]},{"name":"AppBridge","target_dependencies":["NTFSLiteGate1EvidenceTool"]},{"name":"NTFSLiteGateEvidence","target_dependencies":[]},{"name":"NTFSLiteGate1EvidenceTool","target_dependencies":["NTFSLiteGateEvidence"]}]}' \
    "正式只读应用不得依赖 Evidence 工具链"

print -r -- "PASS: 只读包边界负向样例均按预期失败关闭。"

for source_file in ${(f)"$(grep -R -l -E '\bProcess[[:space:]]*\(' Sources --include='*.swift' || true)"}; do
    if [[ "$source_file" != "Sources/NTFSLiteReadOnlyProbing/BoundedReadOnlyCommandRunner.swift" ]]; then
        print -u2 -r -- "FAIL: 发现边界外的 Process：$source_file"
        exit 1
    fi
done

process_site_count=$(
    grep -R -E '\bProcess[[:space:]]*\(' Sources --include='*.swift' \
        | wc -l \
        | tr -d '[:space:]'
)
if [[ "$process_site_count" != "1" ]]; then
    print -u2 -r -- "FAIL: 固定 Setup 探针之外的 Process 数量发生变化。"
    exit 1
fi

grep -q -F \
    'func run(invocation: SetupProbeInvocation) async -> ReadOnlyCommandResult' \
    Sources/NTFSLiteReadOnlyProbing/BoundedReadOnlyCommandRunner.swift

for source_file in ${(f)"$(grep -R -l -F 'BoundedReadOnlyCommandRunner()' Sources --include='*.swift' || true)"}; do
    if [[ "$source_file" != "Sources/NTFSLiteReadOnlyProbing/SetupProbing.swift" \
        && "$source_file" != "Sources/NTFSLiteCoreChecks/main.swift" ]]; then
        print -u2 -r -- "FAIL: 固定 Setup 探针 runner 被产品边界外调用：$source_file"
        exit 1
    fi
done

grep -q -F \
    'private struct HelperRequestDecoder: Sendable' \
    Sources/NTFSLiteHelperProtocol/HelperProtocol.swift

if grep -q -E \
    'package (struct HelperRequestDecoder|actor HelperOperationIDReplayGuard)' \
    Sources/NTFSLiteHelperProtocol/HelperProtocol.swift
then
    print -u2 -r -- "FAIL: helper 解码或重放消费重新暴露为可绕过原子准入的 package 接口。"
    exit 1
fi

if grep -R -n -E \
    'DADisk(Unmount|Eject|Mount)|/sbin/(mount|umount)|/usr/sbin/diskutil|posix_spawn|remove_hiberfile|allow_other|backend=kext' \
    Sources \
    --include='*.swift' \
    --exclude-dir='NTFSLiteCoreChecks'
then
    print -u2 -r -- "FAIL: 产品源码出现禁止的磁盘变更 API 或策略。"
    exit 1
fi

if grep -R -n -E \
    '^import (NTFSLiteMutationPreparation|NTFSLiteHelperProtocol)$' \
    Sources/NTFSLiteReadOnlyApp \
    Sources/NTFSLiteGateEvidence \
    Sources/NTFSLiteGate1EvidenceTool \
    Sources/NTFSLitePresentation \
    Sources/NTFSLiteDiagnostics \
    Sources/NTFSLiteSystem \
    Sources/NTFSLiteCore
then
    print -u2 -r -- "FAIL: 只读产品模块导入了变更或 helper 模块。"
    exit 1
fi

if ! grep -R -q -E \
    '^import NTFSLiteGateEvidence$' \
    Sources/NTFSLiteGate1EvidenceTool \
    --include='*.swift'
then
    print -u2 -r -- "FAIL: Gate1 Evidence Tool 未通过 Gate Evidence 模块。"
    exit 1
fi

if grep -R -n -E \
    '^import (NTFSLiteGateEvidence|NTFSLiteGate1EvidenceTool)$' \
    Sources/NTFSLiteReadOnlyApp \
    --include='*.swift'
then
    print -u2 -r -- "FAIL: 正式只读应用导入了 Evidence 工具链。"
    exit 1
fi

print -r -- "PASS: 只读源码边界未发现真实磁盘变更入口。"
