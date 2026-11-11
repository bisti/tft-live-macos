#!/usr/bin/env python3
"""Open the Windows-authenticated Riot Client and prepare TFT for manual launch."""
import base64
from concurrent.futures import ThreadPoolExecutor
import fcntl
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
import riot_runtime
import launcher_config


DATA = launcher_config.data_directory()
LOCK = DATA / "user/Config/lockfile"
GAME = launcher_config.game_path(DATA)
NORMAL_LOCK = Path.home() / "Library/Application Support/Riot Games/Riot Client/Config/lockfile"
SIEVE = ("https://sieve.services.riotcdn.net/api/v1/products/teamfighttactics/version-sets/{version_set}"
         "?q%5Bartifact_type_id%5D=client&q%5Bplatform%5D={platform}&q%5Bpublished%5D=true")
SESSIONS = "/product-session/v1/sessions"
PATCH_STATE = "/rnet-product-registry/v4/patch-states/products/teamfighttactics/patchlines/live"
PATCH_REQUEST = "/rnet-product-registry/v4/patch-requests/products/teamfighttactics/patchlines/live"
OPENER = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
)


def api(method, route, body=None, lockfile=None):
    lockfile = lockfile or LOCK
    try:
        fields = lockfile.read_text().strip().split(":")
        port = int(fields[2])
        if not 1 <= port <= 65535 or fields[4] != "https":
            return 0, None
        credentials = base64.b64encode(("riot:" + fields[3]).encode()).decode()
        headers = {"Authorization": "Basic " + credentials}
        payload = None
        if body is not None:
            payload = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            "https://127.0.0.1:" + str(port) + route,
            data=payload, headers=headers, method=method,
        )
        try:
            response = OPENER.open(request, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read()
            return response.code, json.loads(raw) if raw else None
    except (OSError, ValueError, IndexError, urllib.error.URLError):
        return 0, None


def published_release(platform, version_set):
    if not re.fullmatch(r"live-[A-Z0-9]+", version_set):
        raise ValueError("The requested TFT channel is invalid.")
    request = urllib.request.Request(SIEVE.format(platform=platform, version_set=version_set), headers={"User-Agent": "TFT-Live-Launcher/1.0"})
    with urllib.request.urlopen(request, timeout=15) as response:
        releases = json.load(response).get("releases", [])
    if len(releases) != 1:
        raise ValueError("Channel " + version_set + " does not identify a unique release.")
    release = releases[0]
    labels = release["release"]["labels"]
    if labels["riot:platform"]["values"] != [platform] or labels["riot:artifact_type_id"]["values"] != ["client"]:
        raise ValueError("The published release does not match the requested client.")
    version = labels["riot:artifact_version_id"]["values"]
    if len(version) != 1 or not version[0] or release["compat_version"]["id"] != version[0]:
        raise ValueError("The published release and its compatibility version do not match.")
    url = release["download"]["url"]
    if not re.fullmatch(r"https://teamfighttactics\.secure\.dyn\.riotcdn\.net/channels/public/releases/[A-Fa-f0-9]{16}\.manifest", url):
        raise ValueError("The TFT manifest is not from the expected official channel.")
    if release["download"].get("scd_required"):
        raise ValueError("The TFT manifest requires private access.")
    return url, version[0]


def live_release(version_set):
    """Use the account region's uniquely published Mac and Windows release."""
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            mac, windows = list(pool.map(lambda platform: published_release(platform, version_set), ["macos", "windows"]))
        if mac[1] != windows[1]:
            raise ValueError("The Mac and Windows releases for " + version_set + " are still out of sync.")
        return mac
    except (OSError, ValueError, KeyError, IndexError, TypeError, AttributeError):
        return None


def sync_install_setting():
    """Point Riot's saved install path at GAME (only while the host is stopped)."""
    settings = DATA / "shared/teamfighttactics.live/teamfighttactics.live.product_settings.yaml"
    try:
        with settings.open(newline="") as handle:  # keep Riot's CRLF line endings
            lines = handle.read().splitlines(keepends=True)
    except OSError:
        return
    ending = "\r\n" if lines and lines[0].endswith("\r\n") else "\n"
    wanted = {
        "product_install_full_path": json.dumps(str(GAME)),
        "product_install_root": json.dumps(str(GAME.parent)),
    }
    changed = False
    for index, line in enumerate(lines):
        key = line.split(":", 1)[0]
        if key in wanted and line.rstrip("\r\n") != key + ": " + wanted[key]:
            lines[index] = key + ": " + wanted[key] + ending
            changed = True
    if changed:
        temporary = settings.with_suffix(".yaml.tmp")
        with temporary.open("w", newline="") as handle:
            handle.write("".join(lines))
        temporary.replace(settings)


def update_game(target):
    """Have the Riot host patch the game to the configured manifest, then return."""
    started = time.monotonic()
    deadline = started + 60
    requested = False
    last_shown = -1
    last_activity = None
    while True:
        status, state = api("GET", PATCH_STATE)
        if status == 200 and isinstance(state, dict):
            url = (state.get("configuration") or {}).get("patch_url")
            if target and url and url != target:
                raise RuntimeError(
                    "The running Riot component targets a different release from live. "
                    "Close Riot and TFT, then reopen TFT Live.")
            combined = state.get("combined_patch_state")
            if combined == "up_to_date":
                if requested:
                    print("Update complete.", flush=True)
                return
            if combined in ("out_of_date", "not_installed") and not requested:
                print("Installing or updating TFT to the live release…", flush=True)
                status, _ = api("PUT", PATCH_REQUEST, {})
                if status not in (200, 201, 204):
                    raise RuntimeError("The Riot component refused the update (HTTP " + str(status) + ").")
                requested = True
                deadline = time.monotonic() + 600
                time.sleep(.2)
                continue
            elif combined == "updating":
                details = (state.get("patch_status") or {}).get("progress") or {}
                progress = details.get("progress") or 0
                shown = int(progress) // 10 * 10  # Riot reports 0-100
                if shown > last_shown:
                    print("  " + str(shown) + " %", flush=True)
                    last_shown = shown
                activity = (details.get("phase"), progress, (details.get("update") or {}).get("downloaded_bytes"),
                            (details.get("update") or {}).get("written_bytes"))
                if activity != last_activity:
                    deadline = time.monotonic() + 600
                    last_activity = activity
            elif combined == "bad_install_path" and time.monotonic() - started > 30:
                # Right after a path change Riot briefly reports not_installed while it re-verifies.
                raise RuntimeError("The Riot component does not recognize the TFT installation (" + combined + ").")
            error = (state.get("patch_status") or {}).get("error")
            if requested and state.get("user_cancelled_patching"):
                raise RuntimeError("TFT installation was interrupted. Reopen TFT Live to resume.")
            if requested and error:
                raise RuntimeError("TFT update failed. " + json.dumps(error)[:200])
        if time.monotonic() >= deadline:
            raise RuntimeError("The TFT update has stopped progressing. Reopen TFT Live.")
        time.sleep(2)


def close_normal_client():
    """Quit the regular Riot Client if it is open, unless one of its games is running."""
    status, sessions = api("GET", SESSIONS, lockfile=NORMAL_LOCK)
    if status != 200:
        return
    if isinstance(sessions, dict) and any(
        isinstance(session, dict) and session.get("productId") not in (None, "riot_client")
        for session in sessions.values()
    ):
        raise RuntimeError("A game is running from the regular Riot Client. Close it, then reopen TFT Live.")
    print("Closing the regular Riot Client…", flush=True)
    api("POST", "/process-control/v1/process/quit", lockfile=NORMAL_LOCK)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        time.sleep(1)
        if api("GET", SESSIONS, lockfile=NORMAL_LOCK)[0] != 200:
            time.sleep(2)  # let it release its ports and files
            return
    raise RuntimeError("The regular Riot Client did not close. Close it, then reopen TFT Live.")


def tft_is_running(sessions):
    return isinstance(sessions, dict) and any(
        isinstance(session, dict) and session.get("productId") == "teamfighttactics"
        for session in sessions.values()
    )


def connect_riot(host):
    process = None
    if api("GET", SESSIONS)[0] != 200:
        close_normal_client()
        sync_install_setting()
        with (DATA / "host-console.log").open("ab") as console:
            process = subprocess.Popen([str(host)], stdin=subprocess.DEVNULL,
                                       stdout=console, stderr=subprocess.STDOUT, start_new_session=True)
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        if process is not None and process.poll() is not None:
            raise RuntimeError("The Riot sign-in component stopped during startup (exit code " + str(process.returncode) + ").")
        status, authorization = api("GET", "/rso-auth/v1/authorization/access-token")
        if status == 200 and isinstance(authorization, dict):
            encoded = authorization.get("token", "").split(".")
            if len(encoded) != 3:
                raise RuntimeError("The Riot session did not provide a recognized token.")
            claims = json.loads(base64.urlsafe_b64decode(encoded[1] + "=" * (-len(encoded[1]) % 4)))
            if claims.get("plt", {}).get("id") != "windows":
                raise RuntimeError("The Riot session is not recognized as Windows.")
            return
        time.sleep(1)
    raise RuntimeError("Riot sign-in is still pending. Sign in again, then reopen TFT Live.")


def account_region(current):
    status, userinfo = api("GET", "/rso-auth/v1/authorization/userinfo")
    if status != 200 or not isinstance(userinfo, dict):
        raise RuntimeError("The signed-in Riot account region is unavailable.")
    try:
        region = launcher_config.decode_userinfo(userinfo.get("userInfo"))
    except RuntimeError:
        status, election = api("GET", "/riot-client-lifecycle/v1/league-region-election")
        selected = election.get("selectedRegions", []) if status == 200 and isinstance(election, dict) else []
        if len(selected) != 1 or not isinstance(selected[0], str) or not re.fullmatch(r"[A-Z0-9]{2,8}", selected[0]):
            raise RuntimeError("Finish selecting a server in Riot, then reopen TFT Live.")
        region = selected[0]
    configuration = launcher_config.cached_configuration(DATA)
    if configuration is None:
        configuration = riot_runtime.official_configuration(current, DATA)
    return launcher_config.region_settings(region, configuration)


def main():
    os.umask(0o077)
    DATA.mkdir(parents=True, exist_ok=True, mode=0o700)
    DATA.chmod(0o700)
    with (DATA / "launch.lock").open("w") as launch_lock:
        try:
            fcntl.flock(launch_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("TFT launch is already in progress.")
            return 0

        removed_watcher = riot_runtime.remove_install_watcher(DATA)
        _, sessions = api("GET", SESSIONS)
        if tft_is_running(sessions):
            print("TFT is already running. Updates will be checked on the next launch.", flush=True)
            return 0
        if removed_watcher:
            riot_runtime.quit_client(api, LOCK)
        launcher_config.prepare_files(ROOT, DATA)
        legacy = ROOT / "sdk-host-data"
        if not (DATA / "user").exists() and (legacy / "user").is_dir() and legacy.resolve() != DATA.resolve():
            riot_runtime.quit_client(api, legacy / "user/Config/lockfile")
            for name in ["user", "shared"]:
                if (legacy / name).is_dir():
                    riot_runtime.clone(legacy / name, DATA / name)
        base = DATA / "bootstrap"
        state = riot_runtime.read_state(DATA)
        if not state.get("root") and not (base / "bootstrap-ready.json").is_file():
            base = riot_runtime.bootstrap_runtime(ROOT, DATA, launcher_config.installed_riot())
        if state.get("pending"):
            riot_runtime.quit_client(api, LOCK)
            riot_runtime.rollback(base, DATA)
            state = riot_runtime.read_state(DATA)
        current = riot_runtime.selected_root(base, DATA, state)
        riot_runtime.refresh_host(ROOT, current, DATA, api)
        riot_runtime.wire_configuration(current, DATA)
        print("Sign in to Riot to prepare TFT live.", flush=True)
        connect_riot(current / riot_runtime.HOST_PATH)
        settings = account_region(current)
        release = live_release(settings["version_set"])
        if release is None:
            raise RuntimeError("Unable to confirm the current TFT release for " + settings["region"] + ". Try again later.")
        target, version = release
        print("Live version " + settings["region"] + " — " + version, flush=True)
        changed = launcher_config.configure_region(DATA, settings, target, version)
        status, patch = api("GET", PATCH_STATE)
        loaded = (patch.get("configuration") or {}) if status == 200 and isinstance(patch, dict) else {}
        if changed or (loaded and (loaded.get("patch_url") != target or loaded.get("id") != settings["region"])):
            riot_runtime.quit_client(api, LOCK)
        host = riot_runtime.ensure_runtime(base, DATA, api)

        try:
            connect_riot(host)
        except (RuntimeError, OSError, ValueError) as error:
            if not riot_runtime.read_state(DATA).get("pending"):
                raise
            riot_runtime.quit_client(api, LOCK)
            previous = riot_runtime.rollback(base, DATA)
            riot_runtime.refresh_host(ROOT, previous.parents[3], DATA, api)
            print("Automatically restored the previous Riot components. " + str(error), flush=True)
            connect_riot(previous)
        riot_runtime.confirm(DATA)
        if account_region(current)["region"] != settings["region"]:
            raise RuntimeError("The Riot account changed during setup. Reopen TFT Live to select its server.")

        _, sessions = api("GET", SESSIONS)
        if tft_is_running(sessions):
            print("Riot is ready. TFT is already running with the Windows session.", flush=True)
            return 0

        GAME.parent.mkdir(parents=True, exist_ok=True)
        launcher_config.atomic_json(DATA / "install.json", {"game_path": str(GAME)})
        deadline = time.monotonic() + 30
        while True:
            status, _ = api(
                "PUT", "/rnet-product-registry/v4/products/teamfighttactics/patchlines/live/install-path",
                {"root_path": str(GAME.parent), "full_path": str(GAME)},
            )
            if status != 404 or time.monotonic() >= deadline:
                break
            time.sleep(.5)
        if status not in (200, 201, 204):
            raise RuntimeError("Unable to register the existing TFT installation.")

        update_game(target)
        if not (GAME / "Contents/MacOS/TFTClient-Mac-Shipping").is_file():
            raise RuntimeError("The Riot patcher did not install the expected TFT Mac client.")

        print("Riot is ready. Click Play in the client to launch TFT live.", flush=True)
        return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
