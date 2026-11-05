import json
import io
import os
import plistlib
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

import launcher_config as configuration
import launch_windows_live as launcher
import riot_runtime
from riot_adapter.apple_silicon import thin_binary


def region_configuration():
    aliases = {"EUW1": ["EUW", "EUW1"], "NA1": ["NA", "NA1"], "KR": ["KR"], "SG2": ["SG2"], "VN2": ["VN2"], "NEW1": ["NEW1"]}
    return {
        "tft.client_settings.version_sets": {region: "live-" + region for region in aliases},
        configuration.LIVE_PATCHLINE: {"platforms": {"win": {"configurations": [
            {"id": region, "region_data": {"available_regions": values}} for region, values in aliases.items()
        ]}}},
    }


class RegionTests(unittest.TestCase):
    def test_account_region_overrides_country_and_device_location(self):
        value = {"country": "FR", "region": "eu", "lol": {"cpid": "KR"}}
        self.assertEqual(configuration.decode_userinfo(json.dumps(value)), "KR")

    def test_active_region_is_supported_without_main_lol_account(self):
        value = {"lol_region": [{"cpid": "EUW1", "active": False}, {"cpid": "NA1", "active": True}]}
        self.assertEqual(configuration.decode_userinfo(value), "NA1")

    def test_missing_and_ambiguous_account_regions_are_rejected(self):
        for value in [{"country": "US"}, {"lol_region": [{"cpid": "KR", "active": True}, {"cpid": "NA1", "active": True}]}]:
            with self.assertRaises(RuntimeError):
                configuration.decode_userinfo(value)

    def test_regions_and_future_region_are_derived_from_riot_configuration(self):
        public = region_configuration()
        for region in ["EUW1", "NA1", "KR", "SG2", "VN2", "NEW1"]:
            settings = configuration.region_settings(region, public)
            self.assertEqual(settings["version_set"], "live-" + region)
            self.assertEqual(settings["region"], region)
        self.assertEqual(configuration.region_settings("NA", public)["region"], "NA1")

    def test_no_live_channel_is_not_replaced_by_another_region(self):
        public = region_configuration()
        public["tft.client_settings.version_sets"]["KR"] = "pbe-global"
        with self.assertRaises(RuntimeError):
            configuration.region_settings("KR", public)

    def test_override_replaces_both_manifest_and_regional_configuration(self):
        source = Path(launcher.ROOT / "riot-sdk-host-override.json")
        with tempfile.TemporaryDirectory() as temporary:
            data = Path(temporary)
            (data / source.name).write_bytes(source.read_bytes())
            settings = configuration.region_settings("NA1", region_configuration())
            self.assertTrue(configuration.configure_region(data, settings, "new-mac-manifest", "new-version"))
            public = json.loads((data / source.name).read_text())["public"]
            product = public[configuration.LIVE_PATCHLINE]
            for platform in product["platforms"].values():
                self.assertEqual(platform["configurations"][0]["id"], "NA1")
                self.assertEqual(platform["configurations"][0]["patch_url"], "new-mac-manifest")
            self.assertNotIn("product_dependency", product["metadata"]["default"])
            self.assertEqual((data / "riot-region.txt").read_text().strip(), "NA")
            self.assertFalse(configuration.configure_region(data, settings, "new-mac-manifest", "new-version"))
            settings = configuration.region_settings("KR", region_configuration())
            self.assertTrue(configuration.configure_region(data, settings, "new-mac-manifest", "new-version"))

    def test_server_selected_in_riot_is_used_when_userinfo_has_no_region(self):
        def api(method, route, **kwargs):
            if route.endswith('/userinfo'):
                return 200, {"userInfo": "{}"}
            return 200, {"selectedRegions": ["KR"]}
        with patch.object(launcher, "api", side_effect=api), patch.object(configuration, "cached_configuration", return_value=region_configuration()):
            self.assertEqual(launcher.account_region(Path('/unused'))["region"], "KR")


class InstallationTests(unittest.TestCase):
    def test_host_fixes_reach_cached_runtimes_and_are_not_reapplied(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            assets = root / "assets"
            assets.mkdir()
            (assets / "SDKHost").write_bytes(b"fixed host")
            current = root / "runtime"
            host = current / riot_runtime.HOST_PATH
            host.parent.mkdir(parents=True)
            host.write_bytes(b"old host")
            with patch.object(riot_runtime, "quit_client") as quit_client, \
                 patch.object(riot_runtime.subprocess, "run") as run:
                riot_runtime.refresh_host(assets, current, root, None)
                self.assertEqual(host.read_bytes(), b"fixed host")
                quit_client.assert_called_once()
                self.assertEqual(run.call_count, 2)
                quit_client.reset_mock()
                run.reset_mock()
                riot_runtime.refresh_host(assets, current, root, None)
                quit_client.assert_not_called()
                run.assert_not_called()
                host.write_bytes(b"interrupted replacement")
                riot_runtime.refresh_host(assets, current, root, None)
                self.assertEqual(host.read_bytes(), b"fixed host")
                quit_client.assert_called_once()

    def test_legacy_watcher_is_removed_only_for_the_private_host(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            data = home / "Library/Application Support/TFT Live"
            path = home / "Library/LaunchAgents/com.riot.riotclient.checkinstalls.plist"
            path.parent.mkdir(parents=True)
            for executable, owned in [(home / "Riot Client.app/Contents/MacOS/RiotClientServices", False),
                                      (data / "bootstrap" / riot_runtime.HOST_PATH, True)]:
                with self.subTest(owned=owned):
                    path.write_bytes(plistlib.dumps({"ProgramArguments": [str(executable), "--agent"]}))
                    with patch.object(Path, "home", return_value=home), \
                         patch.object(riot_runtime.subprocess, "run") as run:
                        run.return_value.returncode = 113
                        self.assertEqual(riot_runtime.remove_install_watcher(data), owned)
                        self.assertEqual(path.exists(), not owned)
                        self.assertEqual(run.call_count, 2 if owned else 0)

    def test_loaded_watcher_is_preserved_when_unloading_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            data = home / "data"
            path = home / "Library/LaunchAgents/com.riot.riotclient.checkinstalls.plist"
            path.parent.mkdir(parents=True)
            path.write_bytes(plistlib.dumps({"ProgramArguments": [str(data / "bootstrap" / riot_runtime.HOST_PATH)]}))
            with patch.object(Path, "home", return_value=home), \
                 patch.object(riot_runtime.subprocess, "run") as run:
                run.return_value.returncode = 0
                with self.assertRaisesRegex(RuntimeError, "watcher"):
                    riot_runtime.remove_install_watcher(data)
            self.assertTrue(path.is_file())

    def test_system_configuration_is_generated_from_the_installed_client(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            assets = root / 'assets'
            assets.mkdir()
            (assets / 'riot-sdk-host-override.json').write_text('{}')
            riot = root / 'Riot Client.app'
            resources = riot / 'Contents/Resources'
            resources.mkdir(parents=True)
            original = 'enable_self_update: true\nother_setting: keep\n'
            (resources / 'system.yaml').write_text(original)
            data = root / 'data'
            with patch.object(configuration, 'installed_riot', return_value=riot):
                configuration.prepare_files(assets, data)
            self.assertEqual((data / 'sdk-host-system.yaml').read_text(), 'enable_self_update: false\nother_setting: keep\n')
            self.assertEqual((resources / 'system.yaml').read_text(), original)

    def test_progress_percentages_are_not_repeated_when_phases_reset(self):
        progress = iter([10, 10, 0, 10, 50, 20, 50, 100])
        def api(method, route, body=None, **kwargs):
            value = next(progress, None)
            if value is None:
                return 200, {"combined_patch_state": "up_to_date"}
            return 200, {"combined_patch_state": "updating", "patch_status": {"progress": {"progress": value}}}
        with patch.object(launcher, "api", side_effect=api), patch.object(launcher.time, "sleep"), \
             patch('sys.stdout', new_callable=io.StringIO) as output:
            launcher.update_game(None)
        self.assertEqual(output.getvalue().splitlines(), ["  10 %", "  50 %", "  100 %"])

    def test_absent_game_requests_native_installation(self):
        states = iter(["not_installed", "updating", "up_to_date"])
        calls = []
        def api(method, route, body=None, **kwargs):
            calls.append((method, route))
            if method == "PUT":
                return 201, None
            return 200, {"combined_patch_state": next(states), "configuration": {"patch_url": "manifest"},
                         "patch_status": {"progress": {"progress": 50}}}
        with patch.object(launcher, "api", side_effect=api), patch.object(launcher.time, "sleep"):
            launcher.update_game("manifest")
        self.assertEqual(calls.count(("PUT", launcher.PATCH_REQUEST)), 1)

    def test_partial_installation_can_be_resumed(self):
        with tempfile.TemporaryDirectory() as temporary:
            data = Path(temporary)
            target = data / "Games/Teamfight Tactics.app"
            target.mkdir(parents=True)
            configuration.atomic_json(data / "install.json", {"game_path": str(target)})
            self.assertEqual(configuration.game_path(data), target)

    def test_cancelled_installation_stops_and_can_be_retried(self):
        responses = iter([(200, {"combined_patch_state":"not_installed"}), (201, None),
                          (200, {"combined_patch_state":"out_of_date", "user_cancelled_patching":True})])
        with patch.object(launcher, "api", side_effect=lambda *args, **kwargs: next(responses)), patch.object(launcher.time, "sleep"):
            with self.assertRaisesRegex(RuntimeError, "resume"):
                launcher.update_game(None)

    def test_new_user_gets_a_writable_per_user_game_location(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "another-account"
            data = Path(temporary) / "data"
            data.mkdir()
            with patch.object(Path, "home", return_value=home), patch.object(os, "access", return_value=False):
                self.assertEqual(configuration.game_path(data), home / "Applications/Teamfight Tactics (Live).app")

    def test_data_directory_is_derived_from_the_current_user(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(Path, "home", return_value=Path('/Users/another-account')):
            self.assertEqual(configuration.data_directory(), Path('/Users/another-account/Library/Application Support/TFT Live'))

    def test_runtime_links_are_relocated_to_the_new_user_profile(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = root / "runtime"
            runtime.mkdir()
            riot_runtime.wire_configuration(runtime, root / "old-profile")
            riot_runtime.wire_configuration(runtime, root / "new-profile")
            self.assertEqual((runtime / "sdk-host-data").resolve(), (root / "new-profile").resolve())

    def test_shutdown_reaps_a_client_spawned_by_the_same_launcher(self):
        with tempfile.TemporaryDirectory() as temporary:
            lock = Path(temporary) / "lockfile"
            lock.write_text("SDKHost:12345:1:unused:https")
            responses = iter([(200, {}), (200, None), (0, None)])
            with patch.object(riot_runtime.os, "waitpid", return_value=(12345, 0)), \
                 patch.object(riot_runtime.os, "kill") as kill, patch.object(riot_runtime.time, "sleep"):
                riot_runtime.quit_client(lambda *args, **kwargs: next(responses), lock)
            kill.assert_not_called()


class NativeSliceTests(unittest.TestCase):
    def test_arm64_extraction_does_not_require_developer_tools(self):
        for wide in [False, True]:
            data = bytearray(0x140)
            data[:8] = struct.pack(">4sI", b"\xca\xfe\xba\xbf" if wide else b"\xca\xfe\xba\xbe", 2)
            if wide:
                struct.pack_into(">IIQQII", data, 8, 0x1000007, 3, 0x80, 16, 0, 0)
                struct.pack_into(">IIQQII", data, 40, 0x100000c, 0, 0x100, 16, 0, 0)
            else:
                struct.pack_into(">IIIII", data, 8, 0x1000007, 3, 0x80, 16, 0)
                struct.pack_into(">IIIII", data, 28, 0x100000c, 0, 0x100, 16, 0)
            native = struct.pack("<4I", 0xfeedfacf, 0x100000c, 0, 6)
            data[0x100:0x110] = native
            with tempfile.TemporaryDirectory() as temporary:
                binary = Path(temporary) / "universal"
                binary.write_bytes(data)
                with patch.object(riot_runtime.subprocess, "run", side_effect=AssertionError("No external tool allowed")):
                    thin_binary(binary)
                self.assertEqual(binary.read_bytes(), native)


if __name__ == "__main__":
    unittest.main()
