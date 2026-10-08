#!/bin/zsh
# One-shot root uninstall of the protected NTFSLite install (2026-10-08, user request).
# Fails closed before any change if the App, helper or driver runs, or an FSKit/macFUSE
# filesystem is mounted writable. Never touches disks, mounts, or other apps' BTM records.
set -euo pipefail
setopt nullglob

fail() { print -u2 -r -- "FAIL: $1"; exit 1; }
[[ $EUID -eq 0 ]] || fail "需要以 root 运行。"

app=/Library/PrivilegedHelperTools/NTFSLite.app
receipt=com.leolu.ntfslite.local-installer
labels=(com.leolu.ntfslite.helper.v2 com.leolu.ntfslite.helper)

# Preconditions: nothing of ours runs and no writable FSKit/macFUSE filesystem is mounted.
procs=$(/bin/ps -axo comm=) || fail "无法读取进程列表。"
[[ ${(L)procs} == *ntfslite* || ${(L)procs} == *ntfs-3g* ]] \
    && fail "NTFSLite App、helper 或 ntfs-3g 进程仍在运行；请先退出 App。"
mounts=$(/sbin/mount) || fail "无法读取挂载列表。"
for row in ${(f)mounts}; do
    [[ ${(L)row} == *(fskit|macfuse)* && ${(L)row} != *read-only* ]] \
        && fail "存在非只读的 FSKit/macFUSE 挂载：$row"
done
[[ ! -e /Library/PrivilegedHelperTools/.NTFSLite-maintenance-lock ]] \
    || fail "维护锁存在，可能有更新在进行。"

# 1. Remove our jobs from launchd (only these exact labels).
for label in $labels; do
    if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
        /bin/launchctl bootout "system/$label" || fail "无法从 launchd 移除 $label。"
    fi
    /bin/launchctl print "system/$label" >/dev/null 2>&1 && fail "$label 仍在 launchd 中。"
    print -r -- "launchd: $label 已不在 system 域"
done

# 2. Remove installed files and our own root-only maintenance/diagnostic leftovers.
targets=($app /private/var/tmp/ntfslite-maintenance-* /private/var/tmp/ntfslite-readonly-diag-*
         /private/var/db/com.leolu.ntfslite.runtime-probe)
for target in $targets; do
    [[ -e $target || -L $target ]] || continue
    /bin/rm -rf -- "$target"
    print -r -- "removed: $target"
done

# 3. Forget the installer receipt so a later install starts as a first install.
if /usr/sbin/pkgutil --pkg-info $receipt >/dev/null 2>&1; then
    /usr/sbin/pkgutil --forget $receipt
fi

# Postconditions.
[[ ! -e $app ]] || fail "$app 仍存在。"
/usr/sbin/pkgutil --pkg-info $receipt >/dev/null 2>&1 && fail "安装收据仍存在。"
print -r -- "--- 剩余 BTM 记录（只读，供复核）:"
/usr/bin/sfltool dumpbtm 2>/dev/null | /usr/bin/grep -E 'leolu|NTFSLite' || print -r -- "(无)"
print -r -- "PASS: NTFSLite 受保护安装件、launchd 任务、维护/诊断残留与安装收据已移除。"
