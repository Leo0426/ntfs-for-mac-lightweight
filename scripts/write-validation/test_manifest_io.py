import json
import copy
import hashlib
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from file_cycle import ValidationError, cleanup, prepare, verify
from manifest_io import load_manifest, save_manifest


class ManifestIOChecks(unittest.TestCase):
    def test_malformed_documents_and_manifest_types_fail_with_validation_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest = prepare(root)
            path = root / 'manifest.json'
            save_manifest(path, manifest)
            valid = path.read_bytes()
            def document(value):
                raw = (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode('ascii')
                return (json.dumps({'schema': 1, 'manifest': value,
                                    'sha256': hashlib.sha256(raw).hexdigest()},
                                   sort_keys=True, separators=(',', ':')) + '\n').encode('ascii')
            invalid = [valid[:-5], b'\xff', b'null', b'[]', b'{',
                       b'[' * 2000 + b']' * 2000,
                       valid.replace(b'"schema":1', b'"schema":1,"schema":1', 1),
                       valid.replace(b'fileChecksPassed', b'localChecksPassed'),
                       valid.replace(b'"checks":33', b'"checks":34'),
                       valid + b' ', document(None), document([])]
            for key, value in [('directory', '../outside'), ('directory', None),
                               ('directory', 100), ('files', None), ('checks', True),
                               ('schema', True), ('windowsVerified', True)]:
                changed = copy.deepcopy(manifest)
                changed[key] = value
                invalid.append(document(changed))
            for value in (None, [], 10, {'bytes': True, 'sha256': '0' * 64}):
                changed = copy.deepcopy(manifest)
                changed['files']['empty.bin'] = value
                invalid.append(document(changed))
            for index, raw in enumerate(invalid):
                with self.subTest(index=index):
                    path.write_bytes(raw)
                    with self.assertRaises(ValidationError):
                        load_manifest(path)

    def test_loading_rejects_linked_special_and_oversized_evidence_without_blocking(self):
        for kind in ('symlink', 'hardlink', 'parent-symlink', 'fifo', 'directory', 'oversized'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                base = Path(directory).resolve()
                manifest = prepare(base)
                evidence = base / 'evidence'
                evidence.mkdir()
                path = evidence / 'manifest.json'
                original = evidence / 'original.json'
                save_manifest(original, manifest)
                if kind == 'symlink':
                    path.symlink_to(original)
                elif kind == 'hardlink':
                    os.link(original, path)
                elif kind == 'parent-symlink':
                    link = base / 'linked'
                    link.symlink_to(evidence, target_is_directory=True)
                    path = link / original.name
                elif kind == 'fifo':
                    os.mkfifo(path)
                elif kind == 'directory':
                    path.mkdir()
                else:
                    path.write_bytes(original.read_bytes() + b' ' * 16384)
                code = ('import sys; from manifest_io import load_manifest; '
                        'from file_cycle import ValidationError; '
                        '\ntry: load_manifest(sys.argv[1])'
                        '\nexcept (ValidationError, OSError): sys.exit(7)')
                result = subprocess.run([sys.executable, '-c', code, str(path)],
                                        cwd=Path(__file__).resolve().parent,
                                        capture_output=True, timeout=3)
                self.assertEqual(result.returncode, 7, result.stderr.decode())

    def test_saving_never_overwrites_existing_evidence_or_follows_a_link(self):
        for kind in ('file', 'symlink', 'parent-symlink'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                base = Path(directory).resolve()
                root, evidence = base / 'volume', base / 'evidence'
                root.mkdir()
                evidence.mkdir()
                manifest = prepare(root)
                original = evidence / 'manifest.json'
                original.write_bytes(b'keep existing evidence')
                path = original
                if kind == 'symlink':
                    path = base / 'link.json'
                    path.symlink_to(original)
                elif kind == 'parent-symlink':
                    link = base / 'linked-directory'
                    link.symlink_to(evidence, target_is_directory=True)
                    path = link / original.name
                with self.assertRaises((ValidationError, OSError)):
                    save_manifest(path, manifest)
                self.assertEqual(original.read_bytes(), b'keep existing evidence')

    def test_saved_manifest_supports_a_later_independent_readback(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            root, evidence = base / 'volume', base / 'evidence'
            root.mkdir()
            evidence.mkdir()
            manifest = prepare(root)
            path = evidence / 'manifest.json'
            save_manifest(path, manifest)
            loaded = load_manifest(path)
            self.assertEqual(loaded, manifest)
            verify(root, loaded)
            cleanup(root, loaded)
            self.assertTrue(path.is_file())


if __name__ == '__main__':
    unittest.main()
