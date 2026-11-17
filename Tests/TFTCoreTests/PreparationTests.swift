import Foundation
import Testing
@testable import TFTCore

final class PreparationTests: TemporaryTests {
    func fixture(patch: @escaping () -> JSON, messages: @escaping (String) -> Void = { _ in }) throws -> Launcher {
        let config = try Configuration(assets: repository.appendingPathComponent("Resources"), data: directory)
        try atomicJSON(["game_path": directory.appendingPathComponent("Game.app").path], to: directory.appendingPathComponent("install.json"))
        _ = try file("Game.app/Contents/MacOS/TFTClient-Mac-Shipping")
        let info: JSON = ["CFBundleName": "Teamfight Tactics", "CFBundleDisplayName": "Teamfight Tactics",
                          "CFBundleExecutable": "TFTClient-Mac-Shipping"]
        _ = try file("Game.app/Contents/Info.plist", PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0))
        _ = try file("user/Config/ClientConfiguration.json", jsonData(["public": [["updateTime": 1, "data": regionalConfiguration()]]]))
        let runtime = RiotRuntime(config, api: { method, route, _, _ in
            #expect(!route.contains("product-launcher"))
            switch route {
            case sessionRoute: return HTTPResult(200, [:])
            case "/rso-auth/v1/authorization/userinfo": return HTTPResult(200, ["userInfo": ["lol": ["cpid": "NA1"]]])
            case patchRoute: return HTTPResult(200, patch())
            default: return HTTPResult(201)
            }
        }, report: messages)
        return try Launcher(config, runtime: runtime)
    }
    func ready(_ region: String = "NA1", manifest: String = "manifest", state: String = "up_to_date") -> JSON {
        ["configuration": ["id": region, "patch_url": manifest], "combined_patch_state": state]
    }
    @Test func gameDisplayNamePreservesExecutableAndSkipsUnchangedMetadata() throws {
        let launcher = try fixture { self.ready() }
        let path = launcher.game.appendingPathComponent("Contents/Info.plist")
        let original: JSON = ["CFBundleName": "TFTClient-Mac-Shipping", "CFBundleExecutable": "TFTClient-Mac-Shipping",
                              "CFBundleIdentifier": "com.riotgames.league.teamfighttactics"]
        try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0).write(to: path)
        var validations = 0
        try launcher.updateGameDisplayName { _ in validations += 1 }
        let updated = try Data(contentsOf: path)
        let info = try #require(PropertyListSerialization.propertyList(from: updated, format: nil) as? JSON)
        #expect(text(info["CFBundleName"]) == "Teamfight Tactics")
        #expect(text(info["CFBundleDisplayName"]) == "Teamfight Tactics")
        #expect(text(info["CFBundleExecutable"]) == text(original["CFBundleExecutable"]))
        #expect(text(info["CFBundleIdentifier"]) == text(original["CFBundleIdentifier"]))
        try launcher.updateGameDisplayName { _ in validations += 1 }
        #expect(validations == 1)
        #expect(try Data(contentsOf: path) == updated)
    }
    @Test func protectedGameMetadataIsPreservedIfValidationFails() throws {
        let launcher = try fixture { self.ready() }
        let path = launcher.game.appendingPathComponent("Contents/Info.plist")
        let original = try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Publisher name"], format: .xml, options: 0)
        try original.write(to: path)
        #expect(throws: (any Error).self) {
            try launcher.updateGameDisplayName { _ in
                throw LauncherError("Protected metadata")
            }
        }
        #expect(try Data(contentsOf: path) == original)
    }
    @Test func completedPreparationRequiresMatchingRegionAndNativeExecutable() throws {
        let launcher = try fixture { self.ready() }
        let region = try regionSettings("NA1", configuration: regionalConfiguration())
        #expect(try !launcher.prepareGame(directory, region: region, release: Release(manifest: "manifest", version: "version")))
        try remove(launcher.game.appendingPathComponent("Contents/MacOS/TFTClient-Mac-Shipping"))
        #expect(throws: (any Error).self) { try launcher.prepareGame(directory, region: region, release: Release(manifest: "manifest", version: "version")) }
    }
    @Test func differentPatchRegionAndManifestFail() throws {
        let region = try regionSettings("NA1", configuration: regionalConfiguration())
        for patch in [ready("EUW1"), ready(manifest: "other")] {
            let launcher = try fixture { patch }
            #expect(throws: (any Error).self) { try launcher.prepareGame(directory, region: region, release: Release(manifest: "manifest", version: "version")) }
        }
    }
    @Test func missingAndPartialInstallationsRequestAnUpdate() throws {
        for initial in ["not_installed", "out_of_date"] {
            var iteration = 0
            let launcher = try fixture {
                iteration += 1
                return self.ready(state: iteration == 1 ? initial : "up_to_date")
            }
            try launcher.updateGame("manifest")
            #expect(iteration == 2)
        }
    }
    @Test func cancelledPatchFailsAndCanBeRetried() throws {
        var iteration = 0
        let launcher = try fixture {
            iteration += 1
            if iteration == 1 { return self.ready(state: "not_installed") }
            var state = self.ready(state: "updating")
            state["user_cancelled_patching"] = true
            return state
        }
        #expect(throws: (any Error).self) { try launcher.updateGame("manifest") }
    }
    @Test func progressDoesNotRepeatWhenPhasesReset() throws {
        var iteration = 0
        var messages: [String] = []
        let launcher = try fixture(patch: {
            defer { iteration += 1 }
            if iteration >= 3 { return self.ready() }
            var state = self.ready(state: "updating")
            state["patch_status"] = ["progress": ["phase": iteration, "progress": [50, 30, 80][iteration]]]
            return state
        }, messages: { messages.append($0) })
        try launcher.updateGame("manifest")
        #expect(messages == ["  50 %", "  80 %"])
    }
    @Test func runningGameDetectionIgnoresRiotClientSessions() {
        #expect(!gameIsRunning(["client": ["productId": "riot_client"]]))
        #expect(gameIsRunning(["game": ["productId": "teamfighttactics"]]))
    }
}
