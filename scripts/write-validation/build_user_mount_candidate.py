"""Build one isolated local candidate; never install it or overwrite the base build."""
import difflib
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from usb_lab import BASE, BUILD, dependencies, require

DESTINATION = BASE / '.build/dependency-candidates/ntfs-3g-user-mount-v2-build'
INPUTS = {
    BUILD / 'src/ntfs-3g.c': '452d34c2a15c708d318e2436c4e6d7cc8b8dda67e3fd113a9c3ee7cfba219c12',
    BUILD / 'libntfs-3g/.libs/libntfs-3g.a': '14f8ff81a47a81a9bde81eab43d2d9662f465c911942007d89686b69b0c62a01',
}


def main():
    require(sys.argv[1:] == ['--build'], 'explicitBuildArgumentRequired')
    dependencies()
    require(BASE.stat().st_uid == 501 and BASE.stat().st_gid == 20, 'fixedMountUserChanged')
    require(not DESTINATION.exists(), 'candidateBuildAlreadyExists')
    for path, digest in INPUTS.items():
        require(path.resolve(strict=True) == path
                and hashlib.sha256(path.read_bytes()).hexdigest() == digest, 'baseBuildInputChanged')
    original = (BUILD / 'src/ntfs-3g.c').read_text()
    edits = [
        ('#include "ntfs-3g_common.h"', '#include "ntfs-3g_common.h"\n#include "ntfslite_fskit_identity.h"'),
        ('\tif (drop_privs())\n\t\treturn NTFS_VOLUME_NO_PRIVILEGE;',
         '\tif (drop_privs())\n\t\treturn NTFS_VOLUME_NO_PRIVILEGE;\n'
         '\t/* Isolated local experiment: validate the fixed destination identity before storage access. */\n'
         '\tif (ntfslite_identity_preflight(501, 20)) {\n'
         '\t\tntfs_log_error("NTFSLite: identity preflight failed.\\n");\n'
         '\t\treturn NTFS_VOLUME_NO_PRIVILEGE;\n\t}'),
        ('\tfh = mount_fuse(parsed_options);',
         '\t/* Storage is already open. FSKit runs as the fixed local user, without saved root IDs. */\n'
         '\tif (ntfslite_drop_mount_identity(501, 20)) {\n'
         '\t\tntfs_log_error("NTFSLite: identity operation=%s errno=%d ruid=%u euid=%u rgid=%u egid=%u\\n",\n'
         '\t\t    ntfslite_identity_operation, errno, (unsigned)getuid(), (unsigned)geteuid(),\n'
         '\t\t    (unsigned)getgid(), (unsigned)getegid());\n'
         '\t\terr = NTFS_VOLUME_NO_PRIVILEGE;\n\t\tgoto err_out;\n\t}\n'
         '\tntfs_log_info("NTFSLite: FSKit uid=%u gid=%u\\n", (unsigned)geteuid(), (unsigned)getegid());\n'
         '\tfh = mount_fuse(parsed_options);'),
    ]
    modified = original
    for before, after in edits:
        require(modified.count(before) == 1, 'sourcePatchContextChanged')
        modified = modified.replace(before, after)
    shutil.copytree(BUILD, DESTINATION, symlinks=True)
    (DESTINATION / 'src/ntfs-3g.c').write_text(modified)
    header = Path(__file__).resolve().parent / 'ntfslite_fskit_identity.h'
    shutil.copyfile(header, DESTINATION / 'src/ntfslite_fskit_identity.h')
    with (DESTINATION / 'ntfslite-source.patch').open('x') as output:
        output.write(''.join(difflib.unified_diff(original.splitlines(True), modified.splitlines(True),
                                                fromfile='a/src/ntfs-3g.c', tofile='b/src/ntfs-3g.c')))
    with (DESTINATION / 'ntfslite-build.log').open('xb') as log:
        subprocess.run(['/usr/bin/make', '-C', str(DESTINATION / 'src'), 'ntfs-3g'],
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    executable = DESTINATION / 'src/ntfs-3g'
    record = {'experimentOnly': True, 'mountUID': 501, 'mountGID': 20,
              'driverSHA256': hashlib.sha256(executable.read_bytes()).hexdigest(),
              'identityHeaderSHA256': hashlib.sha256(header.read_bytes()).hexdigest(),
              'sourceSHA256': hashlib.sha256(modified.encode()).hexdigest(),
              'baseInputs': {str(p.relative_to(BASE)): digest for p, digest in INPUTS.items()}}
    (DESTINATION / 'ntfslite-build.json').write_text(json.dumps(record, sort_keys=True, indent=2) + '\n')
    print(json.dumps(record, sort_keys=True))


if __name__ == '__main__':
    main()
