"""Verify release gate wiring with fake build/verification scripts; no installation."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parent.parent


class ReleaseGateChecks(unittest.TestCase):
    def run_gate(self, failure=None):
        source = PROJECT / 'scripts/check-release.sh'
        self.assertTrue(source.exists(), 'formal release requires a dedicated signed-installer gate')
        with tempfile.TemporaryDirectory() as folder:
            project = Path(folder)
            scripts = project / 'scripts'; scripts.mkdir()
            (scripts / 'check-release.sh').write_bytes(source.read_bytes())
            log = project / 'calls'
            for name, stage in [('check.sh', 'development'), ('build-local-installer.sh', 'installer')]:
                file = scripts / name
                file.write_text('#!/bin/zsh\nprint -r -- ' + stage + ' >> "$GATE_CALLS"\n' +
                                ('exit 9\n' if failure == stage else 'exit 0\n'))
                file.chmod(0o755)
            (scripts / 'verify-local-installer.py').write_text(
                'import os,sys\nfrom pathlib import Path\n'
                'p=Path(os.environ["GATE_CALLS"])\n'
                'with p.open("a") as f: f.write("offlineVerify\\n")\n' +
                ('sys.exit(9)\n' if failure == 'offlineVerify' else ''))
            # Both top-level suites must be discovered by the gate.
            for name in ('test_local_installer.py', 'test_install_local_installer.py'):
                (scripts / name).write_text('import unittest,os\nfrom pathlib import Path\n'
                    'class Check(unittest.TestCase):\n'
                    ' def test_wiring(self):\n'
                    '  with Path(os.environ["GATE_CALLS"]).open("a") as f: f.write("' + name + '\\n")\n')
            result = subprocess.run(['/bin/zsh', str(scripts / 'check-release.sh')],
                                    env={**os.environ, 'GATE_CALLS': str(log)}, capture_output=True, text=True)
            return result, log.read_text().splitlines() if log.exists() else []

    def test_formal_gate_builds_verifies_and_runs_both_installer_suites(self):
        result, calls = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls[:3], ['development', 'installer', 'offlineVerify'])
        self.assertEqual(set(calls[3:]), {'test_local_installer.py', 'test_install_local_installer.py'})

    def test_failed_development_build_or_offline_verification_never_passes_release(self):
        for stage in ('development', 'installer', 'offlineVerify'):
            with self.subTest(stage=stage):
                result, calls = self.run_gate(stage)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('PASS: 正式本机发布', result.stdout)
                self.assertIn('BLOCKED', result.stderr)

    def test_development_check_does_not_claim_formal_release(self):
        source = (PROJECT / 'scripts/check.sh').read_text()
        self.assertIn('开发检查', source)
        self.assertIn('check-release.sh', source)
