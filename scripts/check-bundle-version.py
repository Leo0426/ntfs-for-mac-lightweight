#!/usr/bin/env python3
"""Check trusted bundle metadata using private scratch fixtures, with bounded FIFO read."""
from pathlib import Path
import platform
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parent.parent

def main():
    binary = Path(subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=ROOT, text=True).strip())
    modules = ['NTFSLiteCore']
    objects = []
    for module in modules:
        product = binary / (module + '.o')
        selected = [product] if product.is_file() else sorted((binary / (module + '.build')).glob('*.o'))
        assert selected, 'missing Release objects: ' + module
        objects.extend(selected)
    module_dir = binary / 'Modules' if (binary / 'Modules').is_dir() else binary
    with tempfile.TemporaryDirectory(prefix='ntfslite-bundle-version-') as folder, tempfile.TemporaryDirectory(prefix='bundle-fixture-', dir=ROOT / '.scratch/session') as fixture:
        output = Path(folder) / 'BundleVersionChecks'
        subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '6', '-warnings-as-errors', '-target', platform.machine() + '-apple-macosx15.4', '-I', str(module_dir), str(ROOT / 'Sources/NTFSLiteSystem/TrustedBundleVersionReader.swift'), str(ROOT / 'Tests/BundleVersionChecks/main.swift'), *map(str, objects), '-o', str(output)], check=True, cwd=ROOT)
        subprocess.run([str(output), '--fixture-root', fixture], check=True, cwd=ROOT)
        subprocess.run([str(output), '--fixture-root', fixture, '--fifo'], check=True, cwd=ROOT, timeout=3)

if __name__ == '__main__':
    main()
