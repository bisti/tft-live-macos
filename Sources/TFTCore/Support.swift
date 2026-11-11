import Foundation
import CryptoKit
import Darwin

public typealias JSON = [String: Any]
public func object(_ value: Any?) -> JSON { value as? JSON ?? [:] }
public func objects(_ value: Any?) -> [JSON] { value as? [JSON] ?? [] }
public func text(_ value: Any?) -> String { value as? String ?? "" }
public func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
public func exists(_ path: URL) -> Bool { FileManager.default.fileExists(atPath: path.path) }
public func resolved(_ path: URL) -> URL {
    var current = path.standardizedFileURL
    var suffix: [String] = []
    var visited: Set<String> = []
    while true {
        if let canonical = realpath(current.path, nil) {
            defer { free(canonical) }
            return suffix.reversed().reduce(URL(fileURLWithPath: String(cString: canonical))) { $0.appendingPathComponent($1) }
        }
        if isSymlink(current), let target = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path), visited.insert(current.path).inserted {
            current = target.hasPrefix("/") ? URL(fileURLWithPath: target) : current.deletingLastPathComponent().appendingPathComponent(target)
            continue
        }
        if current.path == "/" { return suffix.reversed().reduce(current) { $0.appendingPathComponent($1) } }
        suffix.append(current.lastPathComponent)
        current.deleteLastPathComponent()
    }
}
public func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: "^(?:" + pattern + ")$", options: .regularExpression) != nil
}
public struct LauncherError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw LauncherError(message) }
}
public func readJSON(_ path: URL) throws -> JSON {
    guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? JSON else {
        throw LauncherError("Invalid JSON object in " + path.lastPathComponent + ".")
    }
    return value
}
public func jsonData(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
}
public func atomicWrite(_ data: Data, to path: URL) throws {
    try data.write(to: path, options: .atomic)
    let descriptor = open(path.path, O_RDONLY | O_CLOEXEC)
    if descriptor >= 0 { _ = fsync(descriptor); close(descriptor) }
}
public func atomicJSON(_ value: JSON, to path: URL) throws { try atomicWrite(jsonData(value), to: path) }
public func readText(_ path: URL) throws -> String { try String(contentsOf: path, encoding: .utf8) }
public func writeText(_ value: String, to path: URL) throws { try atomicWrite(Data(value.utf8), to: path) }
public func makeDirectory(_ path: URL) throws {
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
}
public func remove(_ path: URL) throws {
    if (try? FileManager.default.attributesOfItem(atPath: path.path)) != nil {
        try FileManager.default.removeItem(at: path)
    }
}
public func move(_ source: URL, _ destination: URL) throws {
    try FileManager.default.moveItem(at: source, to: destination)
}
public func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
public func fileDigest(_ path: URL) throws -> String { sha256(try Data(contentsOf: path, options: .mappedIfSafe)) }
public func monotonic() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
public func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

final class ResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    func store(_ value: Result<Value, Error>) { lock.lock(); defer { lock.unlock() }; result = value }
    func get() throws -> Value {
        lock.lock(); defer { lock.unlock() }
        guard let result else { throw LauncherError("The operation returned no result.") }
        return try result.get()
    }
}

public struct CommandResult {
    public let status: Int32
    public let output: String
    public let errorOutput: String
    public init(status: Int32, output: String = "", errorOutput: String = "") {
        self.status = status
        self.output = output
        self.errorOutput = errorOutput
    }
}
@discardableResult public func command(_ arguments: [String], checked: Bool = true, timeout: TimeInterval? = nil) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: arguments[0])
    process.arguments = Array(arguments.dropFirst())
    let pipe = Pipe()
    let diagnostics = Pipe()
    process.standardOutput = pipe
    process.standardError = diagnostics
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let expiration = DispatchWorkItem {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: expiration) }
    defer { expiration.cancel() }
    let errors = ResultBox<Data>()
    let reader = DispatchGroup()
    reader.enter()
    DispatchQueue.global().async {
        errors.store(.success(diagnostics.fileHandleForReading.readDataToEndOfFile()))
        reader.leave()
    }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    reader.wait()
    let result = CommandResult(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self),
                               errorOutput: String(decoding: try errors.get(), as: UTF8.self))
    if checked && result.status != 0 {
        throw LauncherError(URL(fileURLWithPath: arguments[0]).lastPathComponent + " failed. " + String((result.output + result.errorOutput).suffix(2000)))
    }
    return result
}
public func clone(_ source: URL, _ destination: URL) throws {
    try makeDirectory(destination.deletingLastPathComponent())
    if try command(["/bin/cp", "-cR", source.path, destination.path], checked: false).status != 0 {
        try remove(destination)
        try command(["/bin/cp", "-Rp", source.path, destination.path])
    }
}
public func sign(_ path: URL, deep: Bool = true) throws {
    try command(["/usr/bin/codesign", "--force"] + (deep ? ["--deep"] : []) + ["--sign", "-", path.path])
}
public func verify(_ path: URL) throws { try command(["/usr/bin/codesign", "--verify", "--deep", "--strict", path.path]) }
public func files(_ root: URL) -> [URL] {
    guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    return iterator.compactMap { $0 as? URL }
}
public func isSymlink(_ path: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType) == .typeSymbolicLink
}
public func isInside(_ path: URL, _ root: URL) -> Bool {
    resolved(path).path.hasPrefix(resolved(root).path + "/")
}

/// Publish a fully prepared directory, retaining the old one until validation succeeds.
public func replaceDirectory(_ staged: URL, _ destination: URL, validate: () throws -> Void) throws {
    let backup = URL(fileURLWithPath: destination.path + ".repair-backup")
    if !exists(destination) && exists(backup) { try move(backup, destination) }
    try remove(backup)
    if exists(destination) { try move(destination, backup) }
    do {
        try move(staged, destination)
        try validate()
    } catch {
        try remove(destination)
        if exists(backup) { try move(backup, destination) }
        throw error
    }
    try remove(backup)
}
