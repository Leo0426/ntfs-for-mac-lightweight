"""Pinned identity-reduction experiment; never installs or modifies device permissions."""
from contextlib import contextmanager
import ctypes
import hashlib
import os
from pathlib import Path
import stat

from usb_target import require

BASE = Path(__file__).resolve().parents[2]
DRIVER = BASE / '.build/dependency-candidates/ntfs-3g-user-mount-v2-build/src/ntfs-3g'
DRIVER_SHA256 = '3e512072bcb53b5d4af0582b23c980e2c679aacc36afdf0f2a330317dbf01d86'
MOUNT_UID, MOUNT_GID = 501, 20


def process_groups():
    # os.getgroups() may use Darwin's account-default variant. The public libc
    # symbol below returns the actual process list affected by setgroups().
    call = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True).getgroups
    call.argtypes, call.restype = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint)], ctypes.c_int
    count = call(0, None)
    require(0 < count <= 1024, 'processGroupQueryFailed')
    values = (ctypes.c_uint * count)()
    require(call(count, values) == count, 'processGroupsChanged')
    return list(values)


def candidate():
    require((BASE.stat().st_uid, BASE.stat().st_gid) == (MOUNT_UID, MOUNT_GID),
            'candidateOwnerChanged')
    info = DRIVER.lstat()
    require(DRIVER.resolve(strict=True) == DRIVER and stat.S_ISREG(info.st_mode)
            and info.st_uid == MOUNT_UID and info.st_nlink == 1
            and not info.st_mode & 0o6022, 'unsafeMountCandidate')
    require(hashlib.sha256(DRIVER.read_bytes()).hexdigest() == DRIVER_SHA256,
            'mountCandidateDigestChanged')
    return DRIVER


@contextmanager
def filesystem_identity():
    """Single-threaded supervisor's file checks only; never spawn a child in this scope.

    The driver drops all IDs permanently in C. This separate supervisor retains its
    original identity for system observations after leaving a file-check scope.
    """
    uid, gid, groups = os.geteuid(), os.getegid(), process_groups()
    require(os.getuid() == uid and os.getgid() == gid
            and (uid == 0 or (uid, gid) == (MOUNT_UID, MOUNT_GID)), 'unexpectedSupervisorIdentity')
    if uid != 0:
        yield
        return
    try:
        os.setgroups([MOUNT_GID])
        os.setegid(MOUNT_GID)
        os.seteuid(MOUNT_UID)
        require((os.geteuid(), os.getegid(), process_groups()) ==
                (MOUNT_UID, MOUNT_GID, [MOUNT_GID]), 'filesystemIdentityDropFailed')
        yield
    finally:
        os.seteuid(uid)
        os.setegid(gid)
        os.setgroups(groups)
        require((os.geteuid(), os.getegid(), process_groups()) == (uid, gid, groups),
                'supervisorIdentityRestoreFailed')


def unmount_credentials():
    """Give the unmount child permanent user IDs when the supervisor is root."""
    return dict(user=MOUNT_UID, group=MOUNT_GID, extra_groups=[MOUNT_GID]) if os.geteuid() == 0 else {}
