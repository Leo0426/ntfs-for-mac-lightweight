#!/bin/zsh
# Issue 02 tracer bundle: the formal app layout plus the privileged helper, its launchd plist
# and a temporary tracer client. Signed with the local Apple Development identity (ADR 0010).
set -euo pipefail

project_dir=${0:A:h:h}
team=NP3U2GYHWL
app_dir="$project_dir/.build/NTFSLiteHelperTracer.app"
staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/ntfs-lite-tracer.XXXXXX")
staging_app="$staging_dir/NTFSLiteHelperTracer.app"
trap 'rm -rf "$staging_dir"' EXIT

cd "$project_dir"
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development:/ {print $2; exit}')
[[ -n "$identity" ]] || { print -u2 -r -- "FAIL: 没有找到 Apple Development 签名身份。"; exit 1; }

for product in NTFSLiteReadOnlyApp NTFSLiteHelper NTFSLiteHelperTracer; do
    swift build -c release --product "$product" -Xswiftc -warnings-as-errors
done
binary_dir=$(swift build -c release --show-bin-path)

mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Library/LaunchDaemons"
for product in NTFSLiteReadOnlyApp NTFSLiteHelper NTFSLiteHelperTracer; do
    install -m 755 "$binary_dir/$product" "$staging_app/Contents/MacOS/$product"
done
install -m 644 AppResources/NTFSLiteReadOnlyApp-Info.plist "$staging_app/Contents/Info.plist"
# Pinned NTFS-3G candidates (digests before re-signing), see .scratch/write-delete-validation.
mkdir -p "$staging_app/Contents/Helpers"
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
install -m 644 AppResources/com.leolu.ntfslite.helper.plist \
    "$staging_app/Contents/Library/LaunchDaemons/com.leolu.ntfslite.helper.plist"
plutil -lint "$staging_app/Contents/Info.plist" "$staging_app/Contents/Library/LaunchDaemons/"*.plist

sign() { codesign --force --options runtime --timestamp=none --sign "$identity" "$@"; }
# The drivers load macFUSE's libfuse (another team), so they are signed without library validation.
codesign --force --timestamp=none --sign "$identity" --identifier com.leolu.ntfslite.ntfs-3g "$staging_app/Contents/Helpers/ntfs-3g"
codesign --force --timestamp=none --sign "$identity" --identifier com.leolu.ntfslite.ntfs-3g.probe "$staging_app/Contents/Helpers/ntfs-3g.probe"
sign --identifier com.leolu.ntfslite.helper "$staging_app/Contents/MacOS/NTFSLiteHelper"
# The tracer acts as the formal app client for the helper's pinned requirement.
sign --identifier com.leolu.ntfslite.readonly "$staging_app/Contents/MacOS/NTFSLiteHelperTracer"
sign "$staging_app"

codesign --verify --strict --deep "$staging_app"
for item in "$staging_app" "$staging_app/Contents/MacOS/NTFSLiteHelper" "$staging_app/Contents/MacOS/NTFSLiteHelperTracer"; do
    details=$(codesign -dv "$item" 2>&1)
    [[ "$details" == *$'\n'"TeamIdentifier=$team"$'\n'* ]] \
        || { print -u2 -r -- "FAIL: Team ID 不符：$item"; exit 1; }
done

rm -rf "$app_dir"
mv "$staging_app" "$app_dir"
print -r -- "$app_dir"
