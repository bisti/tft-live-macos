import Foundation
import Testing
@testable import TFTCore

final class DiagnosticTests: TemporaryTests {
    private func configuration() throws -> Configuration {
        let assets = repository.appendingPathComponent("Resources")
        try clone(assets.appendingPathComponent("riot-sdk-host-override.json"),
                  directory.appendingPathComponent("riot-sdk-host-override.json"))
        return try Configuration(assets: assets, data: directory)
    }

    @Test func selectionSnapshotPreservesItsFormatWithoutFlaggingAConfigurationChange() throws {
        let config = try configuration()
        let region = try regionSettings("EUW1", configuration: regionalConfiguration())
        #expect(try config.configureRegion(region, manifest: "selected-manifest", version: "first-version"))
        #expect(try !config.configureRegion(region, manifest: "selected-manifest", version: "new-version"))

        let path = directory.appendingPathComponent("selection.json")
        let snapshot = try readJSON(path)
        let expected: JSON = ["region": "EUW1", "version_set": "live-EUW1", "client_region": "EUW",
                              "aliases": ["EUW", "EUW1"], "manifest": "selected-manifest", "version": "new-version"]
        #expect(try jsonData(snapshot) == jsonData(expected))
    }

    @Test func unavailableSelectionSnapshotReportsTheErrorAndKeepsTheConfiguration() throws {
        let config = try configuration()
        let region = try regionSettings("KR", configuration: regionalConfiguration())
        let existing = try file("selection.json/keep", Data("preserve".utf8))
        var reports: [String] = []

        #expect(try config.configureRegion(region, manifest: "selected-manifest", version: "selected-version") { reports.append($0) })
        #expect(reports.count == 1)
        #expect(reports.first?.contains("selection.json") == true)
        #expect(try readText(existing) == "preserve")
        #expect(try readText(directory.appendingPathComponent("riot-region.txt")) == "KR\n")
        let override = try readJSON(directory.appendingPathComponent("riot-sdk-host-override.json"))
        let product = object(object(override["public"])[liveProduct])
        let mac = object(object(product["platforms"])["mac"])
        #expect(text(objects(mac["configurations"]).first?["patch_url"]) == "selected-manifest")
    }

    @Test func requiredRegionWriteFailureStillThrows() throws {
        let config = try configuration()
        let region = try regionSettings("KR", configuration: regionalConfiguration())
        _ = try file("riot-region.txt/keep")

        #expect(throws: (any Error).self) {
            try config.configureRegion(region, manifest: "selected-manifest", version: "selected-version") { _ in
                Issue.record("The diagnostic snapshot should follow successful configuration writes.")
            }
        }
        #expect(!exists(directory.appendingPathComponent("selection.json")))
    }
}
