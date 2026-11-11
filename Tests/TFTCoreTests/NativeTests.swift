import Testing
import Foundation
import Darwin
@testable import TFTCore

func put(_ bytes: inout Data, _ offset: Int, _ value: UInt64, width: Int = 4, bigEndian: Bool = false) {
    for index in 0..<width { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> ((bigEndian ? width - index - 1 : index) * 8)) }
}
func putName(_ bytes: inout Data, _ offset: Int, _ value: String) { bytes.replaceSubrange(offset..<(offset + value.utf8.count), with: value.utf8) }
func syntheticSDK(address: Int = 0x200, image: UInt64 = 0, duplicate: Bool = false) -> Data {
    var bytes = Data(repeating: 0, count: 0x600)
    put(&bytes, 0, 0xfeedfacf)
    put(&bytes, 4, 0x100000c)
    put(&bytes, 12, 6)
    put(&bytes, 16, 1)
    put(&bytes, 20, 232)
    put(&bytes, 32, 0x19)
    put(&bytes, 36, 232)
    putName(&bytes, 40, "__TEXT")
    put(&bytes, 56, image, width: 8)
    put(&bytes, 96, 2)
    for (index, section) in [("__text", address, 24), ("__cstring", 0x400, 0x100)].enumerated() {
        let position = 32 + 72 + index * 80
        putName(&bytes, position, section.0)
        put(&bytes, position + 32, image + UInt64(section.1), width: 8)
        put(&bytes, position + 40, UInt64(section.2), width: 8)
        put(&bytes, position + 48, UInt64(section.1))
    }
    bytes.replaceSubrange(0x410..<0x414, with: [109, 97, 99, 0])
    bytes.replaceSubrange(0x420..<0x428, with: [119, 105, 110, 100, 111, 119, 115, 0])
    for position in duplicate ? [address, address + 12] : [address] {
        put(&bytes, position, 0x90000000)
        put(&bytes, position + 4, 0x91000000 | (0x410 << 10))
        put(&bytes, position + 8, 0xd65f03c0)
    }
    return bytes
}

final class NativeComponentTests: TemporaryTests {
    @Test func testSDKGetterIsLocatedAcrossOffsetsAndImageAddresses() throws {
        for address in [0x200, 0x300] {
            for base: UInt64 in [0, 0x100000000] {
                let path = try file("SDK", syntheticSDK(address: address, image: base))
                #expect((try patchWindowsSDK(path)) == (UInt64(address)))
                let output = BinaryData(bytes: try Data(contentsOf: path))
                #expect(((try output.integer(address + 4, 4) >> 10) & 4095) == (0x420))
            }
        }
    }
    @Test func testAmbiguousSDKGetterDoesNotModifyTheFile() throws {
        let bytes = syntheticSDK(duplicate: true)
        let path = try file("SDK", bytes)
        #expect(throws: (any Error).self) { try patchWindowsSDK(path) }
        #expect((try Data(contentsOf: path)) == (bytes))
    }
    @Test func testTruncatedMachOAndInvalidCommandsFailSafely() throws {
        var malformed = syntheticSDK()
        put(&malformed, 36, 8)
        for bytes in [Data(), Data([1, 2, 3]), malformed, Data(syntheticSDK().prefix(100))] {
            let path = try file("SDK", bytes)
            #expect(throws: (any Error).self) { try patchWindowsSDK(path) }
            #expect((try Data(contentsOf: path)) == (bytes))
        }
    }
    @Test func testMissingWindowsPlatformFailsSafely() throws {
        var bytes = syntheticSDK()
        bytes.replaceSubrange(0x420..<0x428, with: repeatElement(UInt8(0), count: 8))
        let path = try file("SDK", bytes)
        #expect(throws: (any Error).self) { try patchWindowsSDK(path) }
    }
    @Test func testUniversal32And64KeepOnlyARM64() throws {
        for wide in [false, true] {
            var bytes = Data(repeating: 0, count: 0x140)
            put(&bytes, 0, wide ? 0xcafebabf : 0xcafebabe, bigEndian: true)
            put(&bytes, 4, 2, bigEndian: true)
            let size = wide ? 32 : 20
            for (index, slice) in [(UInt64(0x1000007), UInt64(0x80)), (UInt64(0x100000c), UInt64(0x100))].enumerated() {
                let entry = 8 + index * size
                put(&bytes, entry, slice.0, bigEndian: true)
                put(&bytes, entry + 8, slice.1, width: wide ? 8 : 4, bigEndian: true)
                put(&bytes, entry + (wide ? 16 : 12), 16, width: wide ? 8 : 4, bigEndian: true)
            }
            put(&bytes, 0x100, 0xfeedfacf)
            put(&bytes, 0x104, 0x100000c)
            let path = try file("universal", bytes)
            try thinBinary(path)
            #expect((try Data(contentsOf: path)) == (bytes.subdata(in: 0x100..<0x110)))
        }
    }
    @Test func testUniversalWithoutARM64FailsWithoutChangingTheFile() throws {
        var bytes = Data(repeating: 0, count: 128)
        put(&bytes, 0, 0xcafebabe, bigEndian: true)
        put(&bytes, 4, 1, bigEndian: true)
        put(&bytes, 8, 0x1000007, bigEndian: true)
        let path = try file("universal", bytes)
        #expect(throws: (any Error).self) { try thinBinary(path) }
        #expect((try Data(contentsOf: path)) == (bytes))
    }
    @Test func testInvalidSliceRangeFailsWithoutChangingTheFile() throws {
        var bytes = Data(repeating: 0, count: 128)
        put(&bytes, 0, 0xcafebabe, bigEndian: true)
        put(&bytes, 4, 1, bigEndian: true)
        put(&bytes, 8, 0x100000c, bigEndian: true)
        put(&bytes, 16, 120, bigEndian: true)
        put(&bytes, 20, 100, bigEndian: true)
        let path = try file("universal", bytes)
        #expect(throws: (any Error).self) { try thinBinary(path) }
        #expect((try Data(contentsOf: path)) == (bytes))
    }
}

final class LogTests: TemporaryTests {
    @Test func testOversizedLogIsTrimmedAndKeepsThreeArchives() throws {
        let path = try file("console.log", Data(repeating: 42, count: 4096))
        let log = RotatingLog(path, limit: 128)
        try log.append(Data(repeating: 65, count: 64))
        #expect((try Data(contentsOf: URL(fileURLWithPath: path.path + ".1")).count) == (128))
        for byte in UInt8(66)...UInt8(80) { try log.append(Data(repeating: byte, count: 64)) }
        for suffix in ["", ".1", ".2", ".3"] { #expect((try Data(contentsOf: URL(fileURLWithPath: path.path + suffix)).count) <= (128)) }
        #expect(!(exists(URL(fileURLWithPath: path.path + ".4"))))
    }
    @Test func testLargeWriteIsSplitIntoBoundedFiles() throws {
        let path = directory.appendingPathComponent("console.log")
        try RotatingLog(path, limit: 128).append(Data(repeating: 1, count: 1024))
        for suffix in ["", ".1", ".2", ".3"] { #expect((try Data(contentsOf: URL(fileURLWithPath: path.path + suffix)).count) == (128)) }
    }
    @Test func testConcurrentWritersKeepCompleteChunks() throws {
        let path = directory.appendingPathComponent("console.log")
        DispatchQueue.concurrentPerform(iterations: 4) { index in
            let log = RotatingLog(path, limit: 128)
            for _ in 0..<30 { #expect(throws: Never.self) { try log.append(Data(repeating: UInt8(index + 1), count: 64)) } }
        }
        for suffix in ["", ".1", ".2", ".3"] {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path.path + suffix))
            #expect((bytes.count) == (128))
            #expect((Set(bytes.prefix(64)).count) == (1))
            #expect((Set(bytes.suffix(64)).count) == (1))
        }
    }
    @Test func testSessionCleanupKeepsNewestFilesAndPreservesSymlinks() throws {
        let logs = directory.appendingPathComponent("logs/Riot Client Logs")
        try makeDirectory(logs)
        for index in 0..<7 {
            let path = logs.appendingPathComponent("\(index).log")
            try Data().write(to: path)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: path.path)
        }
        let external = try file("unrelated.log", Data("preserved".utf8))
        try FileManager.default.createSymbolicLink(at: logs.appendingPathComponent("linked.log"), withDestinationURL: external)
        try pruneLogs(directory)
        #expect((Set(files(logs).map(\.lastPathComponent))) == (["4.log", "5.log", "6.log", "linked.log"]))
        #expect((try readText(external)) == ("preserved"))
    }
}
