import json
from pathlib import Path
import subprocess
import tempfile
import unittest


class FSKitRegistrationChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        folder = Path(cls.temporary.name)
        cls.binary = folder / 'registration-check'
        harness = folder / 'main.swift'
        harness.write_text('''
import Foundation
let input = FileHandle.standardInput.readDataToEndOfFile()
let modules = try JSONDecoder().decode([FSKitModuleObservation]?.self, from: input)
let report = assessFSKitRegistration(modules)
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(report))
''')
        source = Path(__file__).with_name('FSKitRegistration.swift')
        result = subprocess.run(['/usr/bin/swiftc', '-O', '-warnings-as-errors',
                                 str(source), str(harness), '-o', str(cls.binary)],
                                capture_output=True, timeout=60)
        if result.returncode:
            raise AssertionError(result.stderr.decode())

    def assess(self, modules):
        result = subprocess.run([str(self.binary)], input=json.dumps(modules).encode(),
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        report = json.loads(result.stdout)
        self.assertEqual(report['observationScope'], 'currentProcess')
        return report

    def modules(self):
        base = 'file:///Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app/Contents/Extensions/'
        return [{'identifier': name, 'url': base + name + '.appex', 'enabled': True}
                for name in ('io.macfuse.app.fsmodule.macfuse', 'io.macfuse.app.fsmodule.macfuse-local')]

    def test_exact_enabled_modules_only_establish_current_process_observation(self):
        report = self.assess(self.modules())
        self.assertEqual(report['status'], 'observedAndEnabled')
        self.assertEqual(report['modules'], {'standard': 'enabled', 'local': 'enabled'})
        self.assertFalse(report['mountVerified'])
        self.assertFalse(report['writeAuthorized'])

    def test_disabled_wrong_path_and_duplicate_modules_fail_closed(self):
        for kind, expected in [('disabled', 'disabled'), ('wrong-path', 'unexpectedLocation'),
                               ('duplicate', 'ambiguous'), ('missing', 'notObserved')]:
            with self.subTest(kind=kind):
                modules = self.modules()
                if kind == 'disabled':
                    modules[0]['enabled'] = False
                elif kind == 'wrong-path':
                    modules[0]['url'] = 'file:///private/tmp/copied-extension.appex'
                elif kind == 'duplicate':
                    modules.append(modules[0].copy())
                else:
                    modules.pop(0)
                report = self.assess(modules)
                self.assertEqual(report['status'], 'blocked')
                self.assertEqual(report['modules']['standard'], expected)
                self.assertEqual(report['modules']['local'], 'enabled')
                self.assertFalse(report['mountVerified'])
                self.assertFalse(report['writeAuthorized'])

    def test_other_extensions_do_not_fill_missing_macfuse_slots_or_leak_identifiers(self):
        report = self.assess([{'identifier': 'private.example.extension',
                              'url': 'file:///private/example.appex', 'enabled': True}])
        self.assertEqual(report['status'], 'blocked')
        self.assertEqual(report['modules'], {'standard': 'notObserved', 'local': 'notObserved'})
        self.assertNotIn('private', json.dumps(report))

    def test_empty_query_is_not_evidence_of_system_wide_absence(self):
        report = self.assess([])
        self.assertEqual(report['status'], 'blocked')
        self.assertEqual(report['modules'], {'standard': 'notObserved', 'local': 'notObserved'})
        self.assertFalse(report['mountVerified'])
        self.assertFalse(report['writeAuthorized'])

    def test_failed_query_is_not_a_successful_empty_enumeration(self):
        report = self.assess(None)
        self.assertEqual(report['status'], 'queryFailed')
        self.assertEqual(report['modules'], {'standard': 'unavailable', 'local': 'unavailable'})
        self.assertFalse(report['mountVerified'])
        self.assertFalse(report['writeAuthorized'])

    def test_native_entrypoint_builds_and_rejects_unsupported_arguments(self):
        folder = Path(self.temporary.name)
        native = folder / 'inspect-fskit'
        sources = Path(__file__).parent
        result = subprocess.run(['/usr/bin/swiftc', '-O', '-warnings-as-errors', '-parse-as-library',
                                 str(sources / 'FSKitRegistration.swift'), str(sources / 'InspectFSKit.swift'),
                                 '-o', str(native)], capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        help_result = subprocess.run([str(native), '--help'], capture_output=True, timeout=5)
        self.assertEqual(help_result.returncode, 0)
        rejected = subprocess.run([str(native), '--mount'], capture_output=True, timeout=5)
        self.assertEqual(rejected.returncode, 64)
        self.assertEqual(rejected.stdout, b'')


if __name__ == '__main__':
    unittest.main()
