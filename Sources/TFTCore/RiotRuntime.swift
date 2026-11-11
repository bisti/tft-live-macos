import Foundation
import CryptoKit
import Darwin

private struct IncompatibleRuntime: Error, LocalizedError {
    let cause: Error
    var errorDescription: String? { cause.localizedDescription }
}

public final class RiotRuntime {
    public let configuration: Configuration
    public let api: LocalAPI
    public let fetch: (URL) throws -> JSON
    public let report: (String) -> Void
    private var children: [Int32: Process] = [:]
    public init(_ configuration: Configuration, api: LocalAPI? = nil, fetch: ((URL) throws -> JSON)? = nil,
                report: @escaping (String) -> Void = { print($0); fflush(stdout) }) {
        self.configuration = configuration
        let http = HTTPClient()
        self.api = api ?? http.local
        self.fetch = fetch ?? http.json
        self.report = report
    }
    public var data: URL { configuration.data }
    public func state() throws -> JSON {
        let file = data.appendingPathComponent("runtime-current.json")
        return exists(file) ? try readJSON(file) : [:]
    }
    public func writeState(_ value: JSON) throws { try atomicJSON(value, to: data.appendingPathComponent("runtime-current.json")) }
    public func selectedRoot(_ state: JSON) throws -> URL {
        let root = resolved(URL(fileURLWithPath: text(state["root"]).isEmpty ? configuration.bootstrap.path : text(state["root"])))
        try require(root == resolved(configuration.bootstrap) || isInside(root, data.appendingPathComponent("runtimes")), "The Riot runtime directory is invalid.")
        return root
    }
    @discardableResult public func spawn(_ host: URL, arguments: [String] = []) throws -> Process {
        let process = Process()
        process.executableURL = host
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        children[process.processIdentifier] = process
        return process
    }
    public func quit(_ lock: URL? = nil) throws {
        let lock = lock ?? configuration.lockfile
        let sessions = api("GET", "/product-session/v1/sessions", nil, lock)
        if sessions.status != 200 { return }
        try require(!sessions.json.values.contains { let product = object($0)["productId"] as? String; return product != nil && product != "riot_client" },
                    "A game is running. The Riot update will be applied after it closes.")
        let fields = (try? readText(lock).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ":")) ?? []
        let pid = fields.count > 1 ? Int32(fields[1]) : nil
        _ = api("POST", "/process-control/v1/process/quit", nil, lock)
        let deadline = monotonic() + 30
        while true {
            var running = api("GET", "/product-session/v1/sessions", nil, lock).status == 200
            if let pid, pid > 0 {
                if let child = children[pid] { running = running || child.isRunning }
                else { running = running || kill(pid, 0) == 0 }
            }
            if !running { break }
            try require(monotonic() < deadline, "Riot Client must close to apply its update.")
            pause(0.5)
        }
        pause(1)
    }
    public func rollback() throws -> URL? {
        let old = try state()
        if old["pending"] as? Bool != true { return nil }
        guard let previous = old["previous_root"] as? String, let manifest = old["manifest"] as? String else {
            throw LauncherError("The previous Riot runtime is unavailable.")
        }
        var restored: JSON = ["root": previous, "rejected_manifest": manifest, "rejected_at": Date().timeIntervalSince1970]
        restored["manifest"] = old["previous_manifest"] ?? NSNull()
        let root = try selectedRoot(restored)
        try writeState(restored)
        return root
    }
    public func confirm() throws {
        var state = try state()
        if state["pending"] as? Bool == true { state["pending"] = false; try writeState(state) }
        if text(state["root"]).isEmpty { return }
        let keep = Set(["root", "previous_root"].compactMap { state[$0] as? String }.map { resolved(URL(fileURLWithPath: $0)) })
        var candidates = (try? FileManager.default.contentsOfDirectory(at: data.appendingPathComponent("runtimes"), includingPropertiesForKeys: nil)) ?? []
        if keep.count == 2 && keep.allSatisfy({ exists($0.appendingPathComponent(hostRelativePath)) }) { candidates.append(configuration.bootstrap) }
        for candidate in candidates where !isSymlink(candidate) && !keep.contains(resolved(candidate)) {
            if exists(candidate.appendingPathComponent("sdk-ready.json")) || exists(candidate.appendingPathComponent("bootstrap-ready.json")) { try remove(candidate) }
        }
    }
    public func finishSetup(_ candidate: URL, prepare: (URL) throws -> Bool, restore: (URL) throws -> URL) throws -> Bool {
        let running: Bool
        do { running = try prepare(candidate) }
        catch {
            if try state()["pending"] as? Bool != true { throw error }
            try quit()
            guard let previous = try rollback() else { throw error }
            let restored = try restore(previous)
            report("Automatically restored the previous Riot components. " + error.localizedDescription)
            running = try prepare(restored)
        }
        try confirm()
        return running
    }
    public func wire(_ directory: URL) throws {
        let targets = ["sdk-host-data": data, "sdk-host-system.yaml": data.appendingPathComponent("sdk-host-system.yaml"),
                       "riot-sdk-host-override.json": data.appendingPathComponent("riot-sdk-host-override.json"), "riot-region.txt": data.appendingPathComponent("riot-region.txt")]
        for (name, target) in targets {
            let path = directory.appendingPathComponent(name)
            if isSymlink(path) && resolved(path) != resolved(target) { try remove(path) }
            if !exists(path) && !isSymlink(path) { try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target) }
        }
    }
    public func removeInstallWatcher() throws -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.riot.riotclient.checkinstalls.plist")
        guard exists(path), let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil) as? JSON,
              let executable = (plist["ProgramArguments"] as? [String])?.first else { return false }
        let target = URL(fileURLWithPath: executable)
        guard isInside(target, data), target.path.hasSuffix("/" + hostRelativePath) else { return false }
        let service = "gui/\(getuid())/com.riot.riotclient.checkinstalls"
        try command(["/bin/launchctl", "bootout", service], checked: false)
        try require(try command(["/bin/launchctl", "print", service], checked: false).status != 0, "Unable to stop the legacy TFT installation watcher. Reopen TFT Live to retry.")
        try remove(path)
        return true
    }
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
    func copySharedTree(_ source: URL, _ destination: URL) throws {
        let canonicalSource = resolved(source)
        try makeDirectory(destination)
        for path in files(canonicalSource) {
            let relative = String(path.path.dropFirst(canonicalSource.path.count + 1))
            let target = destination.appendingPathComponent(relative)
            if isSymlink(path) {
                try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: FileManager.default.destinationOfSymbolicLink(atPath: path.path))
            } else if (try path.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                try makeDirectory(target)
            } else {
                do { try FileManager.default.linkItem(at: path, to: target) }
                catch { try clone(path, target) }
            }
        }
    }
    public func shareInterface(_ root: URL) throws {
        let host = root.appendingPathComponent("TFT SDK Host arm64.app")
        let ui = host.appendingPathComponent("Contents/Frameworks/Riot Client.app")
        let staged = URL(fileURLWithPath: ui.path + ".new")
        let backup = root.appendingPathComponent("riot-interface.previous")
        try makeDirectory(ui.deletingLastPathComponent())
        if !exists(ui) && exists(backup) { try move(backup, ui) }
        try remove(staged)
        try copySharedTree(root.appendingPathComponent(riotAppName + "/Contents/Frameworks/Riot Client.app"), staged)
        try remove(backup)
        if exists(ui) { try move(ui, backup) }
        try move(staged, ui)
        do { try sign(host, deep: false); try verify(host) }
        catch {
            try remove(ui)
            if exists(backup) { try move(backup, ui) }
            throw error
        }
        try remove(backup)
    }
    private func makeHost(_ root: URL) throws {
        let host = root.appendingPathComponent(hostRelativePath)
        try makeDirectory(host.deletingLastPathComponent())
        try clone(configuration.hostSource, host)
        let info: JSON = ["CFBundleExecutable": "SDKHost", "CFBundleIdentifier": "local.tft.live.sdk-host", "CFBundleName": "TFT SDK Host",
                          "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "LSArchitecturePriority": ["arm64"],
                          "LSRequiresNativeExecution": true, "LSMinimumSystemVersion": "14.0"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try atomicWrite(plist, to: host.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist"))
        try shareInterface(root)
    }
    public func refreshHost(_ current: URL) throws {
        let source = try fileDigest(configuration.hostSource)
        let host = current.appendingPathComponent(hostRelativePath)
        let marker = current.appendingPathComponent("host-source.json")
        let installed = try exists(host) ? fileDigest(host) : ""
        let record = (try? readJSON(marker)) ?? [:]
        if text(record["source"]) == source && text(record["installed"]) == installed && record["layout"] as? Int == 4 { return }
        try quit()
        let legacy = current.appendingPathComponent("Riot Windows Auth Test.app")
        if exists(legacy) && !exists(current.appendingPathComponent(riotAppName)) { try move(legacy, current.appendingPathComponent(riotAppName)) }
        let temporary = URL(fileURLWithPath: host.path + ".new")
        try makeDirectory(host.deletingLastPathComponent())
        try remove(temporary)
        try clone(configuration.hostSource, temporary)
        guard rename(temporary.path, host.path) == 0 else { throw LauncherError("Unable to install the updated Swift host.") }
        try shareInterface(current)
        try atomicJSON(["source": source, "installed": fileDigest(host), "layout": 4], to: marker)
    }
    public func fingerprint(_ root: URL) throws -> String {
        let canonicalRoot = resolved(root)
        var digest = SHA256()
        for name in [riotAppName, "sdk-windows-override-arm64/RiotGamesApi.framework", "TFT SDK Host arm64.app"] {
            let bundle = canonicalRoot.appendingPathComponent(name)
            for path in [bundle] + files(bundle).sorted(by: { $0.path < $1.path }) {
                var info = stat()
                try require(lstat(path.path, &info) == 0, "A Riot component is missing.")
                var entry = "\(path.path.dropFirst(canonicalRoot.path.count))\u{0}\(info.st_mode) \(info.st_size) \(info.st_mtimespec.tv_sec) \(info.st_mtimespec.tv_nsec) \(info.st_ctimespec.tv_sec) \(info.st_ctimespec.tv_nsec)"
                if isSymlink(path) { entry += try FileManager.default.destinationOfSymbolicLink(atPath: path.path) }
                digest.update(data: Data(entry.utf8))
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public func validate(_ root: URL, address: UInt64) throws {
        let binary = root.appendingPathComponent("sdk-windows-override-arm64/RiotGamesApi.framework/RiotGamesApi")
        let size = (try FileManager.default.attributesOfItem(atPath: binary.path)[.size] as? NSNumber)?.uint64Value ?? 0
        try require(address < size, "The SDK validation address is out of range.")
        for name in [riotAppName, "sdk-windows-override-arm64/RiotGamesApi.framework", "TFT SDK Host arm64.app"] { try verify(root.appendingPathComponent(name)) }
        let result = try command([root.appendingPathComponent(hostRelativePath).path, "--check-sdk", String(address, radix: 16)], timeout: 30)
        try require(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "windows", "Windows validation of the new SDK failed.")
    }
    private func health(_ root: URL, address: UInt64) throws {
        try atomicJSON(["address": address, "fingerprint": fingerprint(root)], to: root.appendingPathComponent("runtime-health.json"))
    }
    public func bootstrap(into destination: URL? = nil, source: URL? = nil) throws -> URL {
        let destination = destination ?? configuration.bootstrap
        if exists(destination.appendingPathComponent("bootstrap-ready.json")) { try wire(destination); return destination }
        let installed = try source ?? configuration.installedRiot()
        report("Preparing Apple Silicon components from the installed Riot Client…")
        let stage = data.appendingPathComponent("bootstrap-stage-" + UUID().uuidString)
        try makeDirectory(stage)
        defer { try? remove(stage) }
        let runtime = stage.appendingPathComponent(riotAppName)
        try clone(installed, runtime)
        try thinTree(runtime)
        try sign(runtime)
        let sdk = stage.appendingPathComponent("sdk-windows-override-arm64/RiotGamesApi.framework")
        try clone(runtime.appendingPathComponent("Contents/Frameworks/RiotGamesApi.framework"), sdk)
        let address = try patchWindowsSDK(sdk.appendingPathComponent("RiotGamesApi"))
        try sign(sdk)
        try makeHost(stage)
        try wire(stage)
        try validate(stage, address: address)
        try atomicJSON(["address": address], to: stage.appendingPathComponent("bootstrap-ready.json"))
        try replaceDirectory(stage, destination) { try self.validate(destination, address: address) }
        return destination
    }
    public func ensureHealthy(_ current: URL) throws -> URL {
        let backup = URL(fileURLWithPath: current.path + ".repair-backup")
        if !exists(current) && exists(backup) { try move(backup, current) }
        do {
            try refreshHost(current)
            let sdkMarker = current.appendingPathComponent("sdk-ready.json")
            let ready = try readJSON(exists(sdkMarker) ? sdkMarker : current.appendingPathComponent("bootstrap-ready.json"))
            guard let address = (ready["address"] as? NSNumber)?.uint64Value else { throw LauncherError("The SDK validation address is missing.") }
            let marker = current.appendingPathComponent("runtime-health.json")
            let record = (try? readJSON(marker)) ?? [:]
            if text(record["fingerprint"]) != (try fingerprint(current)) || (record["address"] as? NSNumber)?.uint64Value != address {
                try validate(current, address: address)
                try health(current, address: address)
            }
            try remove(backup)
            return current
        } catch {
            // A staged replacement keeps the current directory intact until validation succeeds.
        }
        try quit()
        report("Repairing Riot components…")
        let runtime = current.appendingPathComponent(riotAppName)
        let sameVersion = (try? command(["/usr/bin/codesign", "--verify", "--deep", "--strict", runtime.path], checked: false).status) == 0
        let source = try sameVersion ? runtime : configuration.installedRiot()
        let stage = data.appendingPathComponent("repair-stage-" + UUID().uuidString)
        defer { try? remove(stage) }
        let prepared = try bootstrap(into: stage, source: source)
        let ready = try readJSON(prepared.appendingPathComponent("bootstrap-ready.json"))
        guard let address = (ready["address"] as? NSNumber)?.uint64Value else { throw LauncherError("The repaired SDK validation address is missing.") }
        let previous = try state()
        var manifest = text(previous["manifest"])
        if manifest.isEmpty && matches(current.lastPathComponent, "[A-Fa-f0-9]{16}") {
            manifest = "https://ks-foundation.secure.dyn.riotcdn.net/channels/public/releases/" + current.lastPathComponent + ".manifest"
        }
        if sameVersion && !manifest.isEmpty { try atomicJSON(["manifest": manifest, "address": address], to: prepared.appendingPathComponent("sdk-ready.json")) }
        try refreshHost(prepared)
        let destination = sameVersion ? current : configuration.bootstrap
        try replaceDirectory(prepared, destination) {
            try self.validate(destination, address: address)
            try self.health(destination, address: address)
            if !sameVersion { try self.writeState(["root": destination.path, "manifest": NSNull()]) }
        }
        return destination
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
        let marker = candidate.appendingPathComponent("sdk-ready.json")
        if let ready = try? readJSON(marker), text(ready["manifest"]) == manifest, let address = (ready["address"] as? NSNumber)?.uint64Value {
            do { try refreshHost(candidate); try validate(candidate, address: address); return candidate } catch { }
        }
        try require(resolved(candidate) != resolved(current), "The active Riot runtime cannot be replaced while preparing an update.")
        try remove(candidate)
        let stage = data.appendingPathComponent("runtime-stage-" + UUID().uuidString)
        try makeDirectory(stage)
        defer { try? remove(stage) }
        let downloaded = try downloadRuntime(current: current, stage: stage, manifest: manifest)
        let prepared = stage.appendingPathComponent("prepared")
        do { _ = try bootstrap(into: prepared, source: downloaded) }
        catch { throw IncompatibleRuntime(cause: error) }
        let address = try readJSON(prepared.appendingPathComponent("bootstrap-ready.json"))["address"]
        try atomicJSON(["manifest": manifest, "address": address ?? NSNull()], to: prepared.appendingPathComponent("sdk-ready.json"))
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
