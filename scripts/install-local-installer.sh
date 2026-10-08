#!/bin/zsh
# First-install only. Run from an interactive terminal; sudo prompts for the administrator password.
set -euo pipefail

project_dir=${0:A:h:h}
package="$project_dir/.build/NTFSLite-local.pkg"
app="$project_dir/.build/NTFSLite.app"
stage_parent=/private/var/tmp
stage=""

fail() {
    print -u2 -r -- "FAIL: $1"
    exit 1
}

valid_stage_path() {
    local candidate=$1
    [[ "${candidate:h}" == "$stage_parent" ]] &&
        [[ "${candidate:t}" =~ '^ntfslite-install\.[A-Za-z0-9]{8}$' ]]
}

cleanup_stage() {
    local old_stage=$stage
    [[ -n "$old_stage" ]] || return 0
    stage=""
    valid_stage_path "$old_stage" || {
        print -u2 -r -- "FAIL: 暂存路径异常，已拒绝自动清理：$old_stage"
        return 1
    }
    if ! /usr/bin/sudo /bin/zsh -c '
        set -euo pipefail
        stage=$1
        [[ "${stage:h}" == /private/var/tmp ]] || exit 1
        [[ "${stage:t}" =~ "^ntfslite-install\\.[A-Za-z0-9]{8}$" ]] || exit 1
        [[ ! -L "$stage" ]] || exit 1
        [[ ! -e "$stage" ]] && exit 0
        [[ -d "$stage" ]] || exit 1
        /bin/rm -f -- "$stage/package.pkg"
        /bin/rmdir -- "$stage"
    ' ntfslite "$old_stage"; then
        print -u2 -r -- "FAIL: root 暂存目录清理失败：$old_stage"
        return 1
    fi
}

(( $# == 0 )) || fail "用法：scripts/install-local-installer.sh"
[[ -f "$package" && ! -L "$package" ]] || fail "本地 pkg 缺失或不是普通文件。"
[[ -d "$app" && ! -L "$app" ]] || fail "待核对的签名 App 缺失。"

# The caller opens the pkg before sudo. Root only receives its bytes on stdin,
# so a replaced source path cannot make root read a different protected file.
stage=$(/usr/bin/sudo /bin/zsh -c '
    set -euo pipefail
    stage_parent=/private/var/tmp
    [[ -d "$stage_parent" && ! -L "$stage_parent" && -k "$stage_parent" ]] || exit 1
    [[ $(/usr/bin/stat -f %u "$stage_parent") == $EUID ]] || exit 1
    umask 077
    stage=$(/usr/bin/mktemp -d "$stage_parent/ntfslite-install.XXXXXXXX")
    cleanup() {
        /bin/rm -f -- "$stage/package.pkg"
        /bin/rmdir -- "$stage"
    }
    trap cleanup EXIT
    /bin/cat > "$stage/package.pkg"
    [[ -s "$stage/package.pkg" ]] || exit 1
    /bin/chmod -N "$stage" "$stage/package.pkg"
    /bin/chmod 0444 "$stage/package.pkg"
    /bin/chmod 0755 "$stage"
    print -r -- "$stage"
    trap - EXIT
' ntfslite < "$package")
valid_stage_path "$stage" || fail "root 暂存路径不符合固定格式。"
trap cleanup_stage EXIT

# This verifier runs without privilege, against bytes that the caller can read
# but cannot change. The user-writable .build package is never used again.
/usr/bin/python3 "$project_dir/scripts/verify-local-installer.py" "$stage/package.pkg" "$app"
digest=$(/usr/bin/shasum -a 256 "$stage/package.pkg" | /usr/bin/awk '{print $1}')
[[ "$digest" =~ '^[0-9a-f]{64}$' ]] || fail "暂存 pkg 的 SHA-256 无效。"

/usr/bin/sudo /bin/zsh -c '
    set -euo pipefail
    stage=$1
    expected=$2
    [[ "${stage:h}" == /private/var/tmp ]] || exit 1
    [[ "${stage:t}" =~ "^ntfslite-install\\.[A-Za-z0-9]{8}$" ]] || exit 1
    [[ "$expected" =~ "^[0-9a-f]{64}$" ]] || exit 1
    package="$stage/package.pkg"
    [[ -d "$stage" && ! -L "$stage" ]] || exit 1
    [[ -f "$package" && ! -L "$package" ]] || exit 1
    [[ $(/usr/bin/stat -f "%u:%Lp" "$stage") == "$EUID:755" ]] || exit 1
    [[ $(/usr/bin/stat -f "%u:%Lp" "$package") == "$EUID:444" ]] || exit 1
    actual=$(/usr/bin/shasum -a 256 "$package" | /usr/bin/awk "{print \$1}")
    [[ "$actual" == "$expected" ]] || exit 1
    /usr/sbin/installer -pkg "$package" -target /
' ntfslite "$stage" "$digest" || fail "root 复核或 Installer 失败；安装结果需手动核对。"

cleanup_stage || fail "root 暂存目录未完成清理。"
trap - EXIT
print -r -- "PASS: Installer 已使用通过离线验证与 root SHA-256 复核的暂存 pkg。"
