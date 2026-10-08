#!/bin/zsh
# Local first-install package only. Distribution signing/notarization is Gate 5.
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"
"$project_dir/scripts/build-local-app.sh"

app="$project_dir/.build/NTFSLite.app"
output="$project_dir/.build/NTFSLite-local.pkg"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ "$version" =~ '^[0-9]+(\.[0-9]+){1,3}$' ]] \
    || { print -u2 -r -- "FAIL: App 版本不适合 pkgbuild。"; exit 1; }

staging=$(mktemp -d "$project_dir/.build/ntfslite-installer.XXXXXX")
trap 'rm -rf "$staging"' EXIT
payload_app="$staging/root/Library/PrivilegedHelperTools/NTFSLite.app"
mkdir -p "$staging/root/Library/PrivilegedHelperTools" "$staging/scripts"
ditto --norsrc --noextattr --noacl "$app" "$payload_app"
codesign --verify --strict --deep "$payload_app"
install -m 755 "$project_dir/scripts/installer-scripts/preinstall" "$staging/scripts/preinstall"
install -m 755 "$project_dir/scripts/installer-scripts/check-protected-install-target.sh" \
    "$staging/scripts/check-protected-install-target.sh"

cat > "$staging/components.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
  <dict>
    <key>RootRelativeBundlePath</key><string>Library/PrivilegedHelperTools/NTFSLite.app</string>
    <key>BundleIsRelocatable</key><false/>
    <key>BundleIsVersionChecked</key><true/>
    <key>BundleHasStrictIdentifier</key><true/>
    <key>BundleOverwriteAction</key><string>upgrade</string>
  </dict>
</array>
</plist>
PLIST
plutil -lint -s "$staging/components.plist"

# pkgbuild encodes system-domain payload ownership as root:wheel in its BOM.
pkgbuild --root "$staging/root" \
    --scripts "$staging/scripts" \
    --component-plist "$staging/components.plist" \
    --install-location / \
    --identifier com.leolu.ntfslite.local-installer \
    --version "$version" \
    --ownership recommended \
    "$staging/NTFSLite-local.pkg"

python3 "$project_dir/scripts/verify-local-installer.py" "$staging/NTFSLite-local.pkg" "$app"
mv -f "$staging/NTFSLite-local.pkg" "$output"
print -r -- "PASS: 已构建并离线核验首次安装包：$output"
