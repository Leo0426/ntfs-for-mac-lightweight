#!/usr/bin/env python3
"""Compile the real helper adapter and exercise only read-only nonexistent-device facts."""
import pathlib
import sys
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
binary_dir = pathlib.Path(subprocess.check_output(
    ['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=root, text=True).strip())
with tempfile.TemporaryDirectory(prefix='ntfslite-disk-presence-') as folder:
    tmp = pathlib.Path(folder)
    # This package-internal source uses System's public path validation helpers.
    uuid_reader = tmp / 'MountedFileSystemUUIDReader.swift'
    uuid_reader.write_text('import NTFSLiteSystem\n' +
        (root / 'Sources/NTFSLiteSystem/MountedFileSystemUUIDReader.swift').read_text())
    sources = ['HelperProcessResourceReader.swift', 'HelperProcessExitReader.swift', 'LiveWritableMountSystem.swift',
               'LiveRuntimeProbeSystem.swift', 'MountUserAgent.swift', 'RuntimeProbeSeed.swift']
    objects = ['NTFSLiteHelperExecution', 'NTFSLiteHelperProtocol', 'NTFSLiteSystem',
               'NTFSLiteCore', 'NTFSLiteReadOnlyProbing', 'NTFSLiteProtectedInstall', 'NTFSLiteStrictJSON']
    executable = tmp / 'DiskPresenceChecks'
    command = ['swiftc', '-warnings-as-errors', '-package-name', 'NTFSLite', '-I', str(binary_dir)]
    command += [str(root / 'Sources/NTFSLiteHelper' / file) for file in sources]
    command += [str(uuid_reader), str(root / 'Tests/HelperDiskPresenceChecks/main.swift')]
    command += [str(binary_dir / (module + '.o')) for module in objects]
    command += ['-o', str(executable)]
    subprocess.run(command, cwd=root, check=True)
    subprocess.run([str(executable)] + sys.argv[1:], cwd=root, check=True)
