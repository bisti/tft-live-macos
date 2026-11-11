import Foundation
import Darwin

struct BinaryData {
    var bytes: Data
    func integer(_ offset: Int, _ count: Int, bigEndian: Bool = false) throws -> UInt64 {
        try require(offset >= 0 && count > 0 && count <= 8 && offset <= bytes.count - count, "The Mach-O component is truncated.")
        var result: UInt64 = 0
        for index in 0..<count {
            let shift = bigEndian ? count - index - 1 : index
            result |= UInt64(bytes[offset + index]) << (shift * 8)
        }
        return result
    }
    func name(_ offset: Int) throws -> String {
        try require(offset >= 0 && offset <= bytes.count - 16, "The Mach-O section name is truncated.")
        return String(decoding: bytes[offset..<(offset + 16)].prefix { $0 != 0 }, as: UTF8.self)
    }
    mutating func write32(_ offset: Int, _ value: UInt32) throws {
        try require(offset >= 0 && offset <= bytes.count - 4, "The SDK instruction is out of range.")
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
}

/// Locate the unique ARM64 getter by its instructions and referenced platform string.
public func patchWindowsSDK(_ path: URL) throws -> UInt64 {
    var image = BinaryData(bytes: try Data(contentsOf: path))
    try require(try image.integer(0, 4) == 0xfeedfacf && image.integer(4, 4) == 0x100000c, "The SDK must contain only the ARM64 slice.")
    var sections: [String: (address: Int64, length: Int, offset: Int)] = [:]
    var imageAddress: UInt64 = 0
    var position = 32
    let commands = Int(try image.integer(16, 4))
    try require(commands <= image.bytes.count / 8, "Invalid Mach-O command count.")
    for _ in 0..<commands {
        let kind = try image.integer(position, 4)
        let size = Int(try image.integer(position + 4, 4))
        try require(size >= 8 && position <= image.bytes.count - size, "Invalid Mach-O load command.")
        if kind == 0x19 {
            try require(size >= 72, "The Mach-O segment command is truncated.")
            if try image.name(position + 8) == "__TEXT" { imageAddress = try image.integer(position + 24, 8) }
            let count = Int(try image.integer(position + 64, 4))
            try require(count <= (size - 72) / 80, "Invalid Mach-O section count.")
            for index in 0..<count {
                let section = position + 72 + index * 80
                let name = try image.name(section)
                let address = try image.integer(section + 32, 8)
                let length = try image.integer(section + 40, 8)
                try require(address <= UInt64(Int64.max) && length <= UInt64(Int.max), "The SDK section is out of range.")
                sections[name] = (Int64(address), Int(length), Int(try image.integer(section + 48, 4)))
            }
        }
        position += size
    }
    guard let code = sections["__text"], let strings = sections["__cstring"] else { throw LauncherError("The SDK sections are unavailable.") }
    try require(code.offset <= image.bytes.count - code.length && strings.offset <= image.bytes.count - strings.length,
                "The SDK sections are truncated.")
    let stringBytes = image.bytes.subdata(in: strings.offset..<(strings.offset + strings.length))
    guard let windows = stringBytes.range(of: Data([0] + Array("windows".utf8) + [0])) else {
        throw LauncherError("The SDK does not provide the expected Windows platform.")
    }
    let windowsAddress = strings.address + Int64(windows.lowerBound + 1)
    var candidates: [(Int, Int64)] = []
    for offset in stride(from: code.offset, to: code.offset + code.length - 11, by: 4) {
        let adrp = UInt32(try image.integer(offset, 4))
        let add = UInt32(try image.integer(offset + 4, 4))
        let ret = try image.integer(offset + 8, 4)
        if adrp & 0x9f00001f != 0x90000000 || add & 0xffc003ff != 0x91000000 || ret != 0xd65f03c0 { continue }
        let address = code.address + Int64(offset - code.offset)
        var immediate = Int64((adrp >> 29) & 3) | Int64((adrp >> 5) & 0x7ffff) << 2
        if immediate & (1 << 20) != 0 { immediate -= 1 << 21 }
        let target = (address & ~4095) + (immediate << 12) + Int64((add >> 10) & 4095)
        let index = target - strings.address
        if index >= 0 && index <= Int64(stringBytes.count - 4), stringBytes.subdata(in: Int(index)..<(Int(index) + 4)) == Data([109, 97, 99, 0]) {
            candidates.append((offset, address))
        }
    }
    try require(candidates.count == 1, "The new SDK platform function cannot be identified unambiguously.")
    let (offset, address) = candidates[0]
    let pages = ((windowsAddress & ~4095) - (address & ~4095)) / 4096
    try require(pages >= -(1 << 20) && pages < 1 << 20, "The SDK platform string is out of range.")
    let immediate = UInt32(truncatingIfNeeded: pages) & 0x1fffff
    try image.write32(offset, 0x90000000 | ((immediate & 3) << 29) | ((immediate >> 2) << 5))
    try image.write32(offset + 4, 0x91000000 | (UInt32(windowsAddress & 4095) << 10))
    try require(address >= 0 && UInt64(address) >= imageAddress, "Invalid SDK image address.")
    try image.bytes.write(to: path)
    return UInt64(address) - imageAddress
}

public func thinBinary(_ path: URL) throws {
    let input = try FileHandle(forReadingFrom: path)
    defer { try? input.close() }
    let header = BinaryData(bytes: try input.read(upToCount: 8) ?? Data())
    let magic = try header.integer(0, 4, bigEndian: true)
    let count = Int(try header.integer(4, 4, bigEndian: true))
    try require((magic == 0xcafebabe || magic == 0xcafebabf) && (1...32).contains(count), "Unsupported universal binary format.")
    let wide = magic == 0xcafebabf
    let entrySize = wide ? 32 : 20
    let entries = BinaryData(bytes: try input.read(upToCount: count * entrySize) ?? Data())
    var slices: [(UInt64, UInt64)] = []
    for index in 0..<count {
        let entry = index * entrySize
        if try entries.integer(entry, 4, bigEndian: true) == 0x100000c && entries.integer(entry + 4, 4, bigEndian: true) & 0xffffff <= 1 {
            slices.append((try entries.integer(entry + 8, wide ? 8 : 4, bigEndian: true),
                           try entries.integer(entry + (wide ? 16 : 12), wide ? 8 : 4, bigEndian: true)))
        }
    }
    try require(slices.count == 1, "Component does not have a unique Apple Silicon slice.")
    let (offset, size) = slices[0]
    let total = try input.seekToEnd()
    try require(offset >= UInt64(8 + count * entrySize) && offset <= total && size <= total - offset, "Invalid Apple Silicon slice.")
    try input.seek(toOffset: offset)
    let temporary = URL(fileURLWithPath: path.path + ".arm64-tmp")
    defer { try? remove(temporary) }
    FileManager.default.createFile(atPath: temporary.path, contents: nil)
    let output = try FileHandle(forWritingTo: temporary)
    var remaining = size
    while remaining > 0 {
        let bytes = try input.read(upToCount: Int(min(remaining, 1024 * 1024))) ?? Data()
        try require(!bytes.isEmpty, "Incomplete Apple Silicon component.")
        try output.write(contentsOf: bytes)
        remaining -= UInt64(bytes.count)
    }
    try output.close()
    let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions]
    try FileManager.default.setAttributes([.posixPermissions: mode ?? 0o700], ofItemAtPath: temporary.path)
    guard rename(temporary.path, path.path) == 0 else { throw LauncherError("Unable to replace the universal component.") }
}

public func thinTree(_ root: URL) throws {
    for path in files(root) where path.path.hasSuffix("/Krisp/x64") && !isSymlink(path) { try remove(path) }
    for path in files(root) where !isSymlink(path) {
        guard let values = try? path.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else { continue }
        let input = try FileHandle(forReadingFrom: path)
        let header = BinaryData(bytes: try input.read(upToCount: 8) ?? Data())
        try input.close()
        if header.bytes.count < 8 { continue }
        let magic = try header.integer(0, 4, bigEndian: true)
        if magic == 0xcffaedfe { try require(try header.integer(4, 4) == 0x100000c, "Component has no Apple Silicon slice. " + path.path) }
        if magic == 0xcafebabe || magic == 0xcafebabf {
            try thinBinary(path)
            try command(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", "--preserve-metadata=entitlements", path.path])
        }
    }
}
