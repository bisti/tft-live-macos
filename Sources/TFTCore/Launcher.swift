import Foundation
import Darwin

public let sessionRoute = "/product-session/v1/sessions"
public let patchRoute = "/rnet-product-registry/v4/patch-states/products/teamfighttactics/patchlines/live"
public let patchRequestRoute = "/rnet-product-registry/v4/patch-requests/products/teamfighttactics/patchlines/live"
public func gameIsRunning(_ sessions: JSON) -> Bool { sessions.values.contains { text(object($0)["productId"]) == "teamfighttactics" } }

public final class Launcher {
    public let configuration: Configuration
    public let runtime: RiotRuntime
    public let game: URL
    public var report: (String) -> Void { runtime.report }
    public init(_ configuration: Configuration, runtime: RiotRuntime? = nil) throws {
        self.configuration = configuration
        self.runtime = runtime ?? RiotRuntime(configuration)
        game = try configuration.gamePath()
    }
    public func api(_ method: String, _ route: String, _ body: JSON? = nil) -> HTTPResult {
        runtime.api(method, route, body, configuration.lockfile)
    }
    private func syncInstallSetting() throws {
        let path = configuration.data.appendingPathComponent("shared/teamfighttactics.live/teamfighttactics.live.product_settings.yaml")
        guard let original = try? readText(path) else { return }
        let ending = original.contains("\r\n") ? "\r\n" : "\n"
        var lines = original.components(separatedBy: ending)
        let wanted = ["product_install_full_path": game.path, "product_install_root": game.deletingLastPathComponent().path]
        for index in lines.indices {
            let key = String(lines[index].prefix { $0 != ":" })
            if let value = wanted[key] { lines[index] = key + ": " + String(decoding: try jsonData(value), as: UTF8.self) }
        }
        let updated = lines.joined(separator: ending)
        if original != updated { try writeText(updated, to: path) }
    }
    public func connect(_ root: URL) throws {
        var process: Process?
        if api("GET", sessionRoute).status != 200 {
            let normalLock = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Riot Games/Riot Client/Config/lockfile")
            if runtime.api("GET", sessionRoute, nil, normalLock).status == 200 {
                report("Closing the regular Riot Client…")
                try runtime.quit(normalLock)
            }
            try syncInstallSetting()
            try pruneLogs(configuration.data)
            process = try runtime.spawn(root.appendingPathComponent(hostRelativePath))
        }
        let deadline = monotonic() + 600
        while monotonic() < deadline {
            if let process, !process.isRunning {
                throw LauncherError("The Riot sign-in component stopped during startup (exit code \(process.terminationStatus)).")
            }
            let authorization = api("GET", "/rso-auth/v1/authorization/access-token")
            if authorization.status == 200 {
                let token = text(authorization.json["token"]).components(separatedBy: ".")
                try require(token.count == 3, "The Riot session did not provide a recognized token.")
                var encoded = token[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
                guard let bytes = Data(base64Encoded: encoded) else { throw LauncherError("The Riot session token is malformed.") }
                let claims = object(try JSONSerialization.jsonObject(with: bytes))
                try require(text(object(claims["plt"])["id"]) == "windows", "The Riot session is not recognized as Windows.")
                return
            }
            pause(1)
        }
        throw LauncherError("Riot sign-in is still pending. Sign in again, then reopen TFT Live.")
    }
    public func accountRegion(_ current: URL) throws -> Region {
        let response = api("GET", "/rso-auth/v1/authorization/userinfo")
        try require(response.status == 200, "The signed-in Riot account region is unavailable.")
        let region: String
        do { region = try decodeUserRegion(response.json["userInfo"]) }
        catch {
            let election = api("GET", "/riot-client-lifecycle/v1/league-region-election")
            let selected = election.json["selectedRegions"] as? [String] ?? []
            try require(election.status == 200 && selected.count == 1 && matches(selected[0], "[A-Z0-9]{2,8}"),
                        "Finish selecting a server in Riot, then reopen TFT Live.")
            region = selected[0]
        }
        if let cached = try configuration.cachedConfiguration(), let settings = try? regionSettings(region, configuration: cached) {
            return settings
        }
        return try regionSettings(region, configuration: runtime.officialConfiguration(current))
    }
    public func liveRelease(_ region: Region) throws -> Release {
        // Both publications must agree before a regional release can be selected.
        let macResult = ResultBox<Release>()
        let windowsResult = ResultBox<Release>()
        let group = DispatchGroup()
        for (platform, result) in [("macos", macResult), ("windows", windowsResult)] {
            group.enter()
            DispatchQueue.global().async {
                result.store(Result { try publishedRelease(platform: platform, channel: region.versionSet, fetch: self.runtime.fetch) })
                group.leave()
            }
        }
        group.wait()
        let mac = try macResult.get()
        let windows = try windowsResult.get()
        try require(mac.version == windows.version, "The Mac and Windows releases for " + region.versionSet + " are still out of sync.")
        return mac
    }
    public func updateGame(_ target: String) throws {
        let started = monotonic()
        var deadline = started + 60
        var requested = false
        var lastShown = -1
        var lastActivity = Data()
        while true {
            let response = api("GET", patchRoute)
            if response.status == 200 {
                let state = response.json
                let manifest = text(object(state["configuration"])["patch_url"])
                try require(manifest.isEmpty || manifest == target, "The running Riot component targets a different release from live. Close Riot and TFT, then reopen TFT Live.")
                let combined = text(state["combined_patch_state"])
                if combined == "up_to_date" { if requested { report("Update complete.") }; return }
                if ["out_of_date", "not_installed"].contains(combined) && !requested {
                    report("Installing or updating TFT to the live release…")
                    let status = api("PUT", patchRequestRoute, [:]).status
                    try require([200, 201, 204].contains(status), "The Riot component refused the update (HTTP \(status)).")
                    requested = true
                    deadline = monotonic() + 600
                    pause(0.2)
                    continue
                }
                let patch = object(state["patch_status"])
                if combined == "updating" {
                    let progress = object(patch["progress"])
                    let percent = number(progress["progress"])
                    let shown = Int(percent) / 10 * 10
                    if shown > lastShown { report("  \(shown) %"); lastShown = shown }
                    let activity = try jsonData([progress["phase"] ?? NSNull(), percent, object(progress["update"])["downloaded_bytes"] ?? NSNull(),
                                                 object(progress["update"])["written_bytes"] ?? NSNull()])
                    if activity != lastActivity { deadline = monotonic() + 600; lastActivity = activity }
                }
                if combined == "bad_install_path" && monotonic() - started > 30 { throw LauncherError("The Riot component does not recognize the TFT installation.") }
                if requested {
                    try require(state["user_cancelled_patching"] as? Bool != true, "TFT installation was interrupted. Reopen TFT Live to resume.")
                    try require(patch["error"] == nil || patch["error"] is NSNull, "TFT update failed. Reopen TFT Live to retry.")
                }
            }
            try require(monotonic() < deadline, "The TFT update has stopped progressing. Reopen TFT Live.")
            pause(2)
        }
    }
    public func prepareGame(_ current: URL, region: Region, release: Release) throws -> Bool {
        try require(try accountRegion(current).id == region.id, "The Riot account changed during setup. Reopen TFT Live to select its server.")
        if gameIsRunning(api("GET", sessionRoute).json) { return true }
        try makeDirectory(game.deletingLastPathComponent())
        try atomicJSON(["game_path": game.path], to: configuration.data.appendingPathComponent("install.json"))
        let deadline = monotonic() + 30
        var status: Int
        repeat {
            status = api("PUT", "/rnet-product-registry/v4/products/teamfighttactics/patchlines/live/install-path",
                         ["root_path": game.deletingLastPathComponent().path, "full_path": game.path]).status
            if status != 404 || monotonic() >= deadline { break }
            pause(0.5)
        } while true
        try require([200, 201, 204].contains(status), "Unable to register the existing TFT installation.")
        try updateGame(release.manifest)
        let patch = api("GET", patchRoute)
        let loaded = object(patch.json["configuration"])
        try require(patch.status == 200 && text(loaded["patch_url"]) == release.manifest && text(loaded["id"]) == region.id
                    && text(patch.json["combined_patch_state"]) == "up_to_date", "TFT preparation did not confirm the requested live release and server.")
        try require(exists(game.appendingPathComponent("Contents/MacOS/TFTClient-Mac-Shipping")), "The Riot patcher did not install the expected TFT Mac client.")
        return false
    }
    public func run() throws {
        umask(0o077)
        try makeDirectory(configuration.data)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configuration.data.path)
        let lock = open(configuration.data.appendingPathComponent("launch.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try require(lock >= 0, "Unable to open the launcher lock.")
        defer { flock(lock, LOCK_UN); close(lock) }
        if flock(lock, LOCK_EX | LOCK_NB) != 0 { report("TFT launch is already in progress."); return }
        if gameIsRunning(api("GET", sessionRoute).json) { report("TFT is already running. Updates will be checked on the next launch."); return }
        try configuration.prepareFiles()
        var state = try runtime.state()
        if text(state["root"]).isEmpty && !exists(configuration.initialRuntime.appendingPathComponent("runtime.json")) { _ = try runtime.prepareRuntime() }
        if state["pending"] as? Bool == true { try runtime.quit(); _ = try runtime.rollback(); state = try runtime.state() }
        let current = try runtime.ensureHealthy(runtime.selectedRoot(state))
        try runtime.wire(current)
        report("Sign in to Riot to prepare TFT live.")
        try connect(current)
        let region = try accountRegion(current)
        let release = try liveRelease(region)
        report("Live version " + region.id + " — " + release.version)
        let changed = try configuration.configureRegion(region, manifest: release.manifest, version: release.version)
        let loaded = object(api("GET", patchRoute).json["configuration"])
        if changed || (!loaded.isEmpty && (text(loaded["patch_url"]) != release.manifest || text(loaded["id"]) != region.id)) { try runtime.quit() }
        let candidate = try runtime.ensureRuntime()
        let running = try runtime.finishSetup(candidate, prepare: { root in
            try self.connect(root)
            return try self.prepareGame(root, region: region, release: release)
        }, restore: runtime.ensureHealthy)
        report(running ? "Riot is ready. TFT is already running with the Windows session." : "Riot is ready. Click Play in the client to launch TFT live.")
    }
}
