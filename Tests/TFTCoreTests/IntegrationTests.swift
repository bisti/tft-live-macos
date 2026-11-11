import Foundation
import Testing
@testable import TFTCore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["TFT_NATIVE_INTEGRATION"] == "1"))
final class IntegrationTests: TemporaryTests {
    @Test func nativePreparationRepairAndRuntimeDownload() throws {
        let config = try Configuration(assets: repository.appendingPathComponent("dist/TFT Live.app/Contents/Resources"), data: directory)
        try config.prepareFiles()
        let runtime = RiotRuntime(config)
        let source = try config.installedRiot()
        let current = try runtime.prepareRuntime(source: source)
        try runtime.writeState(["root": current.path])
        let address = try RuntimeMetadata.read(from: current).address
        try runtime.validate(current, address: address)
        let sentinel = directory.appendingPathComponent("user/sentinel")
        try makeDirectory(sentinel.deletingLastPathComponent())
        try writeText("preserved", to: sentinel)
        try remove(current.appendingPathComponent("sdk-windows-override-arm64"))
        try remove(current.appendingPathComponent("TFT SDK Host arm64.app/Contents/Frameworks/Riot Client.app"))
        let repaired = try runtime.ensureHealthy(current)
        #expect(try readText(sentinel) == "preserved")
        #expect(exists(repaired.appendingPathComponent("sdk-windows-override-arm64/RiotGamesApi.framework/RiotGamesApi")))
        let ui = repaired.appendingPathComponent(riotAppName + "/Contents/Frameworks/Riot Client.app/Contents/MacOS/Riot Client")
        let shared = repaired.appendingPathComponent("TFT SDK Host arm64.app/Contents/Frameworks/Riot Client.app/Contents/MacOS/Riot Client")
        let originalInfo = try FileManager.default.attributesOfItem(atPath: ui.path)
        let sharedInfo = try FileManager.default.attributesOfItem(atPath: shared.path)
        #expect((originalInfo[.systemFileNumber] as? NSNumber) == (sharedInfo[.systemFileNumber] as? NSNumber))
        _ = try runtime.ensureHealthy(repaired)
        let process = try runtime.spawn(repaired.appendingPathComponent(hostRelativePath), arguments: ["--headless"])
        defer {
            try? runtime.quit()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let deadline = monotonic() + 60
        while runtime.api("GET", sessionRoute, nil, config.lockfile).status != 200 && process.isRunning && monotonic() < deadline { pause(0.5) }
        #expect(runtime.api("GET", sessionRoute, nil, config.lockfile).status == 200)
        try runtime.quit()
        let region = try regionSettings("NA1", configuration: runtime.officialConfiguration(repaired))
        let release = try Launcher(config, runtime: runtime).liveRelease(region)
        try config.configureRegion(region, manifest: release.manifest, version: release.version)
        let manifest = try runtime.officialManifest(repaired)
        let stage = directory.appendingPathComponent("download-test")
        try makeDirectory(stage)
        let downloaded = try runtime.downloadRuntime(current: repaired, stage: stage, manifest: manifest)
        #expect(exists(downloaded.appendingPathComponent("Contents/Info.plist")))
        #expect(isSymlink(stage.appendingPathComponent(riotAppName)))
        print("Native preparation, missing SDK/UI repair, headless startup and live Riot runtime download verified.")
        pause(2)
    }
}
