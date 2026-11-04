"""Per-user paths and account-specific TFT configuration."""
import copy
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


LIVE_PATCHLINE = "keystone.products.teamfighttactics.patchlines.live"


def data_directory():
    override = os.environ.get("TFT_LIVE_DATA_DIR")
    if override:
        path = Path(override).expanduser()
        if not path.is_absolute():
            raise RuntimeError("Le dossier de données doit être un chemin absolu.")
        return path
    return Path.home() / "Library/Application Support/TFT Live"


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w") as output:
        json.dump(value, output, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(path)


def prepare_files(assets, data):
    data.mkdir(parents=True, exist_ok=True, mode=0o700)
    data.chmod(0o700)
    destination = data / "riot-sdk-host-override.json"
    if not destination.exists():
        shutil.copyfile(assets / destination.name, destination)
        destination.chmod(0o600)
    system = data / "sdk-host-system.yaml"
    if not system.exists():
        original = (installed_riot() / "Contents/Resources/system.yaml").read_text()
        managed, count = re.subn(r"(?m)^enable_self_update:.*$", "enable_self_update: false", original)
        if not count:
            managed += "\nenable_self_update: false\n"
        temporary = system.with_suffix(".tmp")
        temporary.write_text(managed)
        temporary.chmod(0o600)
        temporary.replace(system)


def installed_riot():
    candidates = [Path("/Users/Shared/Riot Games/Riot Client.app"), Path("/Applications/Riot Client.app"),
                  Path.home() / "Applications/Riot Client.app"]
    for candidate in candidates:
        if (candidate / "Contents/Frameworks/RiotGamesApi.framework/RiotGamesApi").is_file():
            return candidate
    try:
        result = subprocess.run(["/usr/bin/mdfind", "kMDItemCFBundleIdentifier == 'com.riotgames.RiotGames.RiotClient'"],
                                capture_output=True, text=True, timeout=5, check=True)
        for value in result.stdout.splitlines():
            candidate = Path(value)
            if (candidate / "Contents/Frameworks/RiotGamesApi.framework/RiotGamesApi").is_file():
                return candidate
    except (OSError, subprocess.SubprocessError):
        pass
    raise RuntimeError("Installe le Riot Client officiel sur ce Mac, puis ouvre TFT Live.")


def game_path(data):
    saved = data / "install.json"
    if saved.is_file():
        path = Path(json.loads(saved.read_text())["game_path"])
        if not path.is_absolute():
            raise RuntimeError("Le dossier d'installation TFT mémorisé est invalide.")
        return path
    candidates = [Path.home() / "Applications/Teamfight Tactics (Live).app",
                  Path("/Applications/Teamfight Tactics (Live).app")]
    for candidate in candidates:
        if (candidate / "Contents/MacOS/TFTClient-Mac-Shipping").is_file() and os.access(candidate, os.W_OK):
            return candidate
    return candidates[0]


def decode_userinfo(value):
    if isinstance(value, str):
        value = json.loads(value)
    if not isinstance(value, dict):
        raise RuntimeError("Riot ne fournit pas les informations de région du compte.")
    lol = value.get("lol") or {}
    region = lol.get("cpid") if isinstance(lol, dict) else None
    if not region:
        regions = value.get("lol_region", [])
        if isinstance(regions, list):
            selected = {entry.get("cpid") for entry in regions if isinstance(entry, dict) and entry.get("active") is True}
            selected.discard(None)
            if len(selected) == 1:
                region = selected.pop()
    if not isinstance(region, str) or not re.fullmatch(r"[A-Z0-9]{2,8}", region):
        raise RuntimeError("La région TFT du compte n'est pas disponible.")
    return region


def region_settings(region, configuration):
    product = configuration.get(LIVE_PATCHLINE, {})
    configs = product.get("platforms", {}).get("win", {}).get("configurations", [])
    matches = [entry for entry in configs if entry.get("id") == region
               or region in entry.get("region_data", {}).get("available_regions", [])]
    if len(matches) != 1:
        raise RuntimeError("La configuration Riot de la région " + region + " est indisponible.")
    region = matches[0]["id"]
    version_set = configuration.get("tft.client_settings.version_sets", {}).get(region)
    if not isinstance(version_set, str) or not version_set.startswith("live-"):
        raise RuntimeError("Riot ne propose pas de canal TFT live pour la région " + region + ".")
    aliases = matches[0].get("region_data", {}).get("available_regions") or [region]
    return {"region": region, "version_set": version_set, "client_region": aliases[0], "aliases": aliases}


def cached_configuration(data):
    path = data / "user/Config/ClientConfiguration.json"
    if not path.is_file():
        return None
    entries = json.loads(path.read_text()).get("public", [])
    matches = [entry for entry in entries if LIVE_PATCHLINE in entry.get("data", {})
               and "tft.client_settings.version_sets" in entry.get("data", {})]
    if not matches:
        return None
    return max(matches, key=lambda entry: entry.get("updateTime", 0))["data"]


def configure_region(data, settings, manifest, version):
    path = data / "riot-sdk-host-override.json"
    original = json.loads(path.read_text())
    updated = copy.deepcopy(original)
    product = updated["public"][LIVE_PATCHLINE]
    for metadata in product.get("metadata", {}).values():
        metadata.pop("product_dependency", None)
    product.get("metadata", {}).pop("mac", None)
    platform = copy.deepcopy(product["platforms"]["mac"])
    configuration = copy.deepcopy(platform["configurations"][0])
    configuration.update(id=settings["region"], patch_url=manifest, dependencies=[], region_data={
        "available_regions": settings["aliases"], "default_region": settings["region"],
    })
    platform.update(auto_patch=False, install_dir="Teamfight Tactics (Live).app", dependencies=[], configurations=[configuration])
    product["platforms"] = {name: copy.deepcopy(platform) for name in ["mac", "win", "windows"]}
    for metadata in product.get("metadata", {}).values():
        if "available_platforms" in metadata:
            metadata["available_platforms"] = ["mac", "win", "windows"]
    region_path = data / "riot-region.txt"
    old_region = region_path.read_text().strip() if region_path.exists() else None
    changed = updated != original or old_region != settings["client_region"]
    if updated != original:
        atomic_json(path, updated)
    temporary = region_path.with_suffix(".tmp")
    temporary.write_text(settings["client_region"] + "\n")
    temporary.replace(region_path)
    selection = dict(settings, manifest=manifest, version=version)
    atomic_json(data / "selection.json", selection)
    return changed
