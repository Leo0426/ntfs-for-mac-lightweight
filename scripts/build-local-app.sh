#!/bin/zsh
# Formal local app with the privileged helper (ADR 0010/0011), signed with the local Apple
# Development identity. Distribution still needs Developer ID + notarization (Gate 5).
set -euo pipefail

project_dir=${0:A:h:h}
team=NP3U2GYHWL
app_dir="$project_dir/.build/NTFSLite.app"
staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/ntfs-lite-app.XXXXXX")
staging_app="$staging_dir/NTFSLite.app"
trap 'rm -rf "$staging_dir"' EXIT

cd "$project_dir"
"$project_dir/scripts/check-read-only-boundary.sh" >/dev/null
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development:/ {print $2; exit}')
[[ -n "$identity" ]] || { print -u2 -r -- "FAIL: 没有找到 Apple Development 签名身份。"; exit 1; }

for product in NTFSLiteReadOnlyApp NTFSLiteHelper; do
    swift build -c release --product "$product" -Xswiftc -warnings-as-errors >/dev/null
done
binary_dir=$(swift build -c release --show-bin-path)

mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Library/LaunchDaemons" "$staging_app/Contents/Helpers" "$staging_app/Contents/Resources"
install -m 755 "$binary_dir/NTFSLiteReadOnlyApp" "$staging_app/Contents/MacOS/NTFSLiteReadOnlyApp"
install -m 755 "$binary_dir/NTFSLiteHelper" "$staging_app/Contents/MacOS/NTFSLiteHelper"
install -m 644 AppResources/NTFSLiteReadOnlyApp-Info.plist "$staging_app/Contents/Info.plist"
install -m 644 AppResources/NTFSLite.icns "$staging_app/Contents/Resources/NTFSLite.icns"
[[ "$(shasum -a 256 AppResources/FSKitRuntimeProbe.ntfs.zlib | awk '{print $1}')" == "bc13f484e9bc508733246b1bc2145068041b883a5eaad32273106d54c09d7c34" ]] \
    || { print -u2 -r -- "FAIL: 固定镜像种子摘要不符。"; exit 1; }
install -m 644 AppResources/FSKitRuntimeProbe.ntfs.zlib "$staging_app/Contents/Resources/FSKitRuntimeProbe.ntfs.zlib"
install -m 644 AppResources/com.leolu.ntfslite.helper.v2.plist \
    "$staging_app/Contents/Library/LaunchDaemons/com.leolu.ntfslite.helper.v2.plist"
plutil -lint -s "$staging_app/Contents/Info.plist" "$staging_app/Contents/Library/LaunchDaemons/"*.plist

# Pinned NTFS-3G candidates, digests checked before re-signing (see .scratch/write-delete-validation).
typeset -A pinned=(
    ntfs-3g "$project_dir/.build/dependency-candidates/ntfs-3g-user-mount-v2-build/src/ntfs-3g:3e512072bcb53b5d4af0582b23c980e2c679aacc36afdf0f2a330317dbf01d86"
    ntfs-3g.probe "$project_dir/.build/dependency-candidates/ntfs-3g-build/src/ntfs-3g.probe:c917ddbf3c2350513d534139ef38dbb55b6c7a52957832e4744e3f77e82a625b"
)
for name in ${(k)pinned}; do
    source_path=${pinned[$name]%:*}
    digest=${pinned[$name]##*:}
    [[ "$(shasum -a 256 "$source_path" | awk '{print $1}')" == "$digest" ]] \
        || { print -u2 -r -- "FAIL: 固定驱动摘要不符：$name"; exit 1; }
    install -m 755 "$source_path" "$staging_app/Contents/Helpers/$name"
done

quiet_sign() { codesign --force --timestamp=none --sign "$identity" "$@" 2>/dev/null; }
# The drivers load macFUSE's libfuse (another team), so they are signed without library validation.
quiet_sign --identifier com.leolu.ntfslite.ntfs-3g "$staging_app/Contents/Helpers/ntfs-3g"
quiet_sign --identifier com.leolu.ntfslite.ntfs-3g.probe "$staging_app/Contents/Helpers/ntfs-3g.probe"
quiet_sign --options runtime --identifier com.leolu.ntfslite.helper.v2 "$staging_app/Contents/MacOS/NTFSLiteHelper"
quiet_sign --options runtime "$staging_app"

# Verification: exact file allowlist, strict signatures, identifiers and team.
expected=$'Contents/Helpers/ntfs-3g\nContents/Helpers/ntfs-3g.probe\nContents/Info.plist\nContents/Library/LaunchDaemons/com.leolu.ntfslite.helper.v2.plist\nContents/MacOS/NTFSLiteHelper\nContents/MacOS/NTFSLiteReadOnlyApp\nContents/Resources/FSKitRuntimeProbe.ntfs.zlib\nContents/Resources/NTFSLite.icns\nContents/_CodeSignature/CodeResources'
actual=$(cd "$staging_app" && find . \( -type f -o -type l \) | sed 's|^\./||' | LC_ALL=C sort)
[[ "$actual" == "$expected" ]] || { print -u2 -r -- "FAIL: App 包文件清单与允许列表不一致。"; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$staging_app/Contents/Info.plist")" == "NTFSLite.icns" \
    && "$(sips -g format "$staging_app/Contents/Resources/NTFSLite.icns" 2>/dev/null)" == *$'format: icns'* ]] \
    || { print -u2 -r -- "FAIL: App 图标声明或资源无效。"; exit 1; }
codesign --verify --strict --deep "$staging_app"
typeset -A identifiers=(
    . com.leolu.ntfslite.readonly
    Contents/MacOS/NTFSLiteHelper com.leolu.ntfslite.helper.v2
    Contents/Helpers/ntfs-3g com.leolu.ntfslite.ntfs-3g
    Contents/Helpers/ntfs-3g.probe com.leolu.ntfslite.ntfs-3g.probe
)
for item in ${(k)identifiers}; do
    details=$(codesign -dv "$staging_app/$item" 2>&1)
    [[ "$details" == *$'\n'"Identifier=${identifiers[$item]}"$'\n'* && "$details" == *$'\n'"TeamIdentifier=$team"$'\n'* ]] \
        || { print -u2 -r -- "FAIL: 签名标识或 Team ID 不符：$item"; exit 1; }
done

rm -rf "$app_dir"
mv "$staging_app" "$app_dir"
print -r -- "PASS: 已构建并核验签名 App：$app_dir"
