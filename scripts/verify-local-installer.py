#!/usr/bin/env python3
"""Verify a local first-install package without running Installer or disk mutations."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


PROJECT = Path(__file__).resolve().parent.parent
APP_RELATIVE = Path("Library/PrivilegedHelperTools/NTFSLite.app")
PACKAGE_ID = "com.leolu.ntfslite.local-installer"
APP_ID = "com.leolu.ntfslite.readonly"
TEAM_ID = "NP3U2GYHWL"
SIGNED_COMPONENTS = {
    ".": APP_ID,
    "Contents/MacOS/NTFSLiteHelper": "com.leolu.ntfslite.helper.v2",
    "Contents/Helpers/ntfs-3g": "com.leolu.ntfslite.ntfs-3g",
    "Contents/Helpers/ntfs-3g.probe": "com.leolu.ntfslite.ntfs-3g.probe",
}
SYSTEM_COMMANDS = {
    "codesign": "/usr/bin/codesign",
    "pkgutil": "/usr/sbin/pkgutil",
    "lsbom": "/usr/bin/lsbom",
}
EXPECTED_APP_FILES = {
    "Contents/Helpers/ntfs-3g",
    "Contents/Helpers/ntfs-3g.probe",
    "Contents/Info.plist",
    "Contents/Library/LaunchDaemons/com.leolu.ntfslite.helper.v2.plist",
    "Contents/MacOS/NTFSLiteHelper",
    "Contents/MacOS/NTFSLiteReadOnlyApp",
    "Contents/Resources/NTFSLite.icns",
    "Contents/Resources/FSKitRuntimeProbe.ntfs.zlib",
    "Contents/_CodeSignature/CodeResources",
}
EXPECTED_APP_DIRS = {
    "Contents",
    "Contents/Helpers",
    "Contents/Library",
    "Contents/Library/LaunchDaemons",
    "Contents/MacOS",
    "Contents/Resources",
    "Contents/_CodeSignature",
}
EXPECTED_SCRIPTS = {"preinstall", "check-protected-install-target.sh"}


def verify_package_info(metadata: ET.Element, app_info: dict[str, object]) -> None:
    """Check the Installer actions, not only the files present in Scripts/Payload."""
    require(metadata.tag == "pkg-info", "pkg 元数据格式无效。")
    version = app_info.get("CFBundleShortVersionString")
    build = app_info.get("CFBundleVersion")
    require(isinstance(version, str) and bool(version), "源 App 版本无效。")
    require(isinstance(build, str) and bool(build), "源 App 构建号无效。")
    attributes = dict(metadata.attrib)
    generator = attributes.pop("generator-version", None)
    require(isinstance(generator, str) and bool(generator), "pkg 生成器版本缺失。")
    require(attributes == {
        "overwrite-permissions": "true",
        "relocatable": "false",
        "identifier": PACKAGE_ID,
        "postinstall-action": "none",
        "version": version,
        "format-version": "2",
        "install-location": "/",
        "auth": "root",
    }, "pkg 安装属性不符合固定清单。")

    expected_children = [
        "payload", "bundle", "bundle-version", "upgrade-bundle", "update-bundle",
        "atomic-update-bundle", "strict-identifier", "relocate", "scripts",
    ]
    require([child.tag for child in metadata] == expected_children, "pkg 安装动作清单不符合固定清单（包括 preinstall）。")
    payload, bundle, bundle_version, upgrade_bundle, update_bundle, atomic_update, strict_identifier, relocate, scripts = metadata
    require(set(payload.attrib) == {"numberOfFiles", "installKBytes"} and not list(payload), "pkg payload 元数据无效。")
    for key in ("numberOfFiles", "installKBytes"):
        require(payload.attrib[key].isdigit(), f"pkg payload {key} 无效。")
    require(int(payload.attrib["numberOfFiles"]) > 0, "pkg payload 文件数无效。")
    require(bundle.attrib == {
        "path": f"./{APP_RELATIVE.as_posix()}",
        "id": APP_ID,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
    } and not list(bundle), "pkg App bundle 元数据不符。")
    for node in (bundle_version, upgrade_bundle, strict_identifier):
        require(not node.attrib and len(node) == 1, f"pkg {node.tag} 动作不符。")
        child = node[0]
        require(child.tag == "bundle" and child.attrib == {"id": APP_ID} and not list(child), f"pkg {node.tag} App 标识不符。")
    for node in (update_bundle, atomic_update, relocate):
        require(not node.attrib and not list(node), f"pkg {node.tag} 动作不符。")
    require(not scripts.attrib and len(scripts) == 1, "pkg 安装脚本动作不符。")
    preinstall = scripts[0]
    require(preinstall.tag == "preinstall" and preinstall.attrib == {
        "file": "./preinstall", "timeout": "600",
    } and not list(preinstall), "pkg preinstall 调用不符。")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def run(*arguments: str | Path) -> str:
    name = str(arguments[0])
    require(name in SYSTEM_COMMANDS, f"不允许的验证命令：{name}")
    result = subprocess.run(
        [SYSTEM_COMMANDS[name], *(str(argument) for argument in arguments[1:])],
        check=False,
        capture_output=True,
        text=True,
    )
    require(result.returncode == 0, f"命令失败：{arguments[0]}: {result.stderr.strip()}")
    return result.stdout


def verify_signed_components(app: Path) -> None:
    run("codesign", "--verify", "--strict", "--deep", app)
    for relative, identifier in SIGNED_COMPONENTS.items():
        requirement = (
            f'anchor apple generic and identifier "{identifier}" '
            f'and certificate leaf[subject.OU] = "{TEAM_ID}"'
        )
        component = app if relative == "." else app / relative
        result = subprocess.run(
            [SYSTEM_COMMANDS["codesign"], "--verify", "--strict", f"-R={requirement}", str(component)],
            capture_output=True,
            text=True,
            check=False,
        )
        require(result.returncode == 0, f"签名身份不符：{relative}")


def tree_entries(root: Path) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for parent, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            path = Path(parent) / name
            require(not path.is_symlink(), f"payload 包含符号链接：{path}")
            require(path.is_file() or path.is_dir(), f"payload 包含特殊节点：{path}")
            require(stat.S_IMODE(path.stat().st_mode) & 0o022 == 0, f"payload 权限可被普通用户写入：{path}")
            relative = path.relative_to(root).as_posix()
            require(relative not in result, f"payload 重复路径：{relative}")
            result[relative] = path
    return result


def expected_payload_paths() -> set[str]:
    app = APP_RELATIVE.as_posix()
    return {
        "Library",
        "Library/PrivilegedHelperTools",
        app,
        *(f"{app}/{name}" for name in EXPECTED_APP_DIRS | EXPECTED_APP_FILES),
    }


def verify_bom(bom: Path, payload_paths: set[str]) -> None:
    seen_real: set[str] = set()
    seen_metadata: set[str] = set()
    for line in run("lsbom", "-p", "fmug", bom).splitlines():
        parts = line.split("\t")
        require(len(parts) == 4, "BOM 格式未知。")
        raw_path, raw_mode, uid, gid = parts
        require(raw_path == "." or raw_path.startswith("./"), f"BOM 路径不是相对路径：{raw_path}")
        path = raw_path[2:] if raw_path != "." else "."
        require(uid == "0" and gid == "0", f"BOM 不是 root:wheel：{path}")
        try:
            mode = int(raw_mode, 8)
        except ValueError as error:
            raise ValueError(f"BOM 权限未知：{path}") from error
        require(mode & 0o022 == 0, f"BOM 普通用户可写：{path}")
        require(stat.S_IFMT(mode) in (stat.S_IFDIR, stat.S_IFREG), f"BOM 特殊节点：{path}")

        parts = Path(path).parts
        require(path == "." or (parts and ".." not in parts), f"BOM 路径越界：{path}")
        basename = parts[-1] if parts else ""
        if basename.startswith("._"):
            actual = str(Path(*parts[:-1]) / basename[2:])
            require(actual in payload_paths, f"BOM metadata 没有对应 payload：{path}")
            require(path not in seen_metadata, f"BOM 重复 metadata：{path}")
            seen_metadata.add(path)
        else:
            require(path == "." or path in payload_paths, f"BOM 存在意外 payload：{path}")
            require(path not in seen_real, f"BOM 重复路径：{path}")
            seen_real.add(path)
    require(seen_real == payload_paths | {"."}, "BOM 与 payload 路径清单不一致。")


def verify_package(package: Path, source_app: Path) -> None:
    require(package.is_file() and not package.is_symlink(), "pkg 路径不是普通文件。")
    require(source_app.is_dir() and not source_app.is_symlink(), "源 App 路径不安全。")

    source_entries = tree_entries(source_app)
    require(
        set(source_entries) == EXPECTED_APP_FILES | EXPECTED_APP_DIRS,
        "源 App 文件清单不符合允许集合。",
    )
    with (source_app / "Contents/Info.plist").open("rb") as handle:
        app_info = plistlib.load(handle)
    require(app_info.get("CFBundleIdentifier") == APP_ID, "源 App 标识不符。")
    version = app_info.get("CFBundleShortVersionString")
    require(isinstance(version, str) and bool(version), "源 App 版本无效。")
    verify_signed_components(source_app)

    with tempfile.TemporaryDirectory(prefix="ntfslite-verify-pkg-") as directory:
        expanded = Path(directory) / "expanded"
        run("pkgutil", "--expand-full", package, expanded)
        require(
            {path.name for path in expanded.iterdir()} == {"Bom", "PackageInfo", "Payload", "Scripts"},
            "pkg 顶层内容不符合允许集合。",
        )
        metadata = ET.parse(expanded / "PackageInfo").getroot()
        verify_package_info(metadata, app_info)

        script_entries = tree_entries(expanded / "Scripts")
        require(set(script_entries) == EXPECTED_SCRIPTS, "pkg 安装脚本清单不符。")
        for name in EXPECTED_SCRIPTS:
            packaged = script_entries[name]
            source = PROJECT / "scripts/installer-scripts" / name
            require(packaged.read_bytes() == source.read_bytes(), f"pkg 安装脚本内容不符：{name}")
            require(packaged.stat().st_mode & 0o111 != 0, f"pkg 安装脚本不可执行：{name}")

        payload = expanded / "Payload"
        payload_entries = tree_entries(payload)
        expected_paths = expected_payload_paths()
        require(set(payload_entries) == expected_paths, "pkg payload 路径清单不符。")
        verify_bom(expanded / "Bom", expected_paths)

        packaged_app = payload / APP_RELATIVE
        for name, source in source_entries.items():
            if source.is_file():
                source_digest = hashlib.sha256(source.read_bytes()).digest()
                package_digest = hashlib.sha256((packaged_app / name).read_bytes()).digest()
                require(source_digest == package_digest, f"pkg payload 字节与签名 App 不符：{name}")
        verify_signed_components(packaged_app)


def main() -> int:
    if len(sys.argv) != 3:
        print("用法：verify-local-installer.py <pkg> <signed-app>", file=sys.stderr)
        return 2
    try:
        verify_package(Path(sys.argv[1]), Path(sys.argv[2]))
    except (OSError, ValueError, ET.ParseError, plistlib.InvalidFileException) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("PASS: 本机安装包 payload、脚本、root:wheel BOM 与签名 App 已离线核对。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
