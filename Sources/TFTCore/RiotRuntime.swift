import Foundation
import Darwin

public struct PreparationCancelled: Error {
    public init() {}
}

public final class RiotRuntime {
    public static let applyingUpdateStatus = "Applying the Riot component update…"
    public let configuration: Configuration
    public let api: LocalAPI
    public let fetch: (URL) throws -> JSON
    public let report: (String) -> Void
    let checkCancellation: () throws -> Void
    private var children: [Int32: Process] = [:]
    public init(_ configuration: Configuration, api: LocalAPI? = nil, fetch: ((URL) throws -> JSON)? = nil,
                checkCancellation: @escaping () throws -> Void = {},
                report: @escaping (String) -> Void = { print($0); fflush(stdout) }) {
        self.configuration = configuration
        let http = HTTPClient()
        self.api = api ?? http.local
        self.fetch = fetch ?? http.json
        self.report = report
        self.checkCancellation = checkCancellation
    }
    public var data: URL { configuration.data }
    public func state() throws -> JSON {
        let file = data.appendingPathComponent("runtime-current.json")
        return exists(file) ? try readJSON(file) : [:]
    }
    public func writeState(_ value: JSON) throws { try atomicJSON(value, to: data.appendingPathComponent("runtime-current.json")) }
    public func selectedRoot(_ state: JSON) throws -> URL {
        let stored = text(state["root"])
        let path = stored.isEmpty ? configuration.initialRuntime : URL(fileURLWithPath: stored)
        let root = resolved(path)
        let profile = resolved(data)
        let seed = profile.appendingPathComponent("seed")
        let releases = profile.appendingPathComponent("runtimes")
        try require((stored.isEmpty || stored.hasPrefix("/")) && !isSymlink(path) &&
                    (root.path == seed.path || (root.deletingLastPathComponent().path == releases.path && !isSymlink(releases))),
                    "The Riot runtime directory is invalid.")
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
        guard let active = sessions.value as? JSON else { throw LauncherError("Unable to verify the active Riot sessions.") }
        for session in active.values {
            guard let product = object(session)["productId"] as? String, !product.isEmpty else {
                throw LauncherError("Unable to identify an active Riot session.")
            }
            try require(product == "riot_client", "A game is running. The Riot update will be applied after it closes.")
        }
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
        guard let previous = old["previous_root"] as? String, !previous.isEmpty else {
            throw LauncherError("The previous Riot runtime is unavailable.")
        }
        let restored: JSON = ["root": previous, "manifest": old["previous_manifest"] ?? NSNull()]
        let root = try selectedRoot(restored)
        try writeState(restored)
        return root
    }
    public func confirm() throws {
        var state = try state()
        guard !text(state["root"]).isEmpty else { return }
        var keep = Set([try selectedRoot(state).path])
        if let previous = state["previous_root"] as? String {
            keep.insert(try selectedRoot(["root": previous]).path)
        }
        if state["pending"] as? Bool == true { state["pending"] = false; try writeState(state) }
        let releases = data.appendingPathComponent("runtimes")
        guard !isSymlink(releases) else { return }
        var candidates = ((try? FileManager.default.contentsOfDirectory(at: releases, includingPropertiesForKeys: nil)) ?? [])
            .filter { matches($0.lastPathComponent, "[A-Fa-f0-9]{16}") }
        if keep.count == 2 && keep.allSatisfy({ exists(URL(fileURLWithPath: $0).appendingPathComponent(hostRelativePath)) }) {
            candidates.append(configuration.initialRuntime)
        }
        for candidate in candidates where !isSymlink(candidate) && !keep.contains(resolved(candidate).path) {
            if exists(candidate.appendingPathComponent("runtime.json")) { try remove(candidate) }
        }
    }
    public func finishSetup(_ candidate: URL, prepare: (URL) throws -> Bool, restore: (URL) throws -> URL) throws -> Bool {
        let running: Bool
        do { running = try prepare(candidate) }
        catch {
            if try state()["pending"] as? Bool != true { throw error }
            try quit()
            guard let previous = try rollback() else { throw error }
            if error is PreparationCancelled { throw error }
            let restored = try restore(previous)
            report("Automatically restored the previous Riot components. " + error.localizedDescription)
            running = try prepare(restored)
        }
        try confirm()
        return running
    }
}
