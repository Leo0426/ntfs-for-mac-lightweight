import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from file_cycle import prepare
from manifest_io import save_manifest


class VerifyFilesCLIChecks(unittest.TestCase):
    def test_cli_failures_report_stage_and_preserve_remaining_files(self):
        for kind in ('manifest-corrupted', 'manifest-missing', 'file-corrupted',
                     'file-missing', 'unknown-entry', 'root-missing'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                base = Path(directory).resolve()
                root = base / 'volume'
                root.mkdir()
                manifest = prepare(root)
                path = base / 'manifest.json'
                save_manifest(path, manifest)
                workspace = root / manifest['directory']
                selected_root = root
                if kind == 'manifest-corrupted':
                    path.write_bytes(b'{')
                elif kind == 'manifest-missing':
                    path.unlink()
                elif kind == 'file-corrupted':
                    (workspace / 'append.bin').write_bytes(b'corrupt')
                elif kind == 'file-missing':
                    (workspace / 'append.bin').unlink()
                elif kind == 'unknown-entry':
                    (workspace / 'unknown.txt').write_bytes(b'preserve')
                else:
                    selected_root = base / 'missing'
                before = {entry.name: entry.read_bytes() for entry in workspace.iterdir()}
                result = subprocess.run([sys.executable, '-I', str(Path(__file__).with_name('verify_files.py')),
                                         '--root', str(selected_root), '--manifest', str(path)],
                                        capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 1)
                report = json.loads(result.stdout)
                self.assertEqual(report['status'], 'failed')
                self.assertEqual(report['stage'], 'manifestRead' if kind.startswith('manifest-') else 'fileReadback')
                self.assertFalse(report['remountVerified'])
                self.assertFalse(report['windowsVerified'])
                self.assertNotIn(str(base), result.stdout.decode())
                self.assertEqual(result.stderr, b'')
                self.assertEqual({entry.name: entry.read_bytes() for entry in workspace.iterdir()}, before)

    def test_cli_independently_reads_saved_expectations_without_claiming_remount(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            root, evidence = base / 'volume', base / 'evidence'
            root.mkdir()
            evidence.mkdir()
            manifest = prepare(root)
            path = evidence / 'manifest.json'
            save_manifest(path, manifest)
            workspace = root / manifest['directory']
            before = {entry.name: entry.read_bytes() for entry in workspace.iterdir()}
            result = subprocess.run([sys.executable, '-I', str(Path(__file__).with_name('verify_files.py')),
                                     '--root', str(root), '--manifest', str(path)],
                                    capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            report = json.loads(result.stdout)
            self.assertEqual(report, {'status': 'fileChecksPassed',
                                      'retainedFiles': len(manifest['files']),
                                      'deletedEntries': len(manifest['deleted']),
                                      'remountVerified': False, 'windowsVerified': False})
            self.assertEqual({entry.name: entry.read_bytes() for entry in workspace.iterdir()}, before)
            self.assertEqual(result.stderr, b'')


if __name__ == '__main__':
    unittest.main()
