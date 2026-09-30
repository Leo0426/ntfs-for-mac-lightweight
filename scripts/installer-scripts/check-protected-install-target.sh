#!/bin/zsh
# Read-only first-install guard. The packaged preinstall invokes this with / only.
set -euo pipefail

fail() {
    print -u2 -r -- "FAIL: $1"
    exit 1
}

[[ $# == 1 && "$1" == /* ]] || fail "缺少绝对安装根目录。"
root=$1
[[ "$root" == / || "$root" != */ ]] || fail "安装根目录格式无效。"
[[ ! -L "$root" && -d "$root" ]] || fail "安装根目录不安全。"

root_details=$(/usr/bin/stat -f '%u:%g:%Lp' "$root" 2>/dev/null) \
    || fail "无法核对安装根目录。"
IFS=: read -r expected_uid expected_gid root_mode <<< "$root_details"
[[ "$expected_uid" == <-> && "$expected_gid" == <-> ]] \
    || fail "安装根目录身份未知。"
if [[ "$root" == / ]]; then
    [[ "$expected_uid" == 0 && "$expected_gid" == 0 ]] \
        || fail "系统根目录身份不安全。"
fi

check_directory() {
    local path=$1 details uid gid mode acl_details
    [[ ! -L "$path" && -d "$path" ]] || fail "目录不安全：$path"
    details=$(/usr/bin/stat -f '%u:%g:%Lp' "$path" 2>/dev/null) \
        || fail "目录不安全：$path"
    IFS=: read -r uid gid mode <<< "$details"
    [[ "$uid" == "$expected_uid" && "$gid" == "$expected_gid" \
        && "$mode" =~ '^[0-7]{3,4}$' ]] || fail "目录不安全：$path"
    (( (8#$mode & 8#022) == 0 )) || fail "目录不安全：$path"
    acl_details=$(/bin/ls -lde "$path" 2>/dev/null) \
        || fail "目录不安全：$path"
    [[ "$acl_details" != *$'\n'* ]] || fail "目录不安全：$path"
}

has_entry() {
    local parent=$1 name=$2 found
    found=$(/usr/bin/find "$parent" -mindepth 1 -maxdepth 1 -name "$name" -print 2>/dev/null) \
        || fail "无法完整枚举安装目录：$parent"
    [[ -n "$found" ]]
}

check_directory "$root"
library="${root%/}/Library"
check_directory "$library"
if has_entry "$library" PrivilegedHelperTools; then
    protected="$library/PrivilegedHelperTools"
    check_directory "$protected"
    if has_entry "$protected" NTFSLite.app; then
        fail "目标 App 已存在，禁止覆盖或升级：$protected/NTFSLite.app"
    fi
fi

print -r -- "PASS: 首次安装目标路径空闲且父目录可信。"
