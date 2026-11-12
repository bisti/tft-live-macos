import Foundation
import Darwin

public final class RotatingLog {
    public let path: URL
    public let limit: Int
    public init(_ path: URL, limit: Int = 10 * 1024 * 1024) { self.path = path; self.limit = limit }

    public func append(_ data: Data) throws {
        let lock = open(path.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw LauncherError("Unable to open the log lock.") }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw LauncherError("Unable to lock the log.") }
        if !exists(path) { FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        try trimLog(path, limit: limit)
        var offset = 0
        repeat {
            let size = (try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.intValue ?? 0
            let count = min(data.count - offset, limit)
            if size + count > limit {
                for archive in stride(from: 3, through: 1, by: -1) {
                    let source = archive == 1 ? path : URL(fileURLWithPath: path.path + ".\(archive - 1)")
                    let destination = URL(fileURLWithPath: path.path + ".\(archive)")
                    if exists(source) { try remove(destination); try move(source, destination) }
                }
                FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let output = try FileHandle(forWritingTo: path)
            defer { try? output.close() }
            try output.seekToEnd()
            if count > 0 { try output.write(contentsOf: data.subdata(in: offset..<(offset + count))) }
            offset += count
        } while offset < data.count
    }
    public func line(_ message: String) { try? append(Data((message + "\n").utf8)) }
}

public func trimLog(_ path: URL, limit: Int) throws {
    let size = (try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.intValue ?? 0
    if size <= limit { return }
    let handle = try FileHandle(forUpdating: path)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(size - limit))
    let tail = try handle.read(upToCount: limit) ?? Data()
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: tail)
    try handle.truncate(atOffset: UInt64(tail.count))
}

public func pruneLogs(_ data: URL) throws {
    let root = data.appendingPathComponent("logs")
    let logs = files(root).filter { $0.pathExtension == "log" && !isSymlink($0) && isInside($0, root) }
    for group in Dictionary(grouping: logs, by: { $0.deletingLastPathComponent() }).values {
        let newest = group.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        for (index, path) in newest.enumerated() {
            if index < 3 { try trimLog(path, limit: 10 * 1024 * 1024) } else { try remove(path) }
        }
    }
}

/// The relay owns the reader until every inherited writer has closed its output.
public func startConsoleRelay(_ path: URL, executable: URL) throws -> (process: Process, input: FileHandle) {
    try RotatingLog(path).append(Data())
    let channel = Pipe()
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--console-relay", path.path]
    process.standardInput = channel
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    try channel.fileHandleForReading.close()
    return (process, channel.fileHandleForWriting)
}

public func relayConsole(_ path: URL) {
    let log = RotatingLog(path)
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { return }
        try? log.append(Data(buffer.prefix(count)))
    }
}

public func captureConsole(_ path: URL, executable: URL) throws {
    let relay = try startConsoleRelay(path, executable: executable)
    defer { try? relay.input.close() }
    fflush(stdout); fflush(stderr)
    guard dup2(relay.input.fileDescriptor, STDOUT_FILENO) >= 0,
          dup2(relay.input.fileDescriptor, STDERR_FILENO) >= 0 else {
        throw LauncherError("Unable to connect the Riot console log.")
    }
}
