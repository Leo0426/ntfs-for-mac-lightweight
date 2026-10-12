#!/usr/bin/env python3
"""Compile sourced Setup presentation checks against the current Release libraries."""
from pathlib import Path
import platform
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parent.parent


def main():
    binary_dir = Path(subprocess.check_output(
        ["swift", "build", "-c", "release", "--show-bin-path"], cwd=PROJECT, text=True
    ).strip())
    objects = []
    for module in ["NTFSLiteCore", "NTFSLitePresentation", "NTFSLiteSystem", "NTFSLiteReadOnlyProbing"]:
        product = binary_dir / (module + ".o")
        selected = [product] if product.is_file() else sorted((binary_dir / (module + ".build")).glob("*.o"))
        assert selected, "missing Release objects: " + module
        objects.extend(selected)
    module_dir = binary_dir / "Modules" if (binary_dir / "Modules").is_dir() else binary_dir
    with tempfile.TemporaryDirectory(prefix="ntfslite-setup-status-") as folder:
        executable = Path(folder) / "SetupStatusChecks"
        subprocess.run([
            "swiftc", "-parse-as-library", "-swift-version", "6", "-warnings-as-errors",
            "-target", platform.machine() + "-apple-macosx15.4", "-I", str(module_dir),
            str(PROJECT / "Tests/SetupStatusChecks/main.swift"), *map(str, objects),
            "-o", str(executable)
        ], check=True, cwd=PROJECT)
        subprocess.run([str(executable)], check=True, cwd=PROJECT)


if __name__ == "__main__":
    main()
