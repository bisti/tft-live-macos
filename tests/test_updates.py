import io
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

import launch_windows_live as launcher
import riot_runtime
from riot_adapter.sdk_patch import patch_windows_sdk


def release(platform="macos", version="live-version", manifest="1234567890ABCDEF"):
    return {
        "release": {"labels": {
            "riot:platform": {"values": [platform]},
            "riot:artifact_type_id": {"values": ["client"]},
            "riot:artifact_version_id": {"values": [version]},
        }},
        "compat_version": {"id": version},
        "download": {"url": "https://teamfighttactics.secure.dyn.riotcdn.net/channels/public/releases/" + manifest + ".manifest"},
    }


class LiveReleaseTests(unittest.TestCase):
    def test_published_query_and_matching_platforms(self):
        urls = []

        def response(request, **kwargs):
            urls.append(request.full_url)
            platform = "windows" if "=windows&" in request.full_url else "macos"
            return io.BytesIO(json.dumps({"releases": [release(platform)]}).encode())

        with patch.object(launcher.urllib.request, "urlopen", side_effect=response):
            result = launcher.live_release("live-EUW1")
        self.assertEqual(result[1], "live-version")
        self.assertEqual(len(urls), 2)
        self.assertTrue(all("live-EUW1" in url and "q%5Bpublished%5D=true" in url for url in urls))

    def test_ambiguous_or_empty_publication_is_rejected(self):
        for releases in [[], [release(), release(version="newer-prepublication")]]:
            with self.subTest(count=len(releases)), patch.object(
                launcher.urllib.request, "urlopen", return_value=io.BytesIO(json.dumps({"releases": releases}).encode())
            ):
                with self.assertRaises(ValueError):
                    launcher.published_release("macos", "live-EUW1")

    def test_inconsistent_metadata_is_rejected(self):
        cases = [release("windows"), release()]
        cases[1]["compat_version"]["id"] = "another-version"
        foreign = release()
        foreign["download"]["url"] = "https://example.com/1234567890ABCDEF.manifest"
        cases.append(foreign)
        for entry in cases:
            with patch.object(launcher.urllib.request, "urlopen", return_value=io.BytesIO(json.dumps({"releases": [entry]}).encode())):
                with self.assertRaises(ValueError):
                    launcher.published_release("macos", "live-EUW1")

    def test_partial_regional_rollout_keeps_existing_version(self):
        def selected(platform, version_set):
            return "manifest", "old" if platform == "macos" else "new"
        with patch.object(launcher, "published_release", side_effect=selected):
            self.assertIsNone(launcher.live_release("live-EUW1"))

    def test_each_region_uses_its_own_published_version(self):
        def response(request, **kwargs):
            platform = "windows" if "=windows&" in request.full_url else "macos"
            region = request.full_url.split('/version-sets/')[1].split('?')[0]
            return io.BytesIO(json.dumps({"releases":[release(platform, version=region+'-version')]}).encode())
        with patch.object(launcher.urllib.request, "urlopen", side_effect=response):
            self.assertEqual(launcher.live_release('live-NA1')[1], 'live-NA1-version')
            self.assertEqual(launcher.live_release('live-KR')[1], 'live-KR-version')


class RuntimeStateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.data = self.root / "data"
        self.data.mkdir()
        self.candidate = self.data / "runtimes/new"
        self.candidate.mkdir(parents=True)

    def test_atomic_activation_and_rollback(self):
        with patch.object(riot_runtime, "official_manifest", return_value="new"), \
             patch.object(riot_runtime, "prepare_candidate", return_value=self.candidate), \
             patch.object(riot_runtime, "quit_client"):
            host = riot_runtime.ensure_runtime(self.root, self.data, lambda *args, **kwargs: (0, None))
        self.assertEqual(host, self.candidate / riot_runtime.HOST_PATH)
        self.assertTrue(riot_runtime.read_state(self.data)["pending"])
        self.assertEqual(riot_runtime.rollback(self.root, self.data), self.root / riot_runtime.HOST_PATH)
        state = riot_runtime.read_state(self.data)
        self.assertEqual(state["rejected_manifest"], "new")
        self.assertEqual(state["root"], str(self.root))

    def test_failed_candidate_preserves_current_runtime(self):
        original = {"root": str(self.root), "manifest": "old"}
        riot_runtime.write_state(self.data, original)
        with patch.object(riot_runtime, "official_manifest", return_value="new"), \
             patch.object(riot_runtime, "prepare_candidate", side_effect=RuntimeError("incompatible")):
            host = riot_runtime.ensure_runtime(self.root, self.data, lambda *args, **kwargs: (0, None))
        self.assertEqual(host, self.root / riot_runtime.HOST_PATH)
        self.assertEqual(riot_runtime.read_state(self.data), original)

    def test_interrupted_activation_rolls_back_before_retry(self):
        riot_runtime.write_state(self.data, {
            "root": str(self.candidate), "manifest": "new", "pending": True,
            "previous_root": str(self.root), "previous_manifest": "old",
        })
        with patch.object(riot_runtime, "official_manifest", return_value="new"), patch.object(riot_runtime, "prepare_candidate") as prepare:
            host = riot_runtime.ensure_runtime(self.root, self.data, lambda *args, **kwargs: (0, None))
        self.assertEqual(host, self.root / riot_runtime.HOST_PATH)
        prepare.assert_not_called()

    def test_incompatible_sdk_is_not_downloaded_on_every_launch(self):
        original = {"root": str(self.root), "manifest": "old"}
        riot_runtime.write_state(self.data, original)
        with patch.object(riot_runtime, "official_manifest", return_value="new"), \
             patch.object(riot_runtime, "prepare_candidate", side_effect=riot_runtime.IncompatibleRuntime("Unknown SDK")) as prepare:
            for _ in range(2):
                self.assertEqual(riot_runtime.ensure_runtime(self.root, self.data, None), self.root / riot_runtime.HOST_PATH)
        self.assertEqual(prepare.call_count, 1)
        state = riot_runtime.read_state(self.data)
        self.assertEqual(state["manifest"], "old")
        self.assertEqual(state["rejected_manifest"], "new")

    def test_running_game_prevents_shutdown(self):
        calls = []
        def api(method, route, **kwargs):
            calls.append(method)
            return 200, {"game": {"productId": "teamfighttactics"}}
        with self.assertRaises(RuntimeError):
            riot_runtime.quit_client(api, self.data / "lockfile")
        self.assertEqual(calls, ["GET"])

    def test_confirmation_completes_activation(self):
        riot_runtime.write_state(self.data, {"pending": True, "root": str(self.candidate), "previous_root": str(self.root)})
        riot_runtime.confirm(self.data)
        self.assertFalse(riot_runtime.read_state(self.data)["pending"])

    def test_validated_download_is_reused(self):
        manifest = "https://ks-foundation.secure.dyn.riotcdn.net/channels/public/releases/1234567890ABCDEF.manifest"
        candidate = self.data / "runtimes/1234567890ABCDEF"
        candidate.mkdir()
        (candidate / "sdk-ready.json").write_text(json.dumps({"manifest": manifest, "address": 512}))
        with patch.object(riot_runtime, "validate_candidate") as validate, \
             patch.object(riot_runtime, "refresh_host") as refresh, \
             patch.object(riot_runtime, "download_runtime") as download:
            self.assertEqual(riot_runtime.prepare_candidate(self.root, self.root, self.data, manifest, None), candidate)
        refresh.assert_called_once_with(self.root, candidate, self.data, None)
        validate.assert_called_once_with(candidate, 512)
        download.assert_not_called()

    def test_cleanup_keeps_current_and_fallback_and_retries_on_later_launches(self):
        previous = self.data / "runtimes/previous"
        bootstrap = self.data / "bootstrap"
        obsolete = self.data / "runtimes/obsolete"
        for directory in (self.candidate, previous, bootstrap, obsolete):
            host = directory / riot_runtime.HOST_PATH
            host.parent.mkdir(parents=True, exist_ok=True)
            host.write_bytes(b"host")
            marker = "bootstrap-ready.json" if directory == bootstrap else "sdk-ready.json"
            (directory / marker).write_text("{}")
        unrelated = self.data / "runtimes/unrelated"
        unrelated.mkdir()
        riot_runtime.write_state(self.data, {
            "root": str(self.candidate), "previous_root": str(previous), "pending": False,
        })
        riot_runtime.confirm(self.data)
        self.assertTrue(previous.exists())
        self.assertTrue(self.candidate.exists())
        self.assertTrue(unrelated.exists())
        self.assertFalse(bootstrap.exists())
        self.assertFalse(obsolete.exists())
        riot_runtime.confirm(self.data)

    def test_corrupt_cached_update_is_downloaded_again(self):
        manifest = "https://ks-foundation.secure.dyn.riotcdn.net/channels/public/releases/1234567890ABCDEF.manifest"
        candidate = self.data / "runtimes/1234567890ABCDEF"
        candidate.mkdir()
        (candidate / "sdk-ready.json").write_text("invalid JSON")
        with patch.object(riot_runtime, "download_runtime", side_effect=RuntimeError("fresh download")) as download:
            with self.assertRaisesRegex(RuntimeError, "fresh download"):
                riot_runtime.prepare_candidate(self.root, self.root, self.data, manifest, None)
        download.assert_called_once()
        self.assertFalse(candidate.exists())

    def test_cleanup_preserves_bootstrap_during_first_activation(self):
        bootstrap = self.data / "bootstrap"
        bootstrap.mkdir()
        (bootstrap / "bootstrap-ready.json").write_text("{}")
        riot_runtime.write_state(self.data, {
            "root": str(self.candidate), "previous_root": str(bootstrap), "pending": True,
        })
        riot_runtime.confirm(self.data)
        self.assertTrue(bootstrap.exists())

    def test_updates_use_persistent_configuration_after_bootstrap_cleanup(self):
        bootstrap = self.data / "bootstrap"
        self.assertFalse(bootstrap.exists())
        manifest = "https://ks-foundation.secure.dyn.riotcdn.net/channels/public/releases/1234567890ABCDEF.manifest"
        with patch.object(riot_runtime, "download_runtime", side_effect=RuntimeError("download probe")) as download:
            with self.assertRaisesRegex(RuntimeError, "download probe"):
                riot_runtime.prepare_candidate(bootstrap, self.candidate, self.data, manifest, None)
        self.assertEqual(download.call_args.args[0], self.data)


def synthetic_sdk(address=0x200, duplicate=False):
    data = bytearray(0x600)
    struct.pack_into("<8I", data, 0, 0xfeedfacf, 0x100000c, 0, 6, 1, 232, 0, 0)
    struct.pack_into("<II", data, 32, 0x19, 232)
    struct.pack_into("<I", data, 32 + 64, 2)
    for index, (name, offset, size) in enumerate([(b"__text", address, 24), (b"__cstring", 0x400, 0x100)]):
        position = 32 + 72 + index * 80
        data[position:position + len(name)] = name
        struct.pack_into("<QQI", data, position + 32, offset, size, offset)
    data[0x410:0x414] = b"mac\0"
    data[0x420:0x428] = b"windows\0"
    instructions = (0x90000000, 0x91000000 | (0x410 << 10), 0xd65f03c0)
    struct.pack_into("<III", data, address, *instructions)
    if duplicate:
        struct.pack_into("<III", data, address + 12, *instructions)
    return data


class SDKPatchTests(unittest.TestCase):
    def test_getter_is_located_after_relocation(self):
        with tempfile.TemporaryDirectory() as temporary:
            sdk = Path(temporary) / "SDK"
            for address in [0x200, 0x300]:
                sdk.write_bytes(synthetic_sdk(address))
                self.assertEqual(patch_windows_sdk(sdk), address)
                add = struct.unpack_from("<I", sdk.read_bytes(), address + 4)[0]
                self.assertEqual((add >> 10) & 4095, 0x420)

    def test_ambiguous_getter_is_rejected_without_modification(self):
        with tempfile.TemporaryDirectory() as temporary:
            sdk = Path(temporary) / "SDK"
            original = synthetic_sdk(duplicate=True)
            sdk.write_bytes(original)
            with self.assertRaises(RuntimeError):
                patch_windows_sdk(sdk)
            self.assertEqual(sdk.read_bytes(), original)


class GamePreparationTests(unittest.TestCase):
    def test_ready_state_requires_the_requested_release_server_and_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            data = Path(temporary)
            game = data / "Game.app"
            executable = game / "Contents/MacOS/TFTClient-Mac-Shipping"
            executable.parent.mkdir(parents=True)
            executable.touch()
            settings = {"region": "NA1"}
            expected = {"combined_patch_state": "up_to_date", "configuration": {"id": "NA1", "patch_url": "manifest"}}
            response = expected
            def api(method, route, body=None, **kwargs):
                if route == launcher.SESSIONS:
                    return 200, {}
                if route == launcher.PATCH_STATE:
                    return 200, response
                return 201, None
            with patch.object(launcher, "DATA", data), patch.object(launcher, "GAME", game), \
                 patch.object(launcher, "account_region", return_value=settings), \
                 patch.object(launcher, "update_game"), patch.object(launcher, "api", side_effect=api):
                self.assertFalse(launcher.prepare_game(data, settings, "manifest"))
                for response in ({}, {"combined_patch_state": "updating", "configuration": expected["configuration"]},
                                 {"combined_patch_state": "up_to_date", "configuration": {"id": "EUW1", "patch_url": "manifest"}},
                                 {"combined_patch_state": "up_to_date", "configuration": {"id": "NA1", "patch_url": "other"}}):
                    with self.assertRaisesRegex(RuntimeError, "requested live release and server"):
                        launcher.prepare_game(data, settings, "manifest")
                response = expected
                executable.unlink()
                with self.assertRaisesRegex(RuntimeError, "expected TFT Mac client"):
                    launcher.prepare_game(data, settings, "manifest")


class ManualLaunchTests(unittest.TestCase):
    def test_preparation_never_launches_the_game(self):
        with tempfile.TemporaryDirectory() as temporary:
            data = Path(temporary).resolve()
            (data / "user").mkdir()
            current = data / "runtimes/current"
            current.mkdir(parents=True)
            riot_runtime.write_state(data, {"root": str(current), "pending": False})
            host = data / "SDKHost"
            host.touch()
            game = data / "Game.app"
            (game / "Contents/MacOS").mkdir(parents=True)
            (game / "Contents/MacOS/TFTClient-Mac-Shipping").touch()

            def api(method, route, body=None, **kwargs):
                self.assertNotIn("product-launcher", route)
                if route == launcher.SESSIONS:
                    return 200, {}
                if route == launcher.PATCH_STATE:
                    return 200, {"combined_patch_state": "up_to_date", "configuration": {"id": "NA1", "patch_url": "manifest"}}
                return 201, None

            with patch.object(launcher, "DATA", data), \
                 patch.object(launcher, "GAME", game), patch.object(launcher, "api", side_effect=api), \
                 patch.object(launcher.riot_runtime, "ensure_runtime", return_value=host) as ensure, \
                 patch.object(launcher.riot_runtime, "confirm") as confirm, \
                 patch.object(launcher.launcher_config, "prepare_files"), \
                 patch.object(launcher.launcher_config, "configure_region", return_value=False), \
                 patch.object(launcher.riot_runtime, "wire_configuration"), \
                 patch.object(launcher.riot_runtime, "ensure_healthy", side_effect=lambda assets, current, *args: current), \
                 patch.object(launcher.riot_runtime, "quit_client"), \
                 patch.object(launcher.riot_runtime, "remove_install_watcher", return_value=False), \
                 patch.object(launcher.riot_runtime, "bootstrap_runtime", side_effect=AssertionError("Bootstrap must stay removed")), \
                 patch.object(launcher, "account_region", return_value={"region":"NA1", "version_set":"live-NA1"}), \
                 patch.object(launcher, "live_release", return_value=("manifest", "version")), \
                 patch.object(launcher, "connect_riot") as connect, patch.object(launcher, "update_game") as update, \
                 patch('sys.stdout', new_callable=io.StringIO) as output:
                update.side_effect = lambda target: confirm.assert_not_called()
                self.assertEqual(launcher.main(), 0)
                update.assert_called_once_with("manifest")
                self.assertEqual(connect.call_count, 2)
                self.assertEqual(output.getvalue().count("Sign in to Riot to prepare TFT live."), 1)
                confirm.assert_called_once()

                candidate = data / "runtimes/new"
                def activate(*args):
                    riot_runtime.write_state(data, {
                        "root": str(candidate), "manifest": "new", "pending": True,
                        "previous_root": str(current), "previous_manifest": "old",
                    })
                    return candidate / riot_runtime.HOST_PATH
                ensure.side_effect = activate
                confirm.reset_mock()
                def prepare(root, settings, target):
                    confirm.assert_not_called()
                    if root == candidate:
                        raise RuntimeError("TFT preparation failed")
                    self.assertEqual(root, current)
                    return False
                with patch.object(launcher, "prepare_game", side_effect=prepare) as preparation:
                    self.assertEqual(launcher.main(), 0)
                self.assertEqual(preparation.call_count, 2)
                self.assertEqual(riot_runtime.read_state(data)["root"], str(current))
                confirm.assert_called_once()

                confirm.reset_mock()
                with patch.object(launcher, "prepare_game", side_effect=RuntimeError("Both versions failed")):
                    with self.assertRaisesRegex(RuntimeError, "Both versions failed"):
                        launcher.main()
                confirm.assert_not_called()
                self.assertEqual(riot_runtime.read_state(data)["root"], str(current))


if __name__ == "__main__":
    unittest.main()
