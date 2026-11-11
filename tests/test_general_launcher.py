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
            interface = current / riot_runtime.LEGACY_RIOT_APP / "Contents/Frameworks/Riot Client.app"
            interface.mkdir(parents=True)
            (interface / "UI").write_bytes(b"signed UI")
            with patch.object(riot_runtime, "quit_client") as quit_client, \
                 patch.object(riot_runtime.subprocess, "run") as run:
                riot_runtime.refresh_host(assets, current, root, None)
                self.assertEqual(host.read_bytes(), b"fixed host")
                self.assertFalse((current / riot_runtime.LEGACY_RIOT_APP).exists())
                original = current / riot_runtime.RIOT_APP / "Contents/Frameworks/Riot Client.app/UI"
                shared = current / riot_runtime.HOST_PATH.parents[1] / "Frameworks/Riot Client.app/UI"
                self.assertTrue(original.samefile(shared))
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

    def test_failed_interface_signing_restores_the_previous_copy(self):
        with tempfile.TemporaryDirectory() as temporary:
            current = Path(temporary)
            source = current / riot_runtime.RIOT_APP / "Contents/Frameworks/Riot Client.app"
            source.mkdir(parents=True)
            (source / "UI").write_bytes(b"new UI")
            interface = current / riot_runtime.HOST_PATH.parents[1] / "Frameworks/Riot Client.app"
            interface.mkdir(parents=True)
            (interface / "UI").write_bytes(b"old UI")
            with patch.object(riot_runtime.subprocess, "run", side_effect=RuntimeError("signing failed")):
                with self.assertRaises(RuntimeError):
                    riot_runtime.share_interface(current)
            self.assertEqual((interface / "UI").read_bytes(), b"old UI")
            with patch.object(riot_runtime.subprocess, "run"):
                riot_runtime.share_interface(current)
            self.assertTrue((source / "UI").samefile(interface / "UI"))

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


class RuntimeRepairTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.data = Path(self.temporary.name).resolve()
        self.current = self.data / "runtimes/current"
        self.make_components(self.current)
        (self.current / "sdk-ready.json").write_text(json.dumps({"manifest": "old", "address": 512}))
        riot_runtime.write_state(self.data, {"root": str(self.current), "manifest": "old"})
        self.user = self.data / "user/session"
        self.user.parent.mkdir()
        self.user.write_text("preserved")

    def make_components(self, directory):
        for name in (riot_runtime.RIOT_APP, "sdk-windows-override-arm64/RiotGamesApi.framework",
                     str(riot_runtime.HOST_PATH.parents[2])):
            path = directory / name / "resource"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"original")

    def rebuilt(self, assets, data, source):
        self.assertEqual(source, self.current / riot_runtime.RIOT_APP)
        directory = data / "bootstrap"
        self.make_components(directory)
        (directory / "bootstrap-ready.json").write_text(json.dumps({"address": 768}))
        return directory

    def test_unchanged_components_reuse_validation_and_changed_files_are_checked(self):
        with patch.object(riot_runtime, "refresh_host"), patch.object(riot_runtime, "validate_candidate") as validate:
            riot_runtime.ensure_healthy(self.data, self.current, self.data, None)
            validate.assert_called_once()
            validate.reset_mock()
            backup = self.current.with_name("current.repair-backup")
            backup.mkdir()
            (backup / "leftover").touch()
            riot_runtime.ensure_healthy(self.data, self.current, self.data, None)
            validate.assert_not_called()
            self.assertFalse(backup.exists())
            resource = self.current / riot_runtime.RIOT_APP / "resource"
            info = resource.stat()
            resource.write_bytes(b"modified")
            os.utime(resource, ns=(info.st_atime_ns, info.st_mtime_ns))
            riot_runtime.ensure_healthy(self.data, self.current, self.data, None)
            validate.assert_called_once()

    def test_missing_sdk_is_rebuilt_and_personal_data_is_preserved(self):
        import shutil
        shutil.rmtree(self.current / "sdk-windows-override-arm64")
        with patch.object(riot_runtime, "refresh_host"), patch.object(riot_runtime, "quit_client"), \
             patch.object(riot_runtime.subprocess, "run") as run, \
             patch.object(riot_runtime, "bootstrap_runtime", side_effect=self.rebuilt), \
             patch.object(riot_runtime, "validate_candidate"):
            run.return_value.returncode = 0
            self.assertEqual(riot_runtime.ensure_healthy(self.data, self.current, self.data, None), self.current)
        self.assertTrue((self.current / "sdk-windows-override-arm64/RiotGamesApi.framework/resource").exists())
        self.assertEqual(json.loads((self.current / "sdk-ready.json").read_text())["manifest"], "old")
        self.assertEqual(riot_runtime.read_state(self.data)["manifest"], "old")
        self.assertEqual(self.user.read_text(), "preserved")
        self.assertFalse(self.current.with_name("current.repair-backup").exists())

    def test_failed_replacement_restores_the_original_directory(self):
        import shutil
        shutil.rmtree(self.current / "sdk-windows-override-arm64")
        with patch.object(riot_runtime, "refresh_host"), patch.object(riot_runtime, "quit_client"), \
             patch.object(riot_runtime.subprocess, "run") as run, \
             patch.object(riot_runtime, "bootstrap_runtime", side_effect=self.rebuilt), \
             patch.object(riot_runtime, "validate_candidate", side_effect=[None, RuntimeError("verification failed")]):
            run.return_value.returncode = 0
            with self.assertRaisesRegex(RuntimeError, "verification failed"):
                riot_runtime.ensure_healthy(self.data, self.current, self.data, None)
        self.assertEqual(json.loads((self.current / "sdk-ready.json").read_text())["address"], 512)
        self.assertEqual(self.user.read_text(), "preserved")

    def test_damaged_source_runtime_reboots_from_the_official_installation(self):
        installed = self.data / "Official Riot.app"
        def rebuilt(assets, data, source):
            self.assertEqual(source, installed)
            directory = data / "bootstrap"
            self.make_components(directory)
            (directory / "bootstrap-ready.json").write_text(json.dumps({"address": 768}))
            return directory
        with patch.object(riot_runtime, "refresh_host"), patch.object(riot_runtime, "quit_client"), \
             patch.object(riot_runtime.subprocess, "run") as run, \
             patch.object(configuration, "installed_riot", return_value=installed), \
             patch.object(riot_runtime, "bootstrap_runtime", side_effect=rebuilt), \
             patch.object(riot_runtime, "validate_candidate", side_effect=[RuntimeError("damaged source"), None, None]):
            run.return_value.returncode = 1
            repaired = riot_runtime.ensure_healthy(self.data, self.current, self.data, None)
        self.assertEqual(repaired, self.data / "bootstrap")
        self.assertEqual(riot_runtime.read_state(self.data), {"root": str(repaired), "manifest": None})
        self.assertEqual(self.user.read_text(), "preserved")


class LogRotationTests(unittest.TestCase):
    def test_riot_session_logs_keep_the_three_newest_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            data = Path(temporary)
            logs = data / "logs/Riot Client Logs"
            logs.mkdir(parents=True)
            for index in range(7):
                path = logs / (str(index) + ".log")
                path.write_text(str(index))
                os.utime(path, ns=(index + 1, index + 1))
            external = data / "unrelated.log"
            external.write_text("preserved")
            (logs / "linked.log").symlink_to(external)
            configuration.prune_logs(data)
            self.assertEqual({path.name for path in logs.iterdir()}, {"4.log", "5.log", "6.log", "linked.log"})
            self.assertEqual(external.read_text(), "preserved")

    def test_native_logs_are_bounded_with_concurrent_writers(self):
        import subprocess
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "log-test.cpp"
            binary = root / "log-test"
            source.write_text('''#include "rotating_log.h"
int main(int argc, char **argv) {
    std::string message(64, argv[2][0]);
    for (int index = 0; index < std::stoi(argv[3]); ++index) {
        if (!appendRotatingLog(argv[1], message.data(), message.size(), 128)) return 1;
    }
    return 0;
}
''')
            subprocess.run(["clang++", "-std=c++17", "-I", str(launcher.ROOT), str(source), "-o", str(binary)], check=True)
            path = root / "console.log"
            path.write_bytes(b"old" * 1024)
            subprocess.run([str(binary), str(path), "A", "4"], check=True)
            self.assertEqual(path.with_name("console.log.2").stat().st_size, 128)
            writers = [subprocess.Popen([str(binary), str(path), letter, "30"]) for letter in "BCDE"]
            for writer in writers:
                self.assertEqual(writer.wait(timeout=10), 0)
            logs = [path] + [path.with_name("console.log." + str(index)) for index in range(1, 4)]
            for log in logs:
                contents = log.read_bytes()
                self.assertEqual(len(contents), 128)
                for offset in (0, 64):
                    self.assertEqual(len(set(contents[offset:offset + 64])), 1)
            self.assertFalse(path.with_name("console.log.4").exists())

    def test_shell_log_keeps_three_bounded_archives(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "launcher.log"
            for index in range(6):
                path.write_bytes(bytes([index]) * 512)
                configuration.rotate_log(path, limit=128)
            self.assertFalse(path.exists())
            self.assertEqual(path.with_name("launcher.log.1").read_bytes(), bytes([5]) * 128)
            self.assertEqual(path.with_name("launcher.log.3").read_bytes(), bytes([3]) * 128)
            self.assertFalse(path.with_name("launcher.log.4").exists())


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
