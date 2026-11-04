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
        (code / "standalone").mkdir(parents=True)
        for name in ["launch_windows_live.py", "launcher_config.py", "riot_runtime.py",
                     "riot-sdk-host-override.json"]:
            shutil.copy2(ROOT / name, code / name)
        for name in ["apple_silicon.py", "sdk_patch.py"]:
            shutil.copy2(ROOT / "standalone" / name, code / "standalone" / name)
        shutil.copy2(ROOT / "TFT SDK Host arm64.app/Contents/MacOS/SDKHost", code / "SDKHost")
        cached = Path(os.environ.get("TFT_PYTHON_ARCHIVE", "/private/tmp/tft-python-arm64.tar.gz"))
        if cached.is_file() and hashlib.sha256(cached.read_bytes()).hexdigest() == PYTHON_SHA256:
            download = cached
        else:
            download = stage / "python.tar.gz"
            with urllib.request.urlopen(PYTHON_URL, timeout=60) as response, download.open("wb") as output:
                shutil.copyfileobj(response, output)
        if hashlib.sha256(download.read_bytes()).hexdigest() != PYTHON_SHA256:
            raise RuntimeError("L'empreinte du moteur Python portable est invalide.")
        with tarfile.open(download) as archive:
            for entry in archive.getmembers():
                path = Path(entry.name)
                if path.is_absolute() or ".." in path.parts:
                    raise RuntimeError("Chemin invalide dans le moteur Python.")
                if entry.issym() and (Path(entry.linkname).is_absolute() or not (resources / path.parent / entry.linkname).resolve().is_relative_to(resources)):
                    raise RuntimeError("Lien externe dans le moteur Python.")
            archive.extractall(resources)
        for name in ["LICENSE", "THIRD_PARTY_NOTICES.md"]:
            shutil.copyfile(ROOT / name, resources / name)
        info = {"CFBundleExecutable": "TFT Live", "CFBundleIdentifier": "local.tft.live.launcher",
                "CFBundleName": "TFT Live", "CFBundleDisplayName": "TFT Live", "CFBundlePackageType": "APPL",
                "CFBundleVersion": "30", "CFBundleShortVersionString": "3.0",
                "LSMinimumSystemVersion": "14.0", "LSArchitecturePriority": ["arm64"],
                "LSRequiresNativeExecution": True, "LSUIElement": True, "NSHighResolutionCapable": True}
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        (resources / "LIRE-MOI.txt").write_text(
            "TFT Live pour Mac Apple Silicon, macOS 14 ou plus.\n\n"
            "Installer le Riot Client officiel, puis ouvrir TFT Live.app.\n"
            "Se connecter avec son compte Riot. Le serveur du compte est détecté.\n"
            "Le lanceur installe ou met à jour TFT, puis le bouton Jouer devient utilisable.\n"
            "Les téléchargements initiaux du jeu peuvent dépasser 10 Go.\n\n"
            "Les composants et données personnels sont conservés dans\n"
            "~/Library/Application Support/TFT Live\n"
            "Le jeu est installé dans ~/Applications lorsque aucune installation compatible n'existe.\n\n"
            "Cette application est signée localement et ne dispose pas de notarisation Apple.\n"
            "Le moteur Python et ses licences sont inclus dans Resources/python.\n"
        )
        subprocess.run(["clang++", "-arch", "arm64", "-mmacosx-version-min=14.0", "-std=c++17", "-fobjc-arc",
                        "-framework", "Cocoa", str(ROOT / "portable/launcher.mm"), "-o", str(contents / "MacOS/TFT Live")], check=True)
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
    print(f"Archive partageable : {ARCHIVE.stat().st_size / 1024**2:.1f} Mio")


if __name__ == "__main__":
    build()
