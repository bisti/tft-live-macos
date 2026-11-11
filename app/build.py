"""Package the small ARM64 launcher with a relocatable Python runtime."""
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile
import os
import time


ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "dist/TFT Live.app"
ARCHIVE = ROOT / "dist/TFT-Live-AppleSilicon.zip"
PYTHON_URL = "https://github.com/astral-sh/python-build-standalone/releases/download/20261026/cpython-3.13.18%2B20261026-aarch64-apple-darwin-install_only_stripped.tar.gz"
PYTHON_SHA256 = "8392b6ea51d94391befb2c31ebe75463f045d0b69dfcf5e1bb3234e1f5fa3405"


def build():
    APP.parent.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="tft-portable-build-", dir=APP.parent) as temporary:
        stage = Path(temporary)
        app = stage / APP.name
        contents = app / "Contents"
        resources = contents / "Resources"
        code = resources / "code"
        (contents / "MacOS").mkdir(parents=True)
        (code / "riot_adapter").mkdir(parents=True)
        for name in ["launch_windows_live.py", "launcher_config.py", "riot_runtime.py",
                     "riot-sdk-host-override.json"]:
            shutil.copy2(ROOT / name, code / name)
        for name in ["apple_silicon.py", "sdk_patch.py"]:
            shutil.copy2(ROOT / "riot_adapter" / name, code / "riot_adapter" / name)
        shutil.copy2(ROOT / "TFT SDK Host arm64.app/Contents/MacOS/SDKHost", code / "SDKHost")
        cached = Path(os.environ.get("TFT_PYTHON_ARCHIVE", "/private/tmp/tft-python-arm64.tar.gz"))
        if cached.is_file() and hashlib.sha256(cached.read_bytes()).hexdigest() == PYTHON_SHA256:
            download = cached
        else:
            download = stage / "python.tar.gz"
            with urllib.request.urlopen(PYTHON_URL, timeout=60) as response, download.open("wb") as output:
                shutil.copyfileobj(response, output)
        if hashlib.sha256(download.read_bytes()).hexdigest() != PYTHON_SHA256:
            raise RuntimeError("The portable Python runtime checksum is invalid.")
        with tarfile.open(download) as archive:
            for entry in archive.getmembers():
                path = Path(entry.name)
                if path.is_absolute() or ".." in path.parts:
                    raise RuntimeError("Invalid path in the Python runtime archive.")
                if entry.issym() and (Path(entry.linkname).is_absolute() or not (resources / path.parent / entry.linkname).resolve().is_relative_to(resources)):
                    raise RuntimeError("External link in the Python runtime archive.")
            archive.extractall(resources)
        for name in ["LICENSE", "THIRD_PARTY_NOTICES.md"]:
            shutil.copyfile(ROOT / name, resources / name)
        info = {"CFBundleExecutable": "TFT Live", "CFBundleIdentifier": "local.tft.live.launcher",
                "CFBundleName": "TFT Live", "CFBundleDisplayName": "TFT Live", "CFBundlePackageType": "APPL",
                "CFBundleVersion": "5", "CFBundleShortVersionString": "1.0.4",
                "LSMinimumSystemVersion": "14.0", "LSArchitecturePriority": ["arm64"],
                "LSRequiresNativeExecution": True, "LSUIElement": True, "NSHighResolutionCapable": True}
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        (resources / "README.txt").write_text(
            "TFT Live for Apple Silicon Macs, macOS 14 or later.\n\n"
            "Install the official Riot Client, then open TFT Live.app.\n"
            "Sign in with your Riot account. Your account server is detected automatically.\n"
            "The launcher installs or updates TFT, then enables the Play button.\n"
            "The initial game download may exceed 10 GB.\n\n"
            "Components and personal data are stored in\n"
            "~/Library/Application Support/TFT Live\n"
            "The game is installed in ~/Applications if no compatible installation exists.\n\n"
            "This application is ad-hoc signed and has no Apple notarization.\n"
            "The Python runtime and its licenses are included in Resources/python.\n"
        )
        subprocess.run(["clang++", "-arch", "arm64", "-mmacosx-version-min=14.0", "-std=c++17", "-fobjc-arc",
                        "-framework", "Cocoa", str(ROOT / "app/launcher.mm"), "-o", str(contents / "MacOS/TFT Live")], check=True)
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        if APP.exists():
            shutil.rmtree(APP)
        app.replace(APP)
    partial = ARCHIVE.with_suffix(".zip.partial")
    with zipfile.ZipFile(partial, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as output:
        for path in [APP] + sorted(APP.rglob("*")):
            name = path.relative_to(APP.parent).as_posix()
            if path.is_symlink():
                info = zipfile.ZipInfo(name, time.localtime(path.lstat().st_mtime)[:6])
                info.create_system = 3
                info.external_attr = path.lstat().st_mode << 16
                output.writestr(info, os.readlink(path).encode())
            else:
                output.write(path, name)
    partial.replace(ARCHIVE)
    digest = hashlib.sha256(ARCHIVE.read_bytes()).hexdigest()
    ARCHIVE.with_suffix(".zip.sha256").write_text(digest + "  " + ARCHIVE.name + "\n")
    local = ROOT / "TFT Live.app"
    replacement = ROOT / "TFT Live.app.new"
    if replacement.exists():
        shutil.rmtree(replacement)
    subprocess.run(["cp", "-cR", str(APP), str(replacement)], check=True)
    if local.exists():
        previous = ROOT / "TFT Live.app.previous"
        local.replace(previous)
        replacement.replace(local)
        shutil.rmtree(previous)
    else:
        replacement.replace(local)
    print(APP)
    print(f"Shareable archive. {ARCHIVE.stat().st_size / 1024**2:.1f} MiB")


if __name__ == "__main__":
    build()
