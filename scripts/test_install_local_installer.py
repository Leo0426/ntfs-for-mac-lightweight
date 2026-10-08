"""Exercise the local installer handoff without sudo or system installation."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parent.parent
INSTALL_SCRIPT = PROJECT / "scripts/install-local-installer.sh"


class LocalInstallHandoffTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="ntfslite-install-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / "project with spaces"
        scripts = self.project / "scripts"
        scripts.mkdir(parents=True)
        build = self.project / ".build"
        build.mkdir()
        self.package = build / "NTFSLite-local.pkg"
        self.package.write_bytes(b"validated package bytes")
        self.app = build / "NTFSLite.app"
        self.app.mkdir()
        self.stage_parent = self.root / "root-staging"
        self.stage_parent.mkdir()
        self.stage_parent.chmod(0o1777)
        self.sudo = self.root / "sudo"
        self.sudo.write_text(
            "#!/bin/zsh\n"
            "if [[ -n ${NTFSLITE_TEST_REJECT_CLEANUP:-} && $# == 5 ]]; then exit 74; fi\n"
            "if [[ -n ${NTFSLITE_TEST_TAMPER:-} && $# == 6 ]]; then\n"
            "  /bin/chmod 0644 \"$5/package.pkg\"\n"
            "  print -n -r -- 'changed after verification' > \"$5/package.pkg\"\n"
            "  /bin/chmod 0444 \"$5/package.pkg\"\n"
            "fi\n"
            "exec \"$@\"\n",
            encoding="utf-8",
        )
        self.sudo.chmod(0o755)
        self.installer = self.root / "fake-installer"
        self.installer.write_text(
            "#!/bin/zsh\n"
            "[[ $# == 4 && $1 == '-pkg' && $3 == '-target' && $4 == '/' ]] || exit 64\n"
            "/bin/cp \"$2\" \"$NTFSLITE_TEST_INSTALLED_COPY\"\n",
            encoding="utf-8",
        )
        self.installer.chmod(0o755)
        (scripts / "verify-local-installer.py").write_text(
            "from pathlib import Path\n"
            "import os, sys\n"
            "package, app = map(Path, sys.argv[1:])\n"
            "Path(os.environ['NTFSLITE_TEST_VERIFIED_PATH']).write_text(str(package))\n"
            "if not package.is_file() or app.name != 'NTFSLite.app': sys.exit(71)\n"
            "if package.read_bytes() != b'validated package bytes': sys.exit(72)\n"
            "if os.environ.get('NTFSLITE_TEST_SWAP_SOURCE'):\n"
            "    Path(os.environ['NTFSLITE_TEST_SOURCE_PACKAGE']).write_bytes(b'swapped source')\n"
            "if os.environ.get('NTFSLITE_TEST_REJECT'): sys.exit(73)\n",
            encoding="utf-8",
        )
        self.installed_copy = self.root / "installer-consumed.pkg"
        self.verified_path = self.root / "verified-path.txt"
        self.script = scripts / "install-local-installer.sh"

    def write_testable_script(self) -> None:
        # Rewrite only privileged OS endpoints; execute the installer's real handoff logic.
        source = INSTALL_SCRIPT.read_text(encoding="utf-8")
        replacements = {
            "/private/var/tmp": str(self.stage_parent),
            "/usr/bin/sudo": str(self.sudo),
            "/usr/sbin/installer": str(self.installer),
        }
        for old, new in replacements.items():
            self.assertIn(old, source)
            source = source.replace(old, new)
        self.script.write_text(source, encoding="utf-8")
        self.script.chmod(0o755)

    def invoke(self, **extra_environment: str) -> subprocess.CompletedProcess[str]:
        self.write_testable_script()
        environment = os.environ.copy()
        environment.update({
            "NTFSLITE_TEST_INSTALLED_COPY": str(self.installed_copy),
            "NTFSLITE_TEST_VERIFIED_PATH": str(self.verified_path),
            "NTFSLITE_TEST_SOURCE_PACKAGE": str(self.package),
            **extra_environment,
        })
        return subprocess.run(
            [str(self.script)],
            cwd=self.project,
            env=environment,
            capture_output=True,
            text=True,
        )

    def test_installer_consumes_verified_root_staged_copy_after_source_swap(self) -> None:
        result = self.invoke(NTFSLITE_TEST_SWAP_SOURCE="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        verified = Path(self.verified_path.read_text(encoding="utf-8"))
        self.assertEqual(verified.name, "package.pkg")
        self.assertEqual(verified.parent.parent, self.stage_parent)
        self.assertNotEqual(verified, self.package)
        self.assertEqual(self.package.read_bytes(), b"swapped source")
        self.assertEqual(self.installed_copy.read_bytes(), b"validated package bytes")
        self.assertEqual(list(self.stage_parent.iterdir()), [])

    def test_verifier_rejection_stops_installer_and_cleans_staging(self) -> None:
        result = self.invoke(NTFSLITE_TEST_REJECT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.verified_path.exists())
        self.assertFalse(self.installed_copy.exists())
        self.assertEqual(list(self.stage_parent.iterdir()), [])

    def test_digest_change_after_verification_stops_installer_and_cleans_staging(self) -> None:
        result = self.invoke(NTFSLITE_TEST_TAMPER="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.verified_path.exists())
        self.assertFalse(self.installed_copy.exists())
        self.assertEqual(list(self.stage_parent.iterdir()), [])

    def test_symlink_package_is_rejected_before_sudo(self) -> None:
        self.package.unlink()
        target = self.root / "other.pkg"
        target.write_bytes(b"validated package bytes")
        self.package.symlink_to(target)
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.verified_path.exists())
        self.assertFalse(self.installed_copy.exists())
        self.assertEqual(list(self.stage_parent.iterdir()), [])

    def test_untrusted_python_on_path_cannot_skip_package_verification(self) -> None:
        self.package.write_bytes(b"unverified package bytes")
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        fake_python = fake_bin / "python3"
        fake_python.write_text("#!/bin/zsh\nexit 0\n", encoding="utf-8")
        fake_python.chmod(0o755)
        result = self.invoke(PATH=str(fake_bin) + os.pathsep + os.environ["PATH"])
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.installed_copy.exists())

    def test_cleanup_failure_is_reported_after_installer_returns(self) -> None:
        result = self.invoke(NTFSLITE_TEST_REJECT_CLEANUP="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.installed_copy.exists())
        self.assertIn("清理失败", result.stderr)


if __name__ == "__main__":
    unittest.main()
