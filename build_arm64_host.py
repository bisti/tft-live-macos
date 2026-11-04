#!/usr/bin/env python3
"""Build the Apple Silicon SDK host used by the portable launcher."""
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parent
HOST = ROOT / "TFT SDK Host arm64.app"


def build_host():
    contents = HOST / "Contents"
    (contents / "MacOS").mkdir(parents=True, exist_ok=True)
    (contents / "Frameworks").mkdir(exist_ok=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "SDKHost",
        "CFBundleIdentifier": "local.tft.live.sdk-host",
        "CFBundleName": "TFT SDK Host arm64",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
        "LSArchitecturePriority": ["arm64"],
        "LSRequiresNativeExecution": True,
        "LSMinimumSystemVersion": "14.0",
    }))
    compile_host(contents / "MacOS/SDKHost")
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(HOST)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(HOST)], check=True)


def compile_host(output):
    # Paths are resolved at run time next to the .app, so the project folder can move.
    subprocess.run([
        "clang++", "-arch", "arm64", "-mmacosx-version-min=14.0", "-std=c++17", "-fobjc-arc",
        "-framework", "Cocoa",
        str(ROOT / "sdk-host.mm"), "-o", str(output),
    ], check=True)


if __name__ == "__main__":
    build_host()
    print(HOST)
