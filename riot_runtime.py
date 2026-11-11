"""Stage official Riot updates, validate ARM64 compatibility, and switch atomically."""
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request

from riot_adapter.apple_silicon import thin_tree
from riot_adapter.sdk_patch import patch_windows_sdk


HOST_PATH = Path("TFT SDK Host arm64.app/Contents/MacOS/SDKHost")
RIOT_APP = "Riot Runtime.app"
LEGACY_RIOT_APP = "Riot Windows Auth Test.app"
RUNTIME_PATCHLINE = "keystone.products.teamfighttactics.patchlines.runtime"
REGISTRY = "/rnet-product-registry/v4/"


class IncompatibleRuntime(RuntimeError):
    pass


def read_state(data):
    path = data / "runtime-current.json"
    if not path.exists():
        return {}
    return json.loads(path.read_text())


def write_state(data, state):
    path = data / "runtime-current.json"
    temporary = path.with_suffix(".tmp")
    with temporary.open("w") as output:
        json.dump(state, output)
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(path)


def selected_root(root, data, state):
    selected = Path(state.get("root", root)).resolve()
    if selected != root.resolve() and not selected.is_relative_to((data / "runtimes").resolve()):
        raise RuntimeError("The Riot runtime directory is invalid.")
    return selected


def quit_client(api, lockfile):
    status, sessions = api("GET", "/product-session/v1/sessions", lockfile=lockfile)
    if status != 200:
        return
    if isinstance(sessions, dict) and any(isinstance(session, dict) and session.get("productId") not in (None, "riot_client")
                                          for session in sessions.values()):
        raise RuntimeError("A game is running. The Riot update will be applied after it closes.")
    try:
        pid = int(lockfile.read_text().strip().split(":")[1])
        if pid <= 0:
            raise ValueError("Invalid client PID")
    except (OSError, ValueError, IndexError):
        pid = None
    api("POST", "/process-control/v1/process/quit", lockfile=lockfile)
    deadline = time.monotonic() + 30
    while True:
        running = api("GET", "/product-session/v1/sessions", lockfile=lockfile)[0] == 200
        if pid is not None:
            try:
                reaped, _ = os.waitpid(pid, os.WNOHANG)
                if reaped == pid:
                    pid = None
            except ChildProcessError:
                pass
        if pid is not None:
            try:
                os.kill(pid, 0)
                running = True
            except ProcessLookupError:
                pass
        if not running:
            break
        if time.monotonic() >= deadline:
            raise RuntimeError("Riot Client must close to apply its update.")
        time.sleep(.5)
    time.sleep(1)


def rollback(root, data):
    state = read_state(data)
    if not state.get("pending"):
        return None
    restored = {
        "root": state["previous_root"],
        "manifest": state.get("previous_manifest"),
        "rejected_manifest": state["manifest"],
        "rejected_at": time.time(),
    }
    selected = selected_root(root, data, restored)
    write_state(data, restored)
    return selected / HOST_PATH


def confirm(data):
    state = read_state(data)
    if state.get("pending"):
        state["pending"] = False
        write_state(data, state)
    if not state.get("root"):
        return
    keep = {Path(state[key]).resolve() for key in ("root", "previous_root") if state.get(key)}
    releases = data / "runtimes"
    candidates = list(releases.iterdir()) if releases.is_dir() else []
    if len(keep) == 2 and all((directory / HOST_PATH).is_file() for directory in keep):
        candidates.append(data / "bootstrap")
    for release in candidates:
        owned = (release / "sdk-ready.json").is_file() or (release / "bootstrap-ready.json").is_file()
        if owned and not release.is_symlink() and release.resolve() not in keep:
            shutil.rmtree(release)


def share_interface(directory):
    """Share immutable, signed UI files within a runtime using hard links."""
    def share_file(source, destination):
        try:
            os.link(source, destination)
        except OSError:
            clone(Path(source), Path(destination))

    interface = directory / HOST_PATH.parents[1] / "Frameworks/Riot Client.app"
    interface.parent.mkdir(parents=True, exist_ok=True)
    staged = interface.with_name("Riot Client.app.new")
    backup = directory / "riot-interface.previous"
    if backup.exists() and not interface.exists():
        backup.replace(interface)
    if staged.exists():
        shutil.rmtree(staged)
    shutil.copytree(directory / RIOT_APP / "Contents/Frameworks/Riot Client.app", staged,
                    copy_function=share_file, symlinks=True)
    if backup.exists():
        shutil.rmtree(backup)
    if interface.exists():
        interface.replace(backup)
    staged.replace(interface)
    try:
        # Deep signing would rewrite the UI files shared with the signed runtime.
        host_app = directory / HOST_PATH.parents[2]
        subprocess.run(["codesign", "--force", "--sign", "-", str(host_app)], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(host_app)], check=True)
    except Exception:
        shutil.rmtree(interface)
        if backup.exists():
            backup.replace(interface)
        raise
    if backup.exists():
        shutil.rmtree(backup)


def official_configuration(current, data):
    info = plistlib.loads((current / RIOT_APP / "Contents/Info.plist").read_bytes())
    version = info.get("FileVersion", "")
    cached = data / "user/Config/ClientConfiguration.json"
    if cached.exists():
        entries = json.loads(cached.read_text()).get("public", [])
        entries = [entry for entry in entries if entry.get("params", {}).get("patchline") == "KeystoneFoundationLiveMac"]
        if entries:
            latest = max(entries, key=lambda entry: entry.get("updateTime", 0))["params"]
            version = latest["version"]
    region_file = data / "riot-region.txt"
    region = region_file.read_text().strip() if region_file.exists() else "NA"
    query = urllib.parse.urlencode({
        "app": "Riot Client", "patchline": "KeystoneFoundationLiveMac", "version": version, "region": region,
    }, quote_via=urllib.parse.quote)
    request = urllib.request.Request("https://clientconfig.rpg.riotgames.com/api/v1/config/public?" + query,
                                     headers={"User-Agent": "TFT-Live-Launcher/1.0"})
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.load(response)


def official_manifest(current, data):
    configuration = official_configuration(current, data)
    manifest = configuration["keystone.self_update.manifest_url"]
    if not re.fullmatch(r"https://ks-foundation\.secure\.dyn\.riotcdn\.net/channels/public/releases/[A-Fa-f0-9]{16}\.manifest", manifest):
        raise ValueError("The Riot update manifest is invalid.")
    return manifest


def clone(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(["cp", "-cR", str(source), str(destination)], capture_output=True)
    if result.returncode:
        if destination.is_dir():
            shutil.rmtree(destination)
        elif destination.exists():
            destination.unlink()
        subprocess.run(["cp", "-Rp", str(source), str(destination)], check=True)


def wire_configuration(directory, data):
    targets = {"sdk-host-data": data, "sdk-host-system.yaml": data / "sdk-host-system.yaml",
               "riot-sdk-host-override.json": data / "riot-sdk-host-override.json", "riot-region.txt": data / "riot-region.txt"}
    for name, target in targets.items():
        path = directory / name
        if path.is_symlink() and path.resolve() != target.resolve():
            temporary = path.with_name(path.name + ".new")
            temporary.symlink_to(target)
            temporary.replace(path)
        if not path.exists() and not path.is_symlink():
            path.symlink_to(target)


def remove_install_watcher(data):
    """Remove the legacy launch agent only when it targets our private host."""
    path = Path.home() / "Library/LaunchAgents/com.riot.riotclient.checkinstalls.plist"
    if not path.is_file():
        return False
    agent = plistlib.loads(path.read_bytes())
    arguments = agent.get("ProgramArguments", [])
    if not arguments or not isinstance(arguments[0], str):
        return False
    executable = Path(arguments[0]).resolve()
    if not executable.is_relative_to(data.resolve()) or executable.parts[-4:] != HOST_PATH.parts[-4:]:
        return False
    service = "gui/" + str(os.getuid()) + "/com.riot.riotclient.checkinstalls"
    subprocess.run(["launchctl", "bootout", service], capture_output=True)
    remaining = subprocess.run(["launchctl", "print", service], capture_output=True)
    if remaining.returncode == 0:
        raise RuntimeError("Unable to stop the legacy TFT installation watcher. Reopen TFT Live to retry.")
    path.unlink()
    return True


def refresh_host(assets, current, data, api):
    """Propagate launcher fixes to previously prepared Riot runtimes."""
    source = assets / "SDKHost"
    if not source.is_file():
        source = assets / HOST_PATH
    host = current / HOST_PATH
    marker = current / "host-source.json"
    source_digest = hashlib.sha256(source.read_bytes()).hexdigest()
    recorded = json.loads(marker.read_text()) if marker.is_file() else {}
    if recorded == {"source": source_digest, "installed": hashlib.sha256(host.read_bytes()).hexdigest(), "layout": 3}:
        return
    quit_client(api, data / "user/Config/lockfile")
    legacy = current / LEGACY_RIOT_APP
    if legacy.is_dir() and not (current / RIOT_APP).exists():
        legacy.replace(current / RIOT_APP)
    temporary = host.with_suffix(".new")
    shutil.copy2(source, temporary)
    temporary.replace(host)
    share_interface(current)
    from launcher_config import atomic_json
    atomic_json(marker, {"source": source_digest, "installed": hashlib.sha256(host.read_bytes()).hexdigest(), "layout": 3})


def bootstrap_runtime(assets, data, installed):
    destination = data / "bootstrap"
    if (destination / "bootstrap-ready.json").is_file():
        wire_configuration(destination, data)
        return destination
    if destination.exists():
        shutil.rmtree(destination)
    print("Preparing Apple Silicon components from the installed Riot Client…", flush=True)
    with tempfile.TemporaryDirectory(prefix="bootstrap-stage-", dir=data) as temporary:
        stage = Path(temporary)
        runtime = stage / RIOT_APP
        clone(installed, runtime)
        thin_tree(runtime)
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(runtime)], check=True)
        sdk = stage / "sdk-windows-override-arm64/RiotGamesApi.framework"
        clone(runtime / "Contents/Frameworks/RiotGamesApi.framework", sdk)
        address = patch_windows_sdk(sdk / "RiotGamesApi")
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(sdk)], check=True)
        binary = assets / "SDKHost"
        if not binary.is_file():
            binary = assets / HOST_PATH
        host = stage / HOST_PATH
        clone(binary, host)
        info = {"CFBundleExecutable": "SDKHost", "CFBundleIdentifier": "local.tft.live.sdk-host",
                "CFBundleName": "TFT SDK Host", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
                "LSArchitecturePriority": ["arm64"], "LSRequiresNativeExecution": True, "LSMinimumSystemVersion": "14.0"}
        (host.parents[1] / "Info.plist").write_bytes(plistlib.dumps(info))
        share_interface(stage)
        wire_configuration(stage, data)
        validate_candidate(stage, address)
        (stage / "bootstrap-ready.json").write_text(json.dumps({"address": address}))
        stage.replace(destination)
    return destination


def download_runtime(data, current, stage, manifest, api):
    host = stage / HOST_PATH
    clone(current / HOST_PATH, host)
    clone(current / HOST_PATH.parents[1] / "Info.plist", host.parents[1] / "Info.plist")
    interface = host.parents[1] / "Frameworks/Riot Client.app"
    interface.parent.mkdir()
    interface.symlink_to(current / HOST_PATH.parents[1] / "Frameworks/Riot Client.app")
    for name in [RIOT_APP, "sdk-windows-override-arm64"]:
        (stage / name).symlink_to(current / name, target_is_directory=True)
    shutil.copy2(data / "sdk-host-system.yaml", stage / "sdk-host-system.yaml")
    region_file = data / "riot-region.txt"
    if region_file.exists():
        shutil.copyfile(region_file, stage / "riot-region.txt")
    configuration = json.loads((data / "riot-sdk-host-override.json").read_text())
    product = copy.deepcopy(configuration["public"]["keystone.products.teamfighttactics.patchlines.live"])
    for metadata in product["metadata"].values():
        metadata.pop("product_dependency", None)
    for platform in product["platforms"].values():
        platform["auto_patch"] = False
        platform["install_dir"] = "Riot Download.app"
        for settings in platform.get("configurations", []):
            settings.update(patch_url=manifest, dependencies=[], excluded_paths=[])
    configuration["public"][RUNTIME_PATCHLINE] = product
    (stage / "riot-sdk-host-override.json").write_text(json.dumps(configuration))
    local_data = stage / "sdk-host-data"
    local_data.mkdir(mode=0o700)
    lock = local_data / "user/Config/lockfile"
    destination = stage / "Riot Download.app"
    with (local_data / "host-console.log").open("wb") as console:
        process = subprocess.Popen([str(host), "--headless"], stdin=subprocess.DEVNULL,
                                   stdout=console, stderr=console, start_new_session=True)
    try:
        deadline = time.monotonic() + 60
        while api("GET", "/product-session/v1/sessions", lockfile=lock)[0] != 200:
            if process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError("The isolated Riot patcher failed to start.")
            time.sleep(.5)
        deadline = time.monotonic() + 60
        while True:
            status, error = api("PUT", REGISTRY + "products/teamfighttactics/patchlines/runtime/install-path",
                                {"root_path": str(stage), "full_path": str(destination)}, lockfile=lock)
            if status != 404 or time.monotonic() >= deadline or process.poll() is not None:
                break
            time.sleep(.5)
        if status not in (200, 201, 204):
            raise RuntimeError("The Riot patcher refused the staging directory (HTTP " + str(status) + "). " + str(error))
        status, _ = api("PUT", REGISTRY + "patch-requests/products/teamfighttactics/patchlines/runtime", {}, lockfile=lock)
        if status not in (200, 201, 204):
            raise RuntimeError("The Riot patcher refused the runtime download.")
        deadline = time.monotonic() + 1800
        last_progress = -1
        while time.monotonic() < deadline:
            status, state = api("GET", REGISTRY + "patch-states/products/teamfighttactics/patchlines/runtime", lockfile=lock)
            if status == 200 and isinstance(state, dict):
                if state.get("combined_patch_state") == "up_to_date":
                    return destination
                patch = state.get("patch_status") or {}
                if patch.get("error"):
                    raise RuntimeError("The Riot runtime download failed.")
                progress = int((patch.get("progress") or {}).get("progress", 0)) // 10 * 10
                if progress > last_progress:
                    print("Updating Riot components, " + str(progress) + " %", flush=True)
                    last_progress = progress
            if process.poll() is not None:
                raise RuntimeError("The Riot patcher stopped during the download.")
            time.sleep(1)
        raise RuntimeError("The Riot runtime download timed out.")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def prepare_candidate(root, current, data, manifest, api):
    releases = data / "runtimes"
    releases.mkdir(exist_ok=True)
    candidate = releases / Path(urllib.parse.urlsplit(manifest).path).stem
    marker = candidate / "sdk-ready.json"
    if marker.is_file():
        ready = json.loads(marker.read_text())
        if ready.get("manifest") == manifest:
            refresh_host(current, candidate, data, api)
            validate_candidate(candidate, ready["address"])
            return candidate
    if candidate.exists():
        shutil.rmtree(candidate)
    with tempfile.TemporaryDirectory(prefix="runtime-stage-", dir=data) as temporary:
        stage = Path(temporary)
        downloaded = download_runtime(data, current, stage, manifest, api)
        candidate.mkdir(mode=0o700)
        try:
            runtime = candidate / RIOT_APP
            downloaded.replace(runtime)
            thin_tree(runtime)
            subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(runtime)], check=True)
            sdk = candidate / "sdk-windows-override-arm64/RiotGamesApi.framework"
            clone(runtime / "Contents/Frameworks/RiotGamesApi.framework", sdk)
            address = patch_windows_sdk(sdk / "RiotGamesApi")
            subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(sdk)], check=True)
            host = candidate / HOST_PATH
            clone(current / HOST_PATH, host)
            clone(current / HOST_PATH.parents[1] / "Info.plist", host.parents[1] / "Info.plist")
            share_interface(candidate)
            wire_configuration(candidate, data)
            validate_candidate(candidate, address)
            marker.write_text(json.dumps({"manifest": manifest, "address": address}))
        except Exception as error:
            shutil.rmtree(candidate)
            raise IncompatibleRuntime(str(error)) from error
    return candidate


def validate_candidate(candidate, address):
    for path in [candidate / RIOT_APP, candidate / "sdk-windows-override-arm64/RiotGamesApi.framework",
                 candidate / "TFT SDK Host arm64.app"]:
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(path)], check=True)
    result = subprocess.run([str(candidate / HOST_PATH), "--check-sdk", format(address, "x")],
                            capture_output=True, text=True, timeout=30, check=True)
    if result.stdout.strip() != "windows":
        raise RuntimeError("Windows validation of the new SDK failed.")


def ensure_runtime(root, data, api):
    state = read_state(data)
    if state.get("pending"):
        rollback(root, data)
        state = read_state(data)
    current = selected_root(root, data, state)
    try:
        manifest = official_manifest(current, data)
        if manifest == state.get("manifest"):
            return current / HOST_PATH
        if manifest == state.get("rejected_manifest") and time.time() - state.get("rejected_at", 0) < 86400:
            print("Keeping the previous compatible Riot components.", flush=True)
            return current / HOST_PATH
        candidate = prepare_candidate(root, current, data, manifest, api)
        quit_client(api, data / "user/Config/lockfile")
        write_state(data, {"root": str(candidate), "manifest": manifest, "pending": True,
                           "previous_root": str(current), "previous_manifest": state.get("manifest")})
        print("New Riot components prepared and validated for ARM64.", flush=True)
        return candidate / HOST_PATH
    except (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError, struct.error,
            RuntimeError, subprocess.SubprocessError) as error:
        if isinstance(error, IncompatibleRuntime):
            state.update(rejected_manifest=manifest, rejected_at=time.time())
            write_state(data, state)
        print("Riot update deferred. Keeping the compatible version. " + str(error), flush=True)
        return current / HOST_PATH
