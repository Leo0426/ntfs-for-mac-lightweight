"""Offline integration checks for the local protected-app installer package."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET


PROJECT = Path(__file__).resolve().parent.parent
APP = PROJECT / ".build/NTFSLite.app"
PACKAGE = PROJECT / ".build/NTFSLite-local.pkg"
APP_RELATIVE = Path("Library/PrivilegedHelperTools/NTFSLite.app")
PACKAGE_ID = "com.leolu.ntfslite.local-installer"


def run(*args: str | Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(arg) for arg in args],
        cwd=PROJECT,
        check=True,
        capture_output=True,
        text=True,
    )


def entries(root: Path) -> dict[str, Path]:
    result = {}
    for base, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            path = Path(base) / name
            result[path.relative_to(root).as_posix()] = path
    return result


class LocalInstallerChecks(unittest.TestCase):
    built = False

    def ensure_package(self) -> None:
        if self.__class__.built:
            return
        result = subprocess.run(
            ["/bin/zsh", str(PROJECT / "scripts/build-local-installer.sh")],
            cwd=PROJECT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.__class__.built = True

    def test_installs_only_the_exact_signed_app_at_protected_path(self) -> None:
        self.ensure_package()
        with tempfile.TemporaryDirectory(prefix="ntfslite-pkg-test-") as directory:
            expanded = Path(directory) / "expanded"
            run("pkgutil", "--expand-full", PACKAGE, expanded)

            metadata = ET.parse(expanded / "PackageInfo").getroot()
            self.assertEqual(metadata.attrib["identifier"], PACKAGE_ID)
            self.assertEqual(metadata.attrib["install-location"], "/")
            self.assertEqual(metadata.attrib["auth"], "root")
            self.assertEqual(
                {p.name for p in (expanded / "Scripts").iterdir()},
                {"preinstall", "check-protected-install-target.sh"},
            )
            for name in ("preinstall", "check-protected-install-target.sh"):
                self.assertEqual(
                    (expanded / "Scripts" / name).read_bytes(),
                    (PROJECT / "scripts/installer-scripts" / name).read_bytes(),
                )

            payload = expanded / "Payload"
            package_paths = entries(payload)
            source_paths = entries(APP)
            expected_paths = {
                "Library",
                "Library/PrivilegedHelperTools",
                APP_RELATIVE.as_posix(),
                *(f"{APP_RELATIVE}/{name}" for name in source_paths),
            }
            self.assertEqual(set(package_paths), expected_paths)

            installed_app = payload / APP_RELATIVE
            for name, source in source_paths.items():
                packaged = installed_app / name
                self.assertFalse(source.is_symlink(), name)
                self.assertFalse(packaged.is_symlink(), name)
                if source.is_file():
                    self.assertEqual(
                        hashlib.sha256(source.read_bytes()).digest(),
                        hashlib.sha256(packaged.read_bytes()).digest(),
                        name,
                    )
            run("codesign", "--verify", "--strict", "--deep", installed_app)

            bom = run("lsbom", "-p", "fmug", expanded / "Bom").stdout
            for line in bom.splitlines():
                path, mode, uid, gid = line.split("\t")
                self.assertEqual((uid, gid), ("0", "0"), path)
                self.assertEqual(int(mode, 8) & 0o022, 0, path)

    def test_rejects_package_with_unexpected_payload(self) -> None:
        self.ensure_package()
        with tempfile.TemporaryDirectory(prefix="ntfslite-pkg-negative-") as directory:
            root = Path(directory) / "root"
            shutil.copytree(APP, root / APP_RELATIVE)
            extra = root / "Library/PrivilegedHelperTools/extra"
            extra.write_text("unexpected", encoding="utf-8")
            malicious = Path(directory) / "extra.pkg"
            components = Path(directory) / "components.plist"
            with components.open("wb") as handle:
                plistlib.dump([{
                    "RootRelativeBundlePath": APP_RELATIVE.as_posix(),
                    "BundleIsRelocatable": False,
                    "BundleIsVersionChecked": True,
                    "BundleHasStrictIdentifier": True,
                    "BundleOverwriteAction": "upgrade",
                }], handle)
            run(
                "pkgbuild",
                "--root",
                root,
                "--scripts",
                PROJECT / "scripts/installer-scripts",
                "--component-plist",
                components,
                "--install-location",
                "/",
                "--identifier",
                PACKAGE_ID,
                "--version",
                plistlib.loads((APP / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"],
                "--ownership",
                "recommended",
                malicious,
            )
            result = subprocess.run(
                [sys.executable, str(PROJECT / "scripts/verify-local-installer.py"), str(malicious), str(APP)],
                cwd=PROJECT,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("payload", result.stderr.lower())

    def test_rejects_package_that_does_not_run_preinstall(self) -> None:
        self.ensure_package()
        with tempfile.TemporaryDirectory(prefix="ntfslite-pkg-no-guard-") as directory:
            expanded = Path(directory) / "expanded"
            run("pkgutil", "--expand-full", PACKAGE, expanded)
            info = expanded / "PackageInfo"
            tree = ET.parse(info)
            scripts = tree.getroot().find("scripts")
            self.assertIsNotNone(scripts)
            tree.getroot().remove(scripts)
            tree.write(info, encoding="utf-8", xml_declaration=True)
            unguarded = Path(directory) / "unguarded.pkg"
            run("pkgutil", "--flatten", expanded, unguarded)
            result = subprocess.run(
                [sys.executable, str(PROJECT / "scripts/verify-local-installer.py"), str(unguarded), str(APP)],
                cwd=PROJECT,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("preinstall", result.stderr)

    def test_rejects_adhoc_signed_package_even_when_source_matches(self) -> None:
        self.ensure_package()
        with tempfile.TemporaryDirectory(prefix="ntfslite-pkg-adhoc-") as directory:
            expanded = Path(directory) / "expanded"
            run("pkgutil", "--expand-full", PACKAGE, expanded)
            packaged_app = expanded / "Payload" / APP_RELATIVE
            run("codesign", "--force", "--timestamp=none", "--sign", "-", packaged_app)
            source = Path(directory) / "source.app"
            shutil.copytree(packaged_app, source)
            malicious = Path(directory) / "adhoc.pkg"
            run("pkgutil", "--flatten", expanded, malicious)
            result = subprocess.run(
                [sys.executable, str(PROJECT / "scripts/verify-local-installer.py"), str(malicious), str(source)],
                cwd=PROJECT,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("签名", result.stderr)

            fake_bin = Path(directory) / "fake-bin"
            fake_bin.mkdir()
            fake_codesign = fake_bin / "codesign"
            fake_codesign.write_text("#!/bin/zsh\nexit 0\n", encoding="utf-8")
            fake_codesign.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = str(fake_bin) + os.pathsep + environment["PATH"]
            result = subprocess.run(
                [sys.executable, str(PROJECT / "scripts/verify-local-installer.py"), str(malicious), str(source)],
                cwd=PROJECT,
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("签名", result.stderr)

    def test_preflight_rejects_existing_app_and_dangling_link(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ntfslite-preflight-") as directory:
            protected = Path(directory) / "Library/PrivilegedHelperTools"
            protected.mkdir(parents=True)
            target = protected / "NTFSLite.app"
            for kind in ("directory", "dangling-link"):
                if kind == "directory":
                    target.mkdir()
                else:
                    target.symlink_to(protected / "missing")
                result = subprocess.run(
                    ["/bin/zsh", str(PROJECT / "scripts/installer-scripts/check-protected-install-target.sh"), directory],
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0, kind)
                self.assertIn("已存在", result.stderr, kind)
                if kind == "directory":
                    target.rmdir()
                else:
                    target.unlink()

    def test_preflight_rejects_writable_or_linked_parent(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ntfslite-preflight-") as directory:
            library = Path(directory) / "Library"
            protected = library / "PrivilegedHelperTools"
            protected.mkdir(parents=True)
            protected.chmod(0o777)
            result = subprocess.run(
                ["/bin/zsh", str(PROJECT / "scripts/installer-scripts/check-protected-install-target.sh"), directory],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("目录不安全", result.stderr)
            protected.rmdir()
            protected.symlink_to(Path(directory) / "elsewhere")
            result = subprocess.run(
                ["/bin/zsh", str(PROJECT / "scripts/installer-scripts/check-protected-install-target.sh"), directory],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("目录不安全", result.stderr)

    def test_preflight_accepts_absent_target_under_safe_parent(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ntfslite-preflight-") as directory:
            (Path(directory) / "Library/PrivilegedHelperTools").mkdir(parents=True)
            result = subprocess.run(
                ["/bin/zsh", str(PROJECT / "scripts/installer-scripts/check-protected-install-target.sh"), directory],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
