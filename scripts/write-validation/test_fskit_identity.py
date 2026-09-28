from pathlib import Path
import subprocess
import tempfile
import unittest


class FSKitIdentityChecks(unittest.TestCase):
    def test_darwin_build_reads_process_groups_instead_of_account_default_groups(self):
        header = Path(__file__).resolve().parent / 'ntfslite_fskit_identity.h'
        with tempfile.TemporaryDirectory() as directory:
            source, binary = Path(directory) / 'groups.c', Path(directory) / 'groups-check'
            source.write_text('#include "ntfslite_fskit_identity.h"\n'
                              'int main(void) { return ntfslite_drop_mount_identity(501, 20); }\n')
            built = subprocess.run(['/usr/bin/clang', '-std=gnu23', '-D_DARWIN_C_SOURCE=1',
                                    '-I', str(header.parent), str(source), '-o', str(binary)],
                                   capture_output=True, text=True, timeout=30)
            self.assertEqual(built.returncode, 0, built.stderr)
            symbols = subprocess.run(['/usr/bin/nm', '-u', str(binary)], check=True,
                                     capture_output=True, text=True, timeout=10).stdout.splitlines()
            self.assertIn('_getgroups', symbols)
            self.assertNotIn('_getgroups$DARWIN_EXTSN', symbols)

    def test_permanent_driver_drop_and_failure_paths_at_system_call_boundary(self):
        header = Path(__file__).resolve().parent / 'ntfslite_fskit_identity.h'
        program = r'''
#include <sys/types.h>
#include <unistd.h>
#include <grp.h>
#include <errno.h>
#include <assert.h>
static uid_t real_uid, effective_uid;
static gid_t real_gid, effective_gid, only_group;
static int steps, fail_step, lie;
static uid_t test_getuid(void) { return real_uid; }
static uid_t test_geteuid(void) { return effective_uid; }
static gid_t test_getgid(void) { return real_gid; }
static gid_t test_getegid(void) { return effective_gid; }
static int test_setgroups(int count, const gid_t *groups) {
    steps = steps * 10 + 1;
    if (fail_step == 1) return -1;
    assert(count == 1); only_group = groups[0]; return 0;
}
static int test_setgid(gid_t gid) {
    steps = steps * 10 + 2;
    if (fail_step == 2) return -1;
    real_gid = effective_gid = gid; return 0;
}
static int test_setuid(uid_t uid) {
    steps = steps * 10 + 3;
    if (fail_step == 3) return -1;
    if (!lie) real_uid = effective_uid = uid;
    return 0;
}
static int test_getgroups(int count, gid_t *groups) {
    assert(count >= 1); groups[0] = only_group; return 1;
}
#define getuid test_getuid
#define geteuid test_geteuid
#define getgid test_getgid
#define getegid test_getegid
#define setgroups test_setgroups
#define setgid test_setgid
#define setuid test_setuid
#define getgroups test_getgroups
#include "ntfslite_fskit_identity.h"
static void reset(void) {
    real_uid = effective_uid = 0; real_gid = effective_gid = 0;
    steps = fail_step = lie = 0; only_group = 0;
}
int main(void) {
    reset(); assert(ntfslite_identity_preflight(501, 20) == 0); assert(steps == 0);
    assert(ntfslite_drop_mount_identity(501, 20) == 0);
    assert(steps == 123 && real_uid == 501 && effective_uid == 501);
    assert(real_gid == 20 && effective_gid == 20 && only_group == 20);
    reset(); assert(ntfslite_identity_preflight(0, 20) == -1 && steps == 0);
    reset(); real_uid = 501; assert(ntfslite_identity_preflight(501, 20) == -1);
    for (int i = 1; i <= 3; ++i) {
        reset(); fail_step = i; assert(ntfslite_drop_mount_identity(501, 20) == -1);
        assert(steps == (i == 1 ? 1 : i == 2 ? 12 : 123));
    }
    reset(); lie = 1; assert(ntfslite_drop_mount_identity(501, 20) == -1);
    reset(); real_uid = effective_uid = 501; real_gid = effective_gid = 20;
    assert(ntfslite_drop_mount_identity(501, 20) == 0 && steps == 0);
    reset(); real_uid = effective_uid = 502;
    assert(ntfslite_drop_mount_identity(501, 20) == -1 && steps == 0);
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'identity.c'
            binary = Path(directory) / 'identity-check'
            source.write_text(program)
            built = subprocess.run(['/usr/bin/clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                                    '-I', str(header.parent), str(source), '-o', str(binary)],
                                   capture_output=True, text=True, timeout=30)
            self.assertEqual(built.returncode, 0, built.stderr)
            checked = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
            self.assertEqual(checked.returncode, 0, checked.stderr)


if __name__ == '__main__':
    unittest.main()
