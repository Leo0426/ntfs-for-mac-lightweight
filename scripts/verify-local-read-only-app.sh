#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
    print -u2 -r -- "用法：scripts/verify-local-read-only-app.sh <NTFSLiteReadOnlyApp.app>"
    exit 2
fi

app_dir=$1
if [[ ! -d "$app_dir" || -L "$app_dir" ]]; then
    print -u2 -r -- "FAIL: App 路径不存在、不是目录或是符号链接。"
    exit 1
fi

info_plist="$app_dir/Contents/Info.plist"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
if [[ ! -d "$contents_dir" || -L "$contents_dir" \
    || ! -d "$macos_dir" || -L "$macos_dir" ]]
then
    print -u2 -r -- "FAIL: Contents 或 MacOS 目录缺失或是符号链接。"
    exit 1
fi
if [[ ! -f "$info_plist" || -L "$info_plist" ]]; then
    print -u2 -r -- "FAIL: Info.plist 缺失或不可信。"
    exit 1
fi

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$info_plist"
}

bundle_id=$(plist_value CFBundleIdentifier)
executable_name=$(plist_value CFBundleExecutable)
short_version=$(plist_value CFBundleShortVersionString)
build_version=$(plist_value CFBundleVersion)
minimum_system=$(plist_value LSMinimumSystemVersion)

if [[ "$bundle_id" != "com.leolu.ntfslite.readonly" ]]; then
    print -u2 -r -- "FAIL: bundle identifier 不符合只读应用策略。"
    exit 1
fi
if [[ "$executable_name" != "NTFSLiteReadOnlyApp" ]]; then
    print -u2 -r -- "FAIL: 主可执行文件名不符合只读应用策略。"
    exit 1
fi
if [[ ! "$short_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || ! "$build_version" =~ '^[1-9][0-9]*$' \
    || ! "$minimum_system" =~ '^[0-9]+\.[0-9]+$' ]]
then
    print -u2 -r -- "FAIL: 版本、构建号或最低系统版本格式不符合策略。"
    exit 1
fi

binary="$macos_dir/$executable_name"
if [[ ! -f "$binary" || -L "$binary" || ! -x "$binary" ]]; then
    print -u2 -r -- "FAIL: 主可执行文件缺失、不可执行或是符号链接。"
    exit 1
fi

setopt local_options null_glob dot_glob
contents_entries=("$contents_dir"/*(DN))
macos_entries=("$macos_dir"/*(DN))
if (( ${#contents_entries[@]} != 3 )) \
    || [[ ! -e "$contents_dir/Info.plist" \
        || ! -d "$contents_dir/MacOS" \
        || ! -d "$contents_dir/_CodeSignature" ]]
then
    print -u2 -r -- "FAIL: Contents 不符合本地只读包的固定允许清单。"
    exit 1
fi
if (( ${#macos_entries[@]} != 1 )) || [[ "${macos_entries[1]}" != "$binary" ]]; then
    print -u2 -r -- "FAIL: MacOS 目录必须且只能包含批准的主程序入口。"
    exit 1
fi
if [[ -n "$(find "$contents_dir" -type l -print -quit)" ]]; then
    print -u2 -r -- "FAIL: 本地只读 App 不允许包含符号链接。"
    exit 1
fi
if [[ -n "$(find "$contents_dir" ! -type d ! -type f -print -quit)" ]]; then
    print -u2 -r -- "FAIL: 本地只读 App 不允许包含特殊文件。"
    exit 1
fi

for forbidden_dir in \
    "$app_dir/Contents/Library/LaunchServices" \
    "$app_dir/Contents/PlugIns" \
    "$app_dir/Contents/XPCServices"
do
    if [[ -e "$forbidden_dir" ]]; then
        print -u2 -r -- "FAIL: 只读本地包不应包含 helper、插件或 XPC 服务。"
        exit 1
    fi
done

architectures=$(lipo -archs "$binary")
if [[ "$architectures" != "arm64" ]]; then
    print -u2 -r -- "FAIL: 本地候选必须是单一 Apple Silicon arm64 架构。"
    exit 1
fi

build_metadata=$(vtool -show-build "$binary")
build_command_count=$(awk '$1 == "cmd" && $2 == "LC_BUILD_VERSION" { count += 1 } END { print count + 0 }' <<<"$build_metadata")
binary_platform=$(awk '$1 == "platform" { print $2 }' <<<"$build_metadata")
binary_minimum_system=$(awk '$1 == "minos" { print $2 }' <<<"$build_metadata")
if [[ "$build_command_count" != "1" || "$binary_platform" != "MACOS" ]]
then
    print -u2 -r -- "FAIL: Mach-O build version 命令或平台不符合策略。"
    exit 1
fi
if [[ "$binary_minimum_system" != "$minimum_system" ]]; then
    print -u2 -r -- "FAIL: Info.plist 与 Mach-O 最低系统版本不一致。"
    exit 1
fi
if [[ "$minimum_system" != "15.4" ]]; then
    print -u2 -r -- "FAIL: deployment target 不符合固定的 macOS 15.4 策略。"
    exit 1
fi

plutil -lint "$info_plist" >/dev/null
codesign --verify --strict "$app_dir"

binary_sha256=$(shasum -a 256 "$binary" | awk '{print $1}')
plist_sha256=$(shasum -a 256 "$info_plist" | awk '{print $1}')

print -r -- "PASS: 本地只读 App 允许清单、版本、Mach-O、arm64 与代码签名校验通过。"
print -r -- "版本：$short_version ($build_version)"
print -r -- "最低系统：macOS $minimum_system"
print -r -- "架构：$architectures"
print -r -- "签名范围：本地 ad-hoc；不构成 Developer ID、公证或 Gate 5 证据。"
print -r -- "主程序 SHA-256：$binary_sha256"
print -r -- "Info.plist SHA-256：$plist_sha256"
