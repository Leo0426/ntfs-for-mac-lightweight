#!/usr/bin/env python3
"""Check real stores and window restoration without starting disk observation."""
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile
import uuid

PROJECT = Path(__file__).resolve().parent.parent


def main():
    binary_dir = Path(subprocess.check_output(
        ["swift", "build", "-c", "release", "--show-bin-path"], cwd=PROJECT, text=True
    ).strip())
    # Only replace the application entry annotation; all production behavior is compiled unchanged.
    source = (PROJECT / "Sources/NTFSLiteReadOnlyApp/NTFSLiteReadOnlyApp.swift").read_text()
    entry = "@main\n@MainActor\nstruct NTFSLiteReadOnlyApp: App"
    assert source.count(entry) == 1, "application entry point changed; update the checks compiler"
    with tempfile.TemporaryDirectory(prefix="ntfslite-app-observation-", dir="/private/tmp") as folder:
        folder = Path(folder)
        app_source = folder / "NTFSLiteReadOnlyApp.swift"
        app_source.write_text(source.replace(entry, entry.removeprefix("@main\n"), 1))
        # Xcode's SwiftPM backend places library objects in Products; the native backend uses
        # target build directories. Executable targets are excluded from both sets.
        modules = ["NTFSLiteCore", "NTFSLiteDiagnostics", "NTFSLitePresentation", "NTFSLiteSystem",
                   "NTFSLiteHelperProtocol", "NTFSLiteStrictJSON", "NTFSLiteHelperExecution",
                   "NTFSLiteWriteSession", "NTFSLiteProtectedInstall", "NTFSLiteMutationPreparation",
                   "NTFSLiteReadOnlyProbing"]
        objects = []
        for module in modules:
            product = binary_dir / (module + ".o")
            selected = [product] if product.is_file() else sorted((binary_dir / (module + ".build")).glob("*.o"))
            assert selected, "missing Release objects: " + module
            objects.extend(selected)
        module_dir = binary_dir / "Modules" if (binary_dir / "Modules").is_dir() else binary_dir
        bundle = folder / "AppStoreObservationChecks.app"
        executable = bundle / "Contents/MacOS/AppStoreObservationChecks"
        executable.parent.mkdir(parents=True)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": executable.name, "CFBundleIdentifier": "com.leolu.ntfslite.app-checks." + uuid.uuid4().hex,
            "CFBundlePackageType": "APPL", "NSPrincipalClass": "NSApplication",
        }))
        subprocess.run([
            "swiftc", "-parse-as-library", "-swift-version", "6", "-warnings-as-errors",
            "-target", platform.machine() + "-apple-macosx15.4", "-I", str(module_dir),
            str(app_source),
            str(PROJECT / "Sources/NTFSLiteReadOnlyApp/ReadOnlyMainWindow.swift"),
            str(PROJECT / "Sources/NTFSLiteReadOnlyApp/WriteControls.swift"),
            str(PROJECT / "Tests/AppStoreObservationChecks/main.swift"),
            *map(str, objects), "-o", str(executable)
        ], check=True, cwd=PROJECT)
        subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True, cwd=PROJECT, capture_output=True)
        stdout = folder / "stdout.log"
        stderr = folder / "stderr.log"
        subprocess.run(["open", "-n", "-W", "--stdout", str(stdout), "--stderr", str(stderr), "--env", "NTFSLITE_APP_CHECKS_ROOT=" + str(folder), str(bundle)], check=True, cwd=PROJECT, timeout=120)
        output = stdout.read_text() if stdout.exists() else ""
        errors = stderr.read_text() if stderr.exists() else ""
        print(output, end="")
        print(errors, end="")
        assert "PASS: helper refresh updates the observed app store without page navigation" in output, "application checks did not complete successfully"


if __name__ == "__main__":
    main()
