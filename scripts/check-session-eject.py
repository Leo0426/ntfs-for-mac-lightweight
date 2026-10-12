#!/usr/bin/env python3
"""Compile session eligibility checks against production source; never touches disks."""
from pathlib import Path
import platform
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parent.parent

def main():
    binary = Path(subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=ROOT, text=True).strip())
    modules = ['NTFSLiteCore', 'NTFSLiteSystem', 'NTFSLiteHelperProtocol', 'NTFSLiteStrictJSON', 'NTFSLiteHelperExecution', 'NTFSLiteMutationPreparation', 'NTFSLiteReadOnlyProbing']
    objects = []
    for module in modules:
        product = binary / (module + '.o')
        selected = [product] if product.is_file() else sorted((binary / (module + '.build')).glob('*.o'))
        assert selected, 'missing Release objects: ' + module
        objects.extend(selected)
    module_dir = binary / 'Modules' if (binary / 'Modules').is_dir() else binary
    with tempfile.TemporaryDirectory(prefix='ntfslite-session-eject-') as folder:
        output = Path(folder) / 'SessionEjectChecks'
        subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '6', '-warnings-as-errors', '-target', platform.machine() + '-apple-macosx15.4', '-I', str(module_dir), str(ROOT / 'Sources/NTFSLiteWriteSession/WriteSession.swift'), str(ROOT / 'Tests/SessionEjectChecks/main.swift'), *map(str, objects), '-o', str(output)], check=True, cwd=ROOT)
        subprocess.run([str(output)], check=True, cwd=ROOT)

if __name__ == '__main__':
    main()
