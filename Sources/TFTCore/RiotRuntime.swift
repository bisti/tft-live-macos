import Foundation
import Darwin

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
        let root = resolved(URL(fileURLWithPath: text(state["root"]).isEmpty ? configuration.initialRuntime.path : text(state["root"])))
        try require(root == resolved(configuration.initialRuntime) || isInside(root, data.appendingPathComponent("runtimes")), "The Riot runtime directory is invalid.")
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
        if keep.count == 2 && keep.allSatisfy({ exists($0.appendingPathComponent(hostRelativePath)) }) { candidates.append(configuration.initialRuntime) }
        for candidate in candidates where !isSymlink(candidate) && !keep.contains(resolved(candidate)) {
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
            let restored = try restore(previous)
            report("Automatically restored the previous Riot components. " + error.localizedDescription)
            running = try prepare(restored)
        }
        try confirm()
        return running
    }
}
