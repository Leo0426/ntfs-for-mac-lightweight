import os
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from file_cycle import ValidationError, prepare, verify, cleanup


class FileCycleChecks(unittest.TestCase):
    def test_file_operations_survive_independent_readback_and_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest = prepare(root)
            self.assertEqual(manifest['status'], 'fileChecksPassed')
            self.assertFalse(manifest['windowsVerified'])
            self.assertGreaterEqual(manifest['checks'], 6)
            verify(root, manifest)
            cleanup(root, manifest)
            self.assertEqual(list(root.iterdir()), [])

    def test_missing_file_cannot_be_hidden_by_truncating_the_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest = prepare(root)
            (root / manifest['directory'] / 'empty.bin').unlink()
            del manifest['files']['empty.bin']
            with self.assertRaises(ValidationError):
                verify(root, manifest)

    def test_corruption_prevents_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest = prepare(root)
            workspace = root / manifest['directory']
            (workspace / 'append.bin').write_bytes(b'corrupted')
            with self.assertRaises(ValidationError):
                cleanup(root, manifest)
            self.assertEqual(set(p.name for p in workspace.iterdir()), set(manifest['files']))

    def test_unknown_entries_prevent_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest = prepare(root)
            workspace = root / manifest['directory']
            (workspace / 'unrelated.txt').write_text('preserve')
            with self.assertRaises(ValidationError):
                cleanup(root, manifest)
            self.assertEqual((workspace / 'unrelated.txt').read_text(), 'preserve')
            self.assertTrue((workspace / 'empty.bin').exists())

    def test_symlink_and_hardlink_replacements_preserve_external_file(self):
        for link in ('symlink', 'hardlink'):
            with self.subTest(link=link), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                manifest = prepare(root)
                target = root / 'external.bin'
                target.write_bytes(b'keep')
                victim = root / manifest['directory'] / 'empty.bin'
                victim.unlink()
                if link == 'symlink':
                    victim.symlink_to(target)
                else:
                    os.link(target, victim)
                with self.assertRaises((ValidationError, OSError)):
                    cleanup(root, manifest)
                self.assertEqual(target.read_bytes(), b'keep')
                self.assertTrue(victim.is_symlink() if link == 'symlink' else victim.exists())

    def test_large_stream_handles_a_partial_final_block(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest = prepare(root, large_bytes=1024 * 1024 + 1)
            self.assertEqual(manifest['files']['large.bin']['bytes'], 1024 * 1024 + 1)
            verify(root, manifest)
            cleanup(root, manifest)
            self.assertEqual(list(root.iterdir()), [])

    def test_rename_replaces_existing_target_with_exact_source_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest = prepare(root)
            workspace = root / manifest['directory']
            self.assertEqual((workspace / 'renamed.bin').read_bytes(), b'replacement')
            self.assertFalse((workspace / 'replace-source.bin').exists())
            verify(root, manifest)
            cleanup(root, manifest)

    def test_fifo_replacement_is_rejected_without_waiting_for_a_writer(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest = prepare(root)
            victim = root / manifest['directory'] / 'empty.bin'
            victim.unlink()
            os.mkfifo(victim)
            code = 'import json,sys; from file_cycle import verify; verify(sys.argv[1], json.loads(sys.argv[2]))'
            result = subprocess.run([sys.executable, '-c', code, str(root), json.dumps(manifest)],
                                    cwd=Path(__file__).resolve().parent, capture_output=True, timeout=3)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'unsafeFile', result.stderr)

    def test_replacement_during_readback_cannot_report_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest = prepare(root)
            victim = root / manifest['directory'] / 'empty.bin'
            inode = victim.stat().st_ino
            original_read = os.read
            replaced = False
            def read(descriptor, size):
                nonlocal replaced
                if not replaced and os.fstat(descriptor).st_ino == inode:
                    replacement = victim.with_name('pending-replacement')
                    replacement.write_bytes(b'corrupt-current-path')
                    replacement.replace(victim)
                    replaced = True
                return original_read(descriptor, size)
            with patch('os.read', side_effect=read), self.assertRaises(ValidationError):
                verify(root, manifest)
            self.assertTrue(replaced)
            self.assertEqual(victim.read_bytes(), b'corrupt-current-path')


if __name__ == '__main__':
    unittest.main()
