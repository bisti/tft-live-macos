import Testing
import Foundation
@testable import TFTCore
import Darwin

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

class TemporaryTests {
    var directory: URL!
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tft-swift-tests-" + UUID().uuidString)
        try makeDirectory(directory)
    }
    deinit { try? remove(directory) }
    func file(_ name: String, _ data: Data = Data()) throws -> URL {
        let path = directory.appendingPathComponent(name)
        try makeDirectory(path.deletingLastPathComponent())
        try data.write(to: path)
        return path
    }
}

final class SupportTests: TemporaryTests {
    @Test func testAtomicJSONRetainsNullAndUnicode() throws {
        let path = directory.appendingPathComponent("state.json")
        try atomicJSON(["value": "聯盟", "empty": NSNull()], to: path)
        #expect((text(try readJSON(path)["value"])) == ("聯盟"))
        #expect(try readJSON(path)["empty"] is NSNull)
    }
    @Test func testDirectoryReplacementRollsBackAfterFailedValidation() throws {
        let original = try file("current/resource", Data("old".utf8)).deletingLastPathComponent()
        let staged = try file("staged/resource", Data("new".utf8)).deletingLastPathComponent()
        #expect(throws: (any Error).self) { try replaceDirectory(staged, original) { throw LauncherError("verification failed") } }
        #expect((try readText(original.appendingPathComponent("resource"))) == ("old"))
        #expect(!(exists(URL(fileURLWithPath: original.path + ".repair-backup"))))
    }
    @Test func testDirectoryReplacementPublishesValidatedContent() throws {
        let original = try file("current/resource", Data("old".utf8)).deletingLastPathComponent()
        let staged = try file("staged/resource", Data("new".utf8)).deletingLastPathComponent()
        try replaceDirectory(staged, original) {
            let contents = try readText(original.appendingPathComponent("resource"))
            #expect(contents == "new")
        }
        #expect(!(exists(URL(fileURLWithPath: original.path + ".repair-backup"))))
    }
    @Test func testInterruptedDirectoryReplacementRecoversItsBackup() throws {
        let original = directory.appendingPathComponent("current")
        _ = try file("current.repair-backup/resource", Data("old".utf8))
        let staged = try file("staged/resource", Data("new".utf8)).deletingLastPathComponent()
        #expect(throws: (any Error).self) { try replaceDirectory(staged, original) { throw LauncherError("failed") } }
        #expect((try readText(original.appendingPathComponent("resource"))) == ("old"))
    }
    @Test func testCommandTimeoutStopsTheChild() throws {
        let start = monotonic()
        let result = try command(["/bin/sleep", "5"], checked: false, timeout: 0.1)
        #expect((result.status) != (0))
        #expect((monotonic() - start) < (2))
    }
    @Test func commandKeepsDiagnosticsSeparateFromItsOutput() throws {
        let result = try command(["/bin/sh", "-c", "printf standard; printf diagnostic >&2"])
        #expect(result.output == "standard")
        #expect(result.errorOutput == "diagnostic")
    }
    @Test func testClonePreservesExecutablePermissions() throws {
        let source = try file("source", Data("code".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        let destination = directory.appendingPathComponent("nested/clone")
        try clone(source, destination)
        #expect((try Data(contentsOf: source)) == (try Data(contentsOf: destination)))
        #expect((access(destination.path, X_OK)) == (0))
    }
    @Test func testPathContainmentUsesResolvedPaths() throws {
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/Applications"))
        #expect(!(isInside(link.appendingPathComponent("other"), directory)))
        #expect(isInside(directory.appendingPathComponent("nested/file"), directory))
    }
}

func regionalConfiguration() -> JSON {
    let aliases = ["EUW1": ["EUW", "EUW1"], "NA1": ["NA", "NA1"], "KR": ["KR"], "NEW1": ["NEW1"]]
    return [liveProduct: ["platforms": ["win": ["configurations": aliases.map { ["id": $0.key, "region_data": ["available_regions": $0.value]] as JSON }]]],
            "tft.client_settings.version_sets": Dictionary(uniqueKeysWithValues: aliases.keys.map { ($0, "live-" + $0) })]
}

final class RegionTests: TemporaryTests {
    @Test func testAccountRegionTakesPrecedenceOverCountry() throws {
        #expect((try decodeUserRegion(["country": "FR", "region": "EU", "lol": ["cpid": "KR"]])) == ("KR"))
    }
    @Test func testSingleActiveRegionIsSupported() throws {
        #expect((try decodeUserRegion(["lol_region": [["cpid": "KR", "active": false], ["cpid": "NA1", "active": true]]])) == ("NA1"))
    }
    @Test func testJSONEncodedUserInfoIsSupported() throws {
        #expect((try decodeUserRegion("{\"lol\":{\"cpid\":\"EUW1\"}}")) == ("EUW1"))
    }
    @Test func testMissingAndAmbiguousRegionsFail() {
        for user: JSON in [["country": "US"], ["lol_region": [["cpid": "KR", "active": true], ["cpid": "NA1", "active": true]]]] {
            #expect(throws: (any Error).self) { try decodeUserRegion(user) }
        }
    }
    @Test func testAliasesAndNewRegionsComeFromRiotConfiguration() throws {
        for region in ["EUW1", "NA1", "KR", "NEW1"] { #expect((try regionSettings(region, configuration: regionalConfiguration()).id) == (region)) }
        #expect((try regionSettings("EUW", configuration: regionalConfiguration()).id) == ("EUW1"))
    }
    @Test func testUnknownRegionIsRejected() { #expect(throws: (any Error).self) { try regionSettings("MISSING", configuration: regionalConfiguration()) } }
    @Test func testAbsentLiveChannelIsRejected() {
        var config = regionalConfiguration()
        config["tft.client_settings.version_sets"] = ["KR": "pbe-KR"]
        #expect(throws: (any Error).self) { try regionSettings("KR", configuration: config) }
    }
    @Test func testOverrideReplacesManifestAndRegionalConfiguration() throws {
        let config = try Configuration(assets: repository, data: directory)
        try clone(repository.appendingPathComponent("riot-sdk-host-override.json"), directory.appendingPathComponent("riot-sdk-host-override.json"))
        let region = try regionSettings("KR", configuration: regionalConfiguration())
        #expect(try config.configureRegion(region, manifest: "new-manifest", version: "new-version"))
        #expect(!(try config.configureRegion(region, manifest: "new-manifest", version: "new-version")))
        let product = object(object(try readJSON(directory.appendingPathComponent("riot-sdk-host-override.json"))["public"])[liveProduct])
        #expect((object(product["metadata"])["mac"]) == nil)
        #expect((object(object(product["metadata"])["default"])["product_dependency"]) == nil)
        for platform in object(product["platforms"]).values {
            let entries = objects(object(platform)["configurations"])
            #expect((text(entries.first?["id"])) == ("KR"))
            #expect((text(entries.first?["patch_url"])) == ("new-manifest"))
        }
    }
    @Test func testSavedGamePathIsReusedAndRelativePathsFail() throws {
        let config = try Configuration(assets: repository, data: directory)
        try atomicJSON(["game_path": directory.appendingPathComponent("Game.app").path], to: directory.appendingPathComponent("install.json"))
        #expect((try config.gamePath()) == (directory.appendingPathComponent("Game.app")))
        try atomicJSON(["game_path": "relative/Game.app"], to: directory.appendingPathComponent("install.json"))
        #expect(throws: (any Error).self) { try config.gamePath() }
    }
    @Test func testLatestCachedRegionConfigurationIsSelected() throws {
        let path = directory.appendingPathComponent("user/Config/ClientConfiguration.json")
        try makeDirectory(path.deletingLastPathComponent())
        var latest = regionalConfiguration()
        latest["marker"] = "latest"
        try atomicJSON(["public": [["updateTime": 1, "data": regionalConfiguration()], ["updateTime": 2, "data": latest]]], to: path)
        #expect((text(try Configuration(assets: repository, data: directory).cachedConfiguration()?["marker"])) == ("latest"))
    }
}

func publication(_ platform: String = "macos", version: String = "live-version") -> JSON {
    ["release": ["labels": ["riot:platform": ["values": [platform]], "riot:artifact_type_id": ["values": ["client"]],
                             "riot:artifact_version_id": ["values": [version]]]],
     "compat_version": ["id": version],
     "download": ["url": "https://teamfighttactics.secure.dyn.riotcdn.net/channels/public/releases/1234567890ABCDEF.manifest"]]
}

final class PublicationTests: TemporaryTests {
    @Test func testPublishedQueriesSelectTheRequestedPlatformAndChannel() throws {
        let release = try publishedRelease(platform: "macos", channel: "live-KR") { url in
            #expect(url.absoluteString.contains("live-KR"))
            #expect(url.absoluteString.contains("q%5Bpublished%5D=true"))
            return ["releases": [publication()]]
        }
        #expect((release.version) == ("live-version"))
    }
    @Test func testEmptyAndAmbiguousPublicationsFail() {
        for entries in [[JSON](), [publication(), publication()]] {
            #expect(throws: (any Error).self) { try publishedRelease(platform: "macos", channel: "live-KR") { _ in ["releases": entries] } }
        }
    }
    @Test func testWrongPlatformAndCompatibilityVersionFail() {
        var inconsistent = publication()
        inconsistent["compat_version"] = ["id": "different"]
        for entry in [publication("windows"), inconsistent] {
            #expect(throws: (any Error).self) { try publishedRelease(platform: "macos", channel: "live-KR") { _ in ["releases": [entry]] } }
        }
    }
    @Test func testForeignAndPrivateManifestsFail() {
        for download: JSON in [["url": "https://example.com/1234567890ABCDEF.manifest"],
                               ["url": object(publication()["download"])["url"]!, "scd_required": true]] {
            var value = publication()
            value["download"] = download
            #expect(throws: (any Error).self) { try publishedRelease(platform: "macos", channel: "live-KR") { _ in ["releases": [value]] } }
        }
    }
    @Test func testInvalidChannelFailsBeforeMakingARequest() {
        #expect(throws: (any Error).self) { try publishedRelease(platform: "macos", channel: "pbe-KR") { _ in Issue.record("Unexpected request"); return [:] } }
    }
    @Test func testMismatchedMacAndWindowsReleasesFail() throws {
        let config = try Configuration(assets: repository, data: directory)
        let runtime = RiotRuntime(config, api: { _, _, _, _ in HTTPResult(0) }, fetch: { url in
            ["releases": [publication(url.absoluteString.contains("=windows") ? "windows" : "macos", version: url.absoluteString.contains("=windows") ? "new" : "old")]]
        })
        let region = try regionSettings("KR", configuration: regionalConfiguration())
        #expect(throws: (any Error).self) { try Launcher(config, runtime: runtime).liveRelease(region) }
    }
}

final class RuntimeStateTests: TemporaryTests {
    var manager: RiotRuntime!
    var current: URL!
    var candidate: URL!
    override init() throws {
        try super.init()
        manager = RiotRuntime(try Configuration(assets: repository, data: directory), api: { _, _, _, _ in HTTPResult(0) }, report: { _ in })
        current = directory.appendingPathComponent("bootstrap")
        candidate = directory.appendingPathComponent("runtimes/1234567890ABCDEF")
        try makeDirectory(current)
        try makeDirectory(candidate)
    }
    func pending() throws {
        try manager.writeState(["root": candidate.path, "manifest": "new", "pending": true, "previous_root": current.path, "previous_manifest": "old"])
    }
    @Test func testRollbackRestoresThePreviousVersionAndRejectsTheCandidate() throws {
        try pending()
        #expect((try manager.rollback()) == (resolved(current)))
        #expect((text(try manager.state()["manifest"])) == ("old"))
        #expect((text(try manager.state()["rejected_manifest"])) == ("new"))
    }
    @Test func testInvalidRuntimeRootIsRejected() {
        #expect(throws: (any Error).self) { try manager.selectedRoot(["root": "/Applications"]) }
        #expect(throws: (any Error).self) { try manager.selectedRoot(["root": directory.appendingPathComponent("runtimes/../../escape").path]) }
    }
    @Test func testConfirmationWaitsUntilPreparationCompletes() throws {
        try pending()
        let running = try manager.finishSetup(candidate, prepare: { root in
            #expect((root) == (self.candidate))
            let pending = try self.manager.state()["pending"] as? Bool
            #expect(pending == true)
            return false
        }, restore: { $0 })
        #expect(!running)
        #expect((try manager.state()["pending"] as? Bool) == (false))
    }
    @Test func testPreparationFailureRestoresAndRetriesThePreviousVersion() throws {
        try pending()
        var calls: [URL] = []
        _ = try manager.finishSetup(candidate, prepare: { root in
            calls.append(resolved(root))
            if root == self.candidate { throw LauncherError("TFT preparation failed") }
            return false
        }, restore: { $0 })
        #expect((calls) == ([resolved(candidate), resolved(current)]))
        #expect((text(try manager.state()["root"])) == (current.path))
    }
    @Test func testTwoPreparationFailuresLeaveTheRestoredStateUnconfirmed() throws {
        try pending()
        #expect(throws: (any Error).self) { try manager.finishSetup(candidate, prepare: { _ in throw LauncherError("failed") }, restore: { $0 }) }
        #expect((text(try manager.state()["root"])) == (current.path))
        #expect((try manager.state()["pending"]) == nil)
    }
    @Test func testRunningGamePreventsShutdown() throws {
        let runtime = RiotRuntime(try Configuration(assets: repository, data: directory), api: { method, _, _, _ in
            #expect((method) == ("GET"))
            return HTTPResult(200, ["game": ["productId": "teamfighttactics"]])
        })
        #expect(throws: (any Error).self) { try runtime.quit() }
    }
    @Test func testConfigurationLinksMoveToTheNewProfile() throws {
        try manager.wire(current)
        let other = try Configuration(assets: repository, data: directory.appendingPathComponent("new-profile"))
        try RiotRuntime(other).wire(current)
        #expect((resolved(current.appendingPathComponent("sdk-host-data"))) == (resolved(other.data)))
    }
    @Test func testCleanupRetainsCurrentAndPreviousAndRemovesObsoleteBootstrap() throws {
        let previous = directory.appendingPathComponent("runtimes/previous")
        for root in [current!, previous, candidate!] {
            try makeDirectory(root.appendingPathComponent(hostRelativePath).deletingLastPathComponent())
            try Data().write(to: root.appendingPathComponent(hostRelativePath))
            try atomicJSON([:], to: root.appendingPathComponent("sdk-ready.json"))
        }
        try manager.writeState(["root": candidate.path, "previous_root": previous.path, "pending": false])
        try manager.confirm()
        #expect(!(exists(current)))
        #expect(exists(previous))
        #expect(exists(candidate))
    }
    @Test func testFingerprintDetectsMissingAndModifiedResources() throws {
        for name in [riotAppName, "sdk-windows-override-arm64/RiotGamesApi.framework", "TFT SDK Host arm64.app"] {
            try makeDirectory(current.appendingPathComponent(name))
            try Data("original".utf8).write(to: current.appendingPathComponent(name + "/resource"))
        }
        let before = try manager.fingerprint(current)
        try Data("modified".utf8).write(to: current.appendingPathComponent(riotAppName + "/resource"))
        #expect((before) != (try manager.fingerprint(current)))
        try remove(current.appendingPathComponent("sdk-windows-override-arm64"))
        #expect(throws: (any Error).self) { try manager.fingerprint(current) }
    }
    @Test func sharedInterfacePreservesBundleLayoutThroughDirectoryAliases() throws {
        let source = try file("source/Contents/Info.plist", Data("info".utf8)).deletingLastPathComponent().deletingLastPathComponent()
        _ = try file("source/Contents/MacOS/UI", Data("binary".utf8))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("Current"), withDestinationURL: source.appendingPathComponent("Contents"))
        let destination = directory.appendingPathComponent("shared")
        try manager.copySharedTree(source, destination)
        #expect(try readText(destination.appendingPathComponent("Contents/Info.plist")) == "info")
        #expect(try readText(destination.appendingPathComponent("Contents/MacOS/UI")) == "binary")
        #expect(isSymlink(destination.appendingPathComponent("Current")))
    }
}
