/* Isolated experiment only. This helper never grants or restores root privileges.
 * The pinned driver checks identity before opening storage, then permanently drops
 * real, effective AND saved IDs after opening it and before calling FUSE/FSKit.
 * macOS setuid(2)/setgid(2) provide those semantics when called by root.
 */
#ifndef NTFSLITE_FSKIT_IDENTITY_H
#define NTFSLITE_FSKIT_IDENTITY_H
#include <sys/types.h>
#include <unistd.h>
#include <grp.h>
#include <errno.h>

/* Darwin's extended alias reports account defaults, ignoring setgroups(). Bind
 * the documented process-list variant explicitly even in _DARWIN_C_SOURCE builds.
 * Keep the ordinary spelling for syscall-boundary fixtures and other platforms. */
#if defined(__APPLE__) && !defined(getgroups)
extern int ntfslite_process_groups(int, gid_t *) __asm("_getgroups");
#else
#define ntfslite_process_groups getgroups
#endif

static const char *ntfslite_identity_operation = "notStarted";

static int ntfslite_identity_preflight(uid_t uid, gid_t gid)
{
    ntfslite_identity_operation = "identityPreflight";
    if (!uid || !gid || getuid() != geteuid() || getgid() != getegid()
        || (geteuid() && (geteuid() != uid || getegid() != gid))) {
        errno = EPERM;
        return -1;
    }
    return 0;
}

static int ntfslite_drop_mount_identity(uid_t uid, gid_t gid)
{
    int was_root;
    int count;
    gid_t observed[2];
    if (ntfslite_identity_preflight(uid, gid))
        return -1;
    was_root = geteuid() == 0;
    if (was_root) {
        ntfslite_identity_operation = "setgroups";
        if (setgroups(1, &gid)) return -1;
        ntfslite_identity_operation = "setgid";
        if (setgid(gid)) return -1;
        ntfslite_identity_operation = "setuid";
        if (setuid(uid)) return -1;
    }
    ntfslite_identity_operation = "verifyIDs";
    if (getuid() != uid || geteuid() != uid || getgid() != gid || getegid() != gid) {
        errno = EPERM;
        return -1;
    }
    if (was_root) {
        ntfslite_identity_operation = "verifyProcessGroups";
        count = ntfslite_process_groups(2, observed);
        if (count < 0) return -1;
        if (count != 1 || observed[0] != gid) { errno = EPERM; return -1; }
    }
    ntfslite_identity_operation = "identityVerified";
    return 0;
}
#endif
