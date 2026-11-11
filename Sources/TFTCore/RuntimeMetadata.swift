import Foundation

public struct RuntimeMetadata: Codable, Equatable {
    public let address: UInt64
    public let manifest: String?

    public init(address: UInt64, manifest: String? = nil) {
        self.address = address
        self.manifest = manifest
    }

    public static func read(from directory: URL) throws -> RuntimeMetadata {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("runtime.json")))
    }

    public func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try atomicWrite(encoder.encode(self), to: directory.appendingPathComponent("runtime.json"))
    }
}
