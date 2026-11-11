import Foundation
import CryptoKit
import Darwin

extension RiotRuntime {
    public func wire(_ directory: URL) throws {
        let targets = ["sdk-host-data": data, "sdk-host-system.yaml": data.appendingPathComponent("sdk-host-system.yaml"),
                       "riot-sdk-host-override.json": data.appendingPathComponent("riot-sdk-host-override.json"), "riot-region.txt": data.appendingPathComponent("riot-region.txt")]
        for (name, target) in targets {
            let path = directory.appendingPathComponent(name)
            if isSymlink(path) && resolved(path) != resolved(target) { try remove(path) }
            if !exists(path) && !isSymlink(path) { try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target) }
        }
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
        let marker = current.appendingPathComponent("host.json")
        let installed = try exists(host) ? fileDigest(host) : ""
        let record = (try? readJSON(marker)) ?? [:]
        if text(record["source"]) == source && text(record["installed"]) == installed { return }
        try quit()
        let replacement = URL(fileURLWithPath: host.path + ".new")
        try makeDirectory(host.deletingLastPathComponent())
        try remove(replacement)
        try clone(configuration.hostSource, replacement)
        guard rename(replacement.path, host.path) == 0 else { throw LauncherError("Unable to install the updated Swift host.") }
        try shareInterface(current)
        try atomicJSON(["source": source, "installed": fileDigest(host)], to: marker)
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
    public func prepareRuntime(into destination: URL? = nil, source: URL? = nil) throws -> URL {
        let destination = destination ?? configuration.initialRuntime
        if exists(destination.appendingPathComponent("runtime.json")) { try wire(destination); return destination }
        let installed = try source ?? configuration.installedRiot()
        report("Preparing Apple Silicon components from the installed Riot Client…")
        let stage = data.appendingPathComponent("prepare-" + UUID().uuidString)
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
        try RuntimeMetadata(address: address).write(to: stage)
        try replaceDirectory(stage, destination) { try self.validate(destination, address: address) }
        return destination
    }
    public func ensureHealthy(_ current: URL) throws -> URL {
        let backup = URL(fileURLWithPath: current.path + ".repair-backup")
        if !exists(current) && exists(backup) { try move(backup, current) }
        do {
            try refreshHost(current)
            let address = try RuntimeMetadata.read(from: current).address
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
        let prepared = try prepareRuntime(into: stage, source: source)
        let address = try RuntimeMetadata.read(from: prepared).address
        let previous = try state()
        var manifest = text(previous["manifest"])
        if manifest.isEmpty && matches(current.lastPathComponent, "[A-Fa-f0-9]{16}") {
            manifest = "https://ks-foundation.secure.dyn.riotcdn.net/channels/public/releases/" + current.lastPathComponent + ".manifest"
        }
        if sameVersion && !manifest.isEmpty { try RuntimeMetadata(address: address, manifest: manifest).write(to: prepared) }
        try refreshHost(prepared)
        let destination = sameVersion ? current : configuration.initialRuntime
        try replaceDirectory(prepared, destination) {
            try self.validate(destination, address: address)
            try self.health(destination, address: address)
            if !sameVersion { try self.writeState(["root": destination.path, "manifest": NSNull()]) }
        }
        return destination
    }
}
