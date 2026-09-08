#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
verify_script="$project_dir/scripts/verify-local-read-only-app.sh"

if [[ $# -gt 1 ]]; then
    print -u2 -r -- "用法：scripts/check-local-read-only-app-negative-fixtures.sh [NTFSLiteReadOnlyApp.app]"
    exit 2
fi

source_app=${1:-"$project_dir/.build/NTFSLiteReadOnlyApp.app"}
fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/ntfs-lite-negative.XXXXXX")

cleanup() {
    local target=${fixture_root:-}
    if [[ -n "$target" && -d "$target" \
        && "${target:t}" == ntfs-lite-negative.* ]]
    then
        rm -rf -- "$target"
    fi
}
trap cleanup EXIT

make_fixture() {
    local name=$1
    local fixture="$fixture_root/$name/NTFSLiteReadOnlyApp.app"
    mkdir -p "${fixture:h}"
    /usr/bin/ditto --norsrc "$source_app" "$fixture"
    print -r -- "$fixture"
}

plist_deployment_target() {
    /usr/libexec/PlistBuddy \
        -c "Print :LSMinimumSystemVersion" \
        "$1/Contents/Info.plist"
}

macho_deployment_target() {
    vtool -show-build "$1/Contents/MacOS/NTFSLiteReadOnlyApp" \
        | awk '$1 == "minos" { print $2 }'
}

require_deployment_mismatch() {
    local fixture=$1
    local declared_target
    local binary_target
    declared_target=$(plist_deployment_target "$fixture")
    binary_target=$(macho_deployment_target "$fixture")
    if [[ "$declared_target" == "$binary_target" ]]; then
        print -u2 -r -- "FAIL: deployment target 不一致 fixture 未成功构造。"
        exit 1
    fi
}

require_deployment_target() {
    local fixture=$1
    local expected_target=$2
    local declared_target
    local binary_target
    declared_target=$(plist_deployment_target "$fixture")
    binary_target=$(macho_deployment_target "$fixture")
    if [[ "$declared_target" != "$expected_target" \
        || "$binary_target" != "$expected_target" ]]
    then
        print -u2 -r -- "FAIL: 错误 deployment target fixture 未成功构造。"
        exit 1
    fi
}

expect_rejected() {
    local label=$1
    local fixture=$2
    local expected_message=$3
    local output
    if output=$("$verify_script" "$fixture" 2>&1); then
        print -u2 -r -- "FAIL: $label 未被验证器拒绝。"
        exit 1
    fi
    if [[ "$output" != *"$expected_message"* ]]; then
        print -u2 -r -- "FAIL: $label 虽被拒绝，但未命中预期边界。"
        print -u2 -r -- "$output"
        exit 1
    fi
    print -r -- "PASS: $label 被验证器按预期拒绝。"
}

positive_output=$("$verify_script" "$source_app")
if [[ "$positive_output" != *"主程序 SHA-256"* \
    || "$positive_output" != *"Info.plist SHA-256"* \
    || "$positive_output" != *"本地 ad-hoc"* \
    || "$positive_output" != *"Gate 5"* ]]
then
    print -u2 -r -- "FAIL: 正向验证输出缺少摘要或 ad-hoc/Gate 5 边界说明。"
    exit 1
fi

symlink_fixture=$(make_fixture extra-symlink)
ln -s ../Info.plist \
    "$symlink_fixture/Contents/_CodeSignature/unapproved-link"
expect_rejected \
    "额外符号链接" \
    "$symlink_fixture" \
    "本地只读 App 不允许包含符号链接"

special_file_fixture=$(make_fixture extra-special-file)
mkfifo "$special_file_fixture/Contents/_CodeSignature/unapproved-pipe"
expect_rejected \
    "额外特殊文件" \
    "$special_file_fixture" \
    "本地只读 App 不允许包含特殊文件"

entry_fixture=$(make_fixture extra-ordinary-entry)
install -m 755 \
    "$source_app/Contents/MacOS/NTFSLiteReadOnlyApp" \
    "$entry_fixture/Contents/MacOS/UnapprovedEntry"
codesign --force --sign - "$entry_fixture" >/dev/null 2>&1
expect_rejected \
    "额外普通可执行入口" \
    "$entry_fixture" \
    "MacOS 目录必须且只能包含批准的主程序入口"

plist_mismatch_fixture=$(make_fixture plist-deployment-mismatch)
/usr/libexec/PlistBuddy \
    -c "Set :LSMinimumSystemVersion 15.5" \
    "$plist_mismatch_fixture/Contents/Info.plist"
codesign --force --sign - "$plist_mismatch_fixture" >/dev/null 2>&1
require_deployment_mismatch "$plist_mismatch_fixture"
expect_rejected \
    "Info.plist 与 Mach-O deployment target 不一致" \
    "$plist_mismatch_fixture" \
    "Info.plist 与 Mach-O 最低系统版本不一致"

wrong_target_fixture=$(make_fixture wrong-deployment-target)
/usr/libexec/PlistBuddy \
    -c "Set :LSMinimumSystemVersion 15.5" \
    "$wrong_target_fixture/Contents/Info.plist"
wrong_target_binary="$wrong_target_fixture/Contents/MacOS/NTFSLiteReadOnlyApp"
wrong_target_sdk=$(vtool -show-build "$wrong_target_binary" \
    | awk '$1 == "sdk" { print $2 }')
rewritten_binary="$fixture_root/NTFSLiteReadOnlyApp-wrong-target"
vtool_log="$fixture_root/vtool.log"
if ! vtool \
    -set-build-version macos 15.5 "$wrong_target_sdk" \
    -replace \
    -output "$rewritten_binary" \
    "$wrong_target_binary" \
    >"$vtool_log" 2>&1
then
    print -u2 -r -- "FAIL: 无法构造错误 deployment target fixture。"
    print -u2 -r -- "$(<"$vtool_log")"
    exit 1
fi
install -m 755 "$rewritten_binary" "$wrong_target_binary"
codesign --force --sign - "$wrong_target_fixture" >/dev/null 2>&1
require_deployment_target "$wrong_target_fixture" "15.5"
expect_rejected \
    "错误 deployment target" \
    "$wrong_target_fixture" \
    "deployment target 不符合固定的 macOS 15.4 策略"

print -r -- "PASS: 5 组本地只读包负向 fixture 全部按预期失败关闭。"
