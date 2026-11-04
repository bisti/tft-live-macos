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
        raise ValueError("Le canal TFT demandé est invalide.")
    request = urllib.request.Request(SIEVE.format(platform=platform, version_set=version_set), headers={"User-Agent": "TFT-Live-Launcher/1.0"})
    with urllib.request.urlopen(request, timeout=15) as response:
        releases = json.load(response).get("releases", [])
    if len(releases) != 1:
        raise ValueError("Le canal " + version_set + " ne désigne pas une version unique.")
    release = releases[0]
    labels = release["release"]["labels"]
    if labels["riot:platform"]["values"] != [platform] or labels["riot:artifact_type_id"]["values"] != ["client"]:
        raise ValueError("La version publiée ne correspond pas au client demandé.")
    version = labels["riot:artifact_version_id"]["values"]
    if len(version) != 1 or not version[0] or release["compat_version"]["id"] != version[0]:
        raise ValueError("La version publiée et sa compatibilité sont incohérentes.")
    url = release["download"]["url"]
    if not re.fullmatch(r"https://teamfighttactics\.secure\.dyn\.riotcdn\.net/channels/public/releases/[A-Fa-f0-9]{16}\.manifest", url):
        raise ValueError("Le manifeste TFT ne provient pas du canal officiel attendu.")
    if release["download"].get("scd_required"):
        raise ValueError("Le manifeste TFT nécessite un accès privé.")
    return url, version[0]


def live_release(version_set):
    """Use the account region's uniquely published Mac and Windows release."""
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            mac, windows = list(pool.map(lambda platform: published_release(platform, version_set), ["macos", "windows"]))
        if mac[1] != windows[1]:
            raise ValueError("Le déploiement Mac et Windows de " + version_set + " est encore désynchronisé.")
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
                    "Le composant Riot ouvert vise une autre version que le live. "
                    "Ferme la fenêtre Riot (et TFT), puis relance TFT Live.")
            combined = state.get("combined_patch_state")
            if combined == "up_to_date":
                if requested:
                    print("Mise à jour terminée.", flush=True)
                return
            if combined in ("out_of_date", "not_installed") and not requested:
                print("Installation ou mise à jour de TFT vers la version live…", flush=True)
                status, _ = api("PUT", PATCH_REQUEST, {})
                if status not in (200, 201, 204):
                    raise RuntimeError("Le composant Riot refuse la mise à jour (HTTP " + str(status) + ").")
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
                raise RuntimeError("Le composant Riot ne reconnaît pas l'installation TFT (" + combined + ").")
            error = (state.get("patch_status") or {}).get("error")
            if requested and state.get("user_cancelled_patching"):
                raise RuntimeError("L'installation TFT a été interrompue. Rouvre TFT Live pour la reprendre.")
            if requested and error:
                raise RuntimeError("La mise à jour de TFT a échoué : " + json.dumps(error)[:200])
        if time.monotonic() >= deadline:
            raise RuntimeError("La mise à jour de TFT ne progresse plus. Relance TFT Live.")
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
        raise RuntimeError("Un jeu est ouvert depuis le Riot Client habituel. Ferme-le, puis relance TFT Live.")
    print("Fermeture du Riot Client habituel...", flush=True)
    api("POST", "/process-control/v1/process/quit", lockfile=NORMAL_LOCK)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        time.sleep(1)
        if api("GET", SESSIONS, lockfile=NORMAL_LOCK)[0] != 200:
            time.sleep(2)  # let it release its ports and files
            return
    raise RuntimeError("Le Riot Client habituel ne s'est pas fermé. Ferme-le, puis relance TFT Live.")


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
            raise RuntimeError("Le composant de connexion Riot s'est arrêté au démarrage (code " + str(process.returncode) + ").")
        status, authorization = api("GET", "/rso-auth/v1/authorization/access-token")
        if status == 200 and isinstance(authorization, dict):
            encoded = authorization.get("token", "").split(".")
            if len(encoded) != 3:
                raise RuntimeError("La session Riot ne fournit pas de jeton reconnu.")
            claims = json.loads(base64.urlsafe_b64decode(encoded[1] + "=" * (-len(encoded[1]) % 4)))
            if claims.get("plt", {}).get("id") != "windows":
                raise RuntimeError("La session Riot obtenue n'est pas reconnue comme Windows.")
            return
        time.sleep(1)
    raise RuntimeError("Connexion Riot en attente. Reconnecte-toi puis relance TFT Live.")


def account_region(current):
    status, userinfo = api("GET", "/rso-auth/v1/authorization/userinfo")
    if status != 200 or not isinstance(userinfo, dict):
        raise RuntimeError("La région du compte Riot connecté n'est pas disponible.")
    try:
        region = launcher_config.decode_userinfo(userinfo.get("userInfo"))
    except RuntimeError:
        status, election = api("GET", "/riot-client-lifecycle/v1/league-region-election")
        selected = election.get("selectedRegions", []) if status == 200 and isinstance(election, dict) else []
        if len(selected) != 1 or not isinstance(selected[0], str) or not re.fullmatch(r"[A-Z0-9]{2,8}", selected[0]):
            raise RuntimeError("Termine le choix du serveur dans Riot, puis rouvre TFT Live.")
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
            print("Un lancement de TFT est déjà en cours.")
            return 0

        _, sessions = api("GET", SESSIONS)
        if tft_is_running(sessions):
            print("TFT est déjà ouvert. Les mises à jour seront vérifiées au prochain lancement.", flush=True)
            return 0
        launcher_config.prepare_files(ROOT, DATA)
        legacy = ROOT / "sdk-host-data"
        if not (DATA / "user").exists() and (legacy / "user").is_dir() and legacy.resolve() != DATA.resolve():
            riot_runtime.quit_client(api, legacy / "user/Config/lockfile")
            for name in ["user", "shared"]:
                if (legacy / name).is_dir():
                    riot_runtime.clone(legacy / name, DATA / name)
        base = DATA / "bootstrap"
        if not (base / "bootstrap-ready.json").is_file():
            base = riot_runtime.bootstrap_runtime(ROOT, DATA, launcher_config.installed_riot())
        state = riot_runtime.read_state(DATA)
        if state.get("pending"):
            riot_runtime.quit_client(api, LOCK)
            riot_runtime.rollback(base, DATA)
            state = riot_runtime.read_state(DATA)
        current = riot_runtime.selected_root(base, DATA, state)
        riot_runtime.wire_configuration(current, DATA)
        print("Connecte-toi dans Riot pour préparer TFT live.", flush=True)
        connect_riot(current / riot_runtime.HOST_PATH)
        settings = account_region(current)
        release = live_release(settings["version_set"])
        if release is None:
            raise RuntimeError("Impossible de confirmer la version TFT active pour " + settings["region"] + ". Réessaie plus tard.")
        target, version = release
        print("Version live " + settings["region"] + " — " + version, flush=True)
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
            print("Retour automatique aux composants Riot précédents. " + str(error), flush=True)
            connect_riot(previous)
        riot_runtime.confirm(DATA)
        if account_region(current)["region"] != settings["region"]:
            raise RuntimeError("Le compte Riot a changé pendant la préparation. Rouvre TFT Live pour sélectionner son serveur.")

        _, sessions = api("GET", SESSIONS)
        if tft_is_running(sessions):
            print("Riot est prêt. TFT est déjà ouvert avec la session Windows.", flush=True)
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
            raise RuntimeError("Impossible de référencer l'installation TFT existante.")

        update_game(target)
        if not (GAME / "Contents/MacOS/TFTClient-Mac-Shipping").is_file():
            raise RuntimeError("Le patcher Riot n'a pas installé le client TFT Mac attendu.")

        print("Riot est prêt. Clique sur Jouer dans le client pour lancer TFT live.", flush=True)
        return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
