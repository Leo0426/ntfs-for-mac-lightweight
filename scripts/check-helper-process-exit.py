#!/usr/bin/env python3
"""Read process state and reap only the test's naturally exited child; no disk operations."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='ntfslite-process-exit-') as folder:
    executable = pathlib.Path(folder) / 'ExitChecks'
    subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors',
                    str(root / 'Sources/NTFSLiteHelper/HelperProcessExitReader.swift'),
                    str(root / 'Tests/HelperProcessExitChecks/main.swift'),
                    '-o', str(executable)], cwd=root, check=True)
    subprocess.run([str(executable)], cwd=root, check=True)
