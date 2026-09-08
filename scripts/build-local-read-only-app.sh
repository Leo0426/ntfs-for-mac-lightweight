#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
build_dir="$project_dir/.build"
app_dir="$build_dir/NTFSLiteReadOnlyApp.app"
staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/ntfs-lite-app.XXXXXX")
staging_app="$staging_dir/NTFSLiteReadOnlyApp.app"

cleanup() {
    rm -rf "$staging_dir"
}
trap cleanup EXIT

cd "$project_dir"
"$project_dir/scripts/check-read-only-boundary.sh"
swift build \
    -c release \
    --product NTFSLiteReadOnlyApp \
    -Xswiftc -warnings-as-errors
binary_dir=$(swift build -c release --show-bin-path)

mkdir -p "$staging_app/Contents/MacOS"
install -m 755 \
    "$binary_dir/NTFSLiteReadOnlyApp" \
    "$staging_app/Contents/MacOS/NTFSLiteReadOnlyApp"
install -m 644 \
    "$project_dir/AppResources/NTFSLiteReadOnlyApp-Info.plist" \
    "$staging_app/Contents/Info.plist"

plutil -lint "$staging_app/Contents/Info.plist"
codesign --force --sign - "$staging_app"
"$project_dir/scripts/verify-local-read-only-app.sh" "$staging_app"

if [[ -e "$app_dir" ]]; then
    rm -rf "$app_dir"
fi
mv "$staging_app" "$app_dir"

print -r -- "$app_dir"
