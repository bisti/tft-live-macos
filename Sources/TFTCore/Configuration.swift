import Foundation
import Darwin

public let liveProduct = "keystone.products.teamfighttactics.patchlines.live"
public let hostRelativePath = "TFT SDK Host arm64.app/Contents/MacOS/SDKHost"
public let riotAppName = "Riot Runtime.app"

public struct Region: Equatable {
    public let id: String
    public let versionSet: String
    public let clientRegion: String
    public let aliases: [String]
    public var json: JSON { ["region": id, "version_set": versionSet, "client_region": clientRegion, "aliases": aliases] }
}

public struct Configuration {
    public let assets: URL
    public let data: URL
    public init(assets: URL, data: URL? = nil) throws {
        self.assets = assets.standardizedFileURL
        if let data { self.data = data.standardizedFileURL; return }
        if let override = ProcessInfo.processInfo.environment["TFT_LIVE_DATA_DIR"] {
            let expanded = (override as NSString).expandingTildeInPath
            try require(expanded.hasPrefix("/"), "The data directory must be an absolute path.")
            self.data = URL(fileURLWithPath: expanded)
        } else {
            self.data = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TFT Live")
        }
    }
    public var lockfile: URL { data.appendingPathComponent("user/Config/lockfile") }
    public var initialRuntime: URL { data.appendingPathComponent("seed") }
    public var hostSource: URL { assets.appendingPathComponent("SDKHost") }
    public func installedRiot() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = [URL(fileURLWithPath: "/Users/Shared/Riot Games/Riot Client.app"),
                     URL(fileURLWithPath: "/Applications/Riot Client.app"), home.appendingPathComponent("Applications/Riot Client.app")]
        if let found = paths.first(where: { exists($0.appendingPathComponent("Contents/Frameworks/RiotGamesApi.framework/RiotGamesApi")) }) { return found }
        if let result = try? command(["/usr/bin/mdfind", "kMDItemCFBundleIdentifier == 'com.riotgames.RiotGames.RiotClient'"], timeout: 5) {
            paths += result.output.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        }
        guard let found = paths.first(where: { exists($0.appendingPathComponent("Contents/Frameworks/RiotGamesApi.framework/RiotGamesApi")) }) else {
            throw LauncherError("Install the official Riot Client on this Mac, then open TFT Live.")
        }
        return found
    }
    public func prepareFiles() throws {
        try makeDirectory(data)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path)
        let override = data.appendingPathComponent("riot-sdk-host-override.json")
        if !exists(override) {
            try FileManager.default.copyItem(at: assets.appendingPathComponent(override.lastPathComponent), to: override)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: override.path)
        }
        let system = data.appendingPathComponent("sdk-host-system.yaml")
        if !exists(system) {
            let original = try readText(installedRiot().appendingPathComponent("Contents/Resources/system.yaml"))
            var managed = original.replacingOccurrences(of: "(?m)^enable_self_update:.*$", with: "enable_self_update: false", options: .regularExpression)
            if managed == original && !original.contains("enable_self_update: false") { managed += "\nenable_self_update: false\n" }
            try writeText(managed, to: system)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: system.path)
        }
    }
    public func gamePath() throws -> URL {
        let saved = data.appendingPathComponent("install.json")
        if exists(saved) {
            let path = text(try readJSON(saved)["game_path"])
            try require(path.hasPrefix("/"), "The saved TFT installation directory is invalid.")
            return URL(fileURLWithPath: path)
        }
        let candidates = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Teamfight Tactics (Live).app"),
                          URL(fileURLWithPath: "/Applications/Teamfight Tactics (Live).app")]
        return candidates.first { exists($0.appendingPathComponent("Contents/MacOS/TFTClient-Mac-Shipping")) && access($0.path, W_OK) == 0 } ?? candidates[0]
    }
    public func cachedConfiguration() throws -> JSON? {
        let path = data.appendingPathComponent("user/Config/ClientConfiguration.json")
        if !exists(path) { return nil }
        let entries = objects(try readJSON(path)["public"]).filter {
            let value = object($0["data"])
            return value[liveProduct] != nil && value["tft.client_settings.version_sets"] != nil
        }
        return entries.max { number($0["updateTime"]) < number($1["updateTime"]) }.map { object($0["data"]) }
    }
    @discardableResult public func configureRegion(_ region: Region, manifest: String, version: String) throws -> Bool {
        let path = data.appendingPathComponent("riot-sdk-host-override.json")
        let original = try readJSON(path)
        var updated = original
        var publicConfig = object(updated["public"])
        var product = object(publicConfig[liveProduct])
        var metadata = object(product["metadata"])
        metadata.removeValue(forKey: "mac")
        for key in metadata.keys {
            var entry = object(metadata[key])
            entry.removeValue(forKey: "product_dependency")
            if entry["available_platforms"] != nil { entry["available_platforms"] = ["mac", "win", "windows"] }
            metadata[key] = entry
        }
        product["metadata"] = metadata
        var platform = object(object(product["platforms"])["mac"])
        guard var entry = objects(platform["configurations"]).first else { throw LauncherError("The TFT platform template is missing.") }
        entry["id"] = region.id
        entry["patch_url"] = manifest
        entry["dependencies"] = [Any]()
        entry["region_data"] = ["available_regions": region.aliases, "default_region": region.id]
        platform["auto_patch"] = false
        platform["install_dir"] = "Teamfight Tactics (Live).app"
        platform["dependencies"] = [Any]()
        platform["configurations"] = [entry]
        product["platforms"] = ["mac": platform, "win": platform, "windows": platform]
        publicConfig[liveProduct] = product
        updated["public"] = publicConfig
        let regionFile = data.appendingPathComponent("riot-region.txt")
        let changed = try jsonData(original) != jsonData(updated) || (try? readText(regionFile).trimmingCharacters(in: .whitespacesAndNewlines)) != region.clientRegion
        if try jsonData(original) != jsonData(updated) { try atomicJSON(updated, to: path) }
        try writeText(region.clientRegion + "\n", to: regionFile)
        var selection = region.json
        selection["manifest"] = manifest
        selection["version"] = version
        try atomicJSON(selection, to: data.appendingPathComponent("selection.json"))
        return changed
    }
}

public func decodeUserRegion(_ value: Any?) throws -> String {
    var user = object(value)
    if let encoded = value as? String, let data = encoded.data(using: .utf8) { user = object(try JSONSerialization.jsonObject(with: data)) }
    var region = text(object(user["lol"])["cpid"])
    if region.isEmpty {
        let active = Set(objects(user["lol_region"]).filter { $0["active"] as? Bool == true }.compactMap { $0["cpid"] as? String })
        if active.count == 1 { region = active.first! }
    }
    try require(matches(region, "[A-Z0-9]{2,8}"), "The account TFT region is unavailable.")
    return region
}

public func regionSettings(_ requested: String, configuration: JSON) throws -> Region {
    let product = object(configuration[liveProduct])
    let configs = objects(object(object(product["platforms"])["win"])["configurations"])
    let selected = configs.filter { text($0["id"]) == requested || (object($0["region_data"])["available_regions"] as? [String] ?? []).contains(requested) }
    try require(selected.count == 1, "Riot configuration for region " + requested + " is unavailable.")
    let region = text(selected[0]["id"])
    let versionSet = text(object(configuration["tft.client_settings.version_sets"])[region])
    try require(matches(versionSet, "live-[A-Z0-9]+"), "Riot does not offer a TFT live channel for region " + region + ".")
    let aliases = object(selected[0]["region_data"])["available_regions"] as? [String] ?? [region]
    return Region(id: region, versionSet: versionSet, clientRegion: aliases.first ?? region, aliases: aliases.isEmpty ? [region] : aliases)
}
