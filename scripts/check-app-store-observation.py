#!/usr/bin/env python3
"""Run the real App/store/controllers with a checks entry point, without launching the UI."""
from pathlib import Path
import platform
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parent.parent


def main():
    binary_dir = Path(subprocess.check_output(
        ["swift", "build", "-c", "release", "--show-bin-path"], cwd=PROJECT, text=True
    ).strip())
    # Only replace the application entry annotation; all production behavior is compiled unchanged.
    source = (PROJECT / "Sources/NTFSLiteReadOnlyApp/NTFSLiteReadOnlyApp.swift").read_text()
    entry = "@main\n@MainActor\nstruct NTFSLiteReadOnlyApp: App"
    assert source.count(entry) == 1, "application entry point changed; update the checks compiler"
    with tempfile.TemporaryDirectory(prefix="ntfslite-app-observation-") as folder:
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
        executable = folder / "AppStoreObservationChecks"
        subprocess.run([
            "swiftc", "-parse-as-library", "-swift-version", "6", "-warnings-as-errors",
            "-target", platform.machine() + "-apple-macosx15.4", "-I", str(module_dir),
            str(app_source),
            str(PROJECT / "Sources/NTFSLiteReadOnlyApp/ReadOnlyMainWindow.swift"),
            str(PROJECT / "Sources/NTFSLiteReadOnlyApp/WriteControls.swift"),
            str(PROJECT / "Tests/AppStoreObservationChecks/main.swift"),
            *map(str, objects), "-o", str(executable)
        ], check=True, cwd=PROJECT)
        subprocess.run([str(executable)], check=True, cwd=PROJECT)


if __name__ == "__main__":
    main()
