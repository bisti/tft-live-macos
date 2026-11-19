import Foundation
import Testing
@testable import TFTCore

final class MigrationTests: TemporaryTests {
    private let overrideName = "riot-sdk-host-override.json"
    private let systemName = "sdk-host-system.yaml"
    private let riot = """
        ---
        enable_self_update: true # managed by Riot
        default_region: NA
        publisher: riot
        launch_ux: false

        """

    private func template(version: Int, configuration: JSON = [:]) -> JSON {
        let details: JSON = ["id": "default", "patch_url": "", "bundles_url": "v\(version)"]
        let platform: JSON = ["configurations": [details.merging(configuration) { _, value in value }],
                              "deprecated_cloudfront_id": "v\(version)", "install_dir": "Teamfight Tactics (Live).app"]
        return ["public": [liveProduct: ["platforms": ["mac": platform, "win": platform, "windows": platform]],
                           "untouched_default": version, "removed_by_user": version], "player": [:]]
    }

    private func setup() throws -> Configuration {
        let asset = try file("assets/" + overrideName, jsonData(template(version: 1)))
        return try Configuration(assets: asset.deletingLastPathComponent(), data: directory.appendingPathComponent("profile"))
    }

    private func selectedDetails(_ override: JSON, platform: String) -> JSON {
        let platforms = object(object(object(override["public"])[liveProduct])["platforms"])
        return objects(object(platforms[platform])["configurations"])[0]
    }

    @Test func profileWithoutTemplatesRetainsItsRegionAndGainsDefaults() throws {
        let config = try setup()
        let details: JSON = ["id": "EUW1", "patch_url": "europe.manifest", "region_data": ["default_region": "EUW1"], "custom": true]
        let platform: JSON = ["configurations": [details], "install_dir": "Teamfight Tactics (Live).app"]
        let existing: JSON = ["public": [liveProduct: ["platforms": ["mac": platform, "win": platform, "windows": platform]]],
                              "player": ["custom": "player setting"]]
        let override = try file("profile/" + overrideName, jsonData(existing))
        let system = try file("profile/" + systemName, Data("default_region: EUW\nenable_self_update: false\n".utf8))
        let regionFile = try file("profile/riot-region.txt", Data("EUW\n".utf8))
        var notifications = 0

        #expect(try config.prepareFiles(riotSystem: { riot }, beforeChangingFiles: { notifications += 1 }))
        let configured = try readJSON(override)
        for platform in ["mac", "win", "windows"] {
            let selected = selectedDetails(configured, platform: platform)
            #expect(selected["id"] as? String == "EUW1")
            #expect(selected["patch_url"] as? String == "europe.manifest")
            #expect(object(selected["region_data"])["default_region"] as? String == "EUW1")
            #expect(selected["custom"] as? Bool == true)
            #expect(selected["bundles_url"] as? String == "v1")
        }
        #expect(object(configured["player"])["custom"] as? String == "player setting")
        #expect(try readText(system) == "default_region: EUW\nenable_self_update: false\n")
        #expect(try readText(regionFile) == "EUW\n")
        let migrated = try Data(contentsOf: override)
        #expect(try !config.prepareFiles(riotSystem: { riot }, beforeChangingFiles: { notifications += 1 }))
        #expect(try Data(contentsOf: override) == migrated)
        #expect(notifications == 1)
    }

    @Test func evolvingTemplatesUpdateDefaultsWhileKeepingLocalEdits() throws {
        let config = try setup()
        #expect(try config.prepareFiles(riotSystem: { riot }))
        let override = config.data.appendingPathComponent(overrideName)
        var local = template(version: 1, configuration: ["id": "EUW1", "patch_url": "local", "extra": "custom"])
        var settings = object(local["public"])
        settings.removeValue(forKey: "removed_by_user")
        local["public"] = settings
        try atomicJSON(local, to: override)
        let system = config.data.appendingPathComponent(systemName)
        try writeText(try readText(system).replacingOccurrences(of: "default_region: NA", with: "default_region: EUW"), to: system)
        try atomicJSON(template(version: 2), to: config.assets.appendingPathComponent(overrideName))
        let updated = riot.replacingOccurrences(of: "launch_ux: false", with: "launch_ux: true")

        #expect(try config.prepareFiles(riotSystem: { updated }))
        let configured = try readJSON(override)
        let selection = selectedDetails(configured, platform: "mac")
        #expect(selection["id"] as? String == "EUW1")
        #expect(selection["patch_url"] as? String == "local")
        #expect(selection["extra"] as? String == "custom")
        #expect(selection["bundles_url"] as? String == "v2")
        #expect(object(configured["public"])["untouched_default"] as? Int == 2)
        #expect(object(configured["public"])["removed_by_user"] == nil)
        #expect(try readText(system).contains("default_region: EUW"))
        #expect(try readText(system).contains("launch_ux: true"))
        #expect(try readText(system).contains("enable_self_update: false # managed by Riot"))
        #expect(try !config.prepareFiles(riotSystem: { updated }))
    }

    @Test func existingSystemWorksWithoutOfficialRiotAndConflictsPreserveTheLocalFile() throws {
        let config = try setup()
        _ = try config.prepareFiles(riotSystem: { riot })
        let system = config.data.appendingPathComponent(systemName)
        let legacy = try readText(system).replacingOccurrences(of: "default_region: NA", with: "default_region: EUW")
        try writeText(legacy, to: system)
        #expect(try !config.prepareFiles(riotSystem: { throw LauncherError("missing official client") }))
        let conflict = riot.replacingOccurrences(of: "default_region: NA", with: "default_region: JP")
        var report = ""
        #expect(try !config.prepareFiles(riotSystem: { conflict }, report: { report = $0 }))
        #expect(try readText(system) == legacy)
        #expect(report.contains(system.path))
        try writeText(legacy.replacingOccurrences(of: "default_region: EUW", with: "default_region: NA"), to: system)
        #expect(try config.prepareFiles(riotSystem: { conflict }))
        #expect(try readText(system).contains("default_region: JP"))
    }

    @Test func quotedSettingAndImplicitDocumentBoundary() throws {
        let config = try setup()
        #expect(try config.prepareFiles(riotSystem: { "\"enable_self_update\": true\n" }))
        let file = config.data.appendingPathComponent(systemName)
        #expect(try readText(file) == "\"enable_self_update\": false\n")
        #expect(throws: LauncherError.self) {
            try config.prepareFiles(riotSystem: { "first: document\n---\nenable_self_update: true\n" })
        }
        #expect(try readText(file) == "\"enable_self_update\": false\n")
    }

    @Test func invalidFilesAndCallbackFailureLeaveProfilesIntact() throws {
        let config = try setup()
        let invalid = try file("profile/" + overrideName, Data("{invalid".utf8))
        #expect(throws: LauncherError.self) { try config.prepareFiles(riotSystem: { riot }) }
        #expect(try readText(invalid) == "{invalid")
        try remove(invalid)
        let ambiguous = "enable_self_update: true\n\"enable_self_update\": false\n"
        let system = try file("profile/" + systemName, Data(ambiguous.utf8))
        #expect(throws: LauncherError.self) { try config.prepareFiles(riotSystem: { riot }) }
        #expect(try readText(system) == ambiguous)
        try remove(system)
        #expect(throws: LauncherError.self) {
            try config.prepareFiles(riotSystem: { riot }, beforeChangingFiles: { throw LauncherError("active host") })
        }
        #expect(!exists(invalid))
        #expect(!exists(system))
    }
}
