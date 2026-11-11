import Foundation
import Darwin

private struct IncompatibleRuntime: Error, LocalizedError {
    let cause: Error
    var errorDescription: String? { cause.localizedDescription }
}

extension RiotRuntime {
    public func officialConfiguration(_ current: URL) throws -> JSON {
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: current.appendingPathComponent(riotAppName + "/Contents/Info.plist")), format: nil) as? JSON ?? [:]
        var version = text(info["FileVersion"])
        let cached = data.appendingPathComponent("user/Config/ClientConfiguration.json")
        if exists(cached) {
            let entries = objects(try readJSON(cached)["public"]).filter { text(object($0["params"])["patchline"]) == "KeystoneFoundationLiveMac" }
            if let latest = entries.max(by: { number($0["updateTime"]) < number($1["updateTime"]) }),
               let value = object(latest["params"])["version"] as? String { version = value }
        }
        let region = (try? readText(data.appendingPathComponent("riot-region.txt")).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "NA"
        var url = URLComponents(string: "https://clientconfig.rpg.riotgames.com/api/v1/config/public")!
        url.queryItems = [URLQueryItem(name: "app", value: "Riot Client"), URLQueryItem(name: "patchline", value: "KeystoneFoundationLiveMac"),
                          URLQueryItem(name: "version", value: version), URLQueryItem(name: "region", value: region)]
        return try fetch(url.url!)
    }
    public func officialManifest(_ current: URL) throws -> String {
        let manifest = text(try officialConfiguration(current)["keystone.self_update.manifest_url"])
        try require(matches(manifest, "https://ks-foundation\\.secure\\.dyn\\.riotcdn\\.net/channels/public/releases/[A-Fa-f0-9]{16}\\.manifest"), "The Riot update manifest is invalid.")
        return manifest
    }
    public func downloadRuntime(current: URL, stage: URL, manifest: String) throws -> URL {
        let host = stage.appendingPathComponent(hostRelativePath)
        try clone(current.appendingPathComponent(hostRelativePath), host)
        let contents = host.deletingLastPathComponent().deletingLastPathComponent()
        try clone(current.appendingPathComponent("TFT SDK Host arm64.app/Contents/Info.plist"), contents.appendingPathComponent("Info.plist"))
        try makeDirectory(contents.appendingPathComponent("Frameworks"))
        try FileManager.default.createSymbolicLink(at: contents.appendingPathComponent("Frameworks/Riot Client.app"), withDestinationURL: current.appendingPathComponent("TFT SDK Host arm64.app/Contents/Frameworks/Riot Client.app"))
        for name in [riotAppName, "sdk-windows-override-arm64"] {
            try FileManager.default.createSymbolicLink(at: stage.appendingPathComponent(name), withDestinationURL: current.appendingPathComponent(name))
        }
        try clone(data.appendingPathComponent("sdk-host-system.yaml"), stage.appendingPathComponent("sdk-host-system.yaml"))
        if exists(data.appendingPathComponent("riot-region.txt")) { try clone(data.appendingPathComponent("riot-region.txt"), stage.appendingPathComponent("riot-region.txt")) }
        var config = try readJSON(data.appendingPathComponent("riot-sdk-host-override.json"))
        var publicConfig = object(config["public"])
        var product = object(publicConfig[liveProduct])
        var metadata = object(product["metadata"])
        for key in metadata.keys { var entry = object(metadata[key]); entry.removeValue(forKey: "product_dependency"); metadata[key] = entry }
        product["metadata"] = metadata
        var platforms = object(product["platforms"])
        for key in platforms.keys {
            var platform = object(platforms[key])
            platform["auto_patch"] = false
            platform["install_dir"] = "Riot Download.app"
            platform["configurations"] = objects(platform["configurations"]).map { entry -> JSON in
                var entry = entry
                entry["patch_url"] = manifest
                entry["dependencies"] = [Any]()
                entry["excluded_paths"] = [Any]()
                return entry
            }
            platforms[key] = platform
        }
        product["platforms"] = platforms
        publicConfig["keystone.products.teamfighttactics.patchlines.runtime"] = product
        config["public"] = publicConfig
        try atomicJSON(config, to: stage.appendingPathComponent("riot-sdk-host-override.json"))
        let localData = stage.appendingPathComponent("sdk-host-data")
        try makeDirectory(localData)
        let lock = localData.appendingPathComponent("user/Config/lockfile")
        let destination = stage.appendingPathComponent("Riot Download.app")
        let process = try spawn(host, arguments: ["--headless"])
        defer {
            try? quit(lock)
            if process.isRunning { process.terminate() }
            let deadline = monotonic() + 10
            while process.isRunning && monotonic() < deadline { pause(0.1) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        var deadline = monotonic() + 60
        while api("GET", "/product-session/v1/sessions", nil, lock).status != 200 {
            try require(process.isRunning && monotonic() < deadline, "The isolated Riot patcher failed to start.")
            pause(0.5)
        }
        let registry = "/rnet-product-registry/v4/"
        deadline = monotonic() + 60
        var status: Int
        repeat {
            status = api("PUT", registry + "products/teamfighttactics/patchlines/runtime/install-path", ["root_path": stage.path, "full_path": destination.path], lock).status
            if status != 404 || monotonic() >= deadline || !process.isRunning { break }
            pause(0.5)
        } while true
        try require([200, 201, 204].contains(status), "The Riot patcher refused the staging directory (HTTP \(status)).")
        let request = api("PUT", registry + "patch-requests/products/teamfighttactics/patchlines/runtime", [:], lock)
        status = request.status
        try require([200, 201, 204].contains(status), "The Riot patcher refused the runtime download (HTTP \(status)). " + String(text(request.json["message"]).prefix(300)))
        deadline = monotonic() + 1800
        var lastProgress = -1
        while monotonic() < deadline {
            let state = api("GET", registry + "patch-states/products/teamfighttactics/patchlines/runtime", nil, lock)
            if state.status == 200 {
                if text(state.json["combined_patch_state"]) == "up_to_date" { return destination }
                let patch = object(state.json["patch_status"])
                try require(patch["error"] == nil || patch["error"] is NSNull, "The Riot runtime download failed.")
                let progress = Int(number(object(patch["progress"])["progress"])) / 10 * 10
                if progress > lastProgress { report("Updating Riot components, \(progress) %"); lastProgress = progress }
            }
            try require(process.isRunning, "The Riot patcher stopped during the download.")
            pause(1)
        }
        throw LauncherError("The Riot runtime download timed out.")
    }
    public func prepareCandidate(current: URL, manifest: String) throws -> URL {
        let releases = data.appendingPathComponent("runtimes")
        try makeDirectory(releases)
        let identifier = URL(string: manifest)!.deletingPathExtension().lastPathComponent
        try require(matches(identifier, "[A-Fa-f0-9]{16}"), "The Riot update identifier is invalid.")
        let candidate = releases.appendingPathComponent(identifier)
        if let ready = try? RuntimeMetadata.read(from: candidate), ready.manifest == manifest {
            do { try refreshHost(candidate); try validate(candidate, address: ready.address); return candidate } catch { }
        }
        try require(resolved(candidate) != resolved(current), "The active Riot runtime cannot be replaced while preparing an update.")
        try remove(candidate)
        let stage = data.appendingPathComponent("runtime-stage-" + UUID().uuidString)
        try makeDirectory(stage)
        defer { try? remove(stage) }
        let downloaded = try downloadRuntime(current: current, stage: stage, manifest: manifest)
        let prepared = stage.appendingPathComponent("prepared")
        do { _ = try prepareRuntime(into: prepared, source: downloaded) }
        catch { throw IncompatibleRuntime(cause: error) }
        let address = try RuntimeMetadata.read(from: prepared).address
        try RuntimeMetadata(address: address, manifest: manifest).write(to: prepared)
        try move(prepared, candidate)
        return candidate
    }
    public func ensureRuntime() throws -> URL {
        var state = try state()
        if state["pending"] as? Bool == true { _ = try rollback(); state = try self.state() }
        let current = try selectedRoot(state)
        var manifest = ""
        do {
            manifest = try officialManifest(current)
            if text(state["manifest"]) == manifest { return current }
            if text(state["rejected_manifest"]) == manifest && Date().timeIntervalSince1970 - number(state["rejected_at"]) < 86400 {
                report("Keeping the previous compatible Riot components.")
                return current
            }
            let candidate = try prepareCandidate(current: current, manifest: manifest)
            try quit()
            try writeState(["root": candidate.path, "manifest": manifest, "pending": true,
                            "previous_root": current.path, "previous_manifest": state["manifest"] ?? NSNull()])
            report("New Riot components prepared and validated for ARM64.")
            return candidate
        } catch {
            // Retain the selected runtime when an update cannot be prepared.
            if error is IncompatibleRuntime && !manifest.isEmpty {
                state["rejected_manifest"] = manifest
                state["rejected_at"] = Date().timeIntervalSince1970
                try writeState(state)
            }
            report("Riot update deferred. Keeping the compatible version. " + error.localizedDescription)
            return current
        }
    }
}
