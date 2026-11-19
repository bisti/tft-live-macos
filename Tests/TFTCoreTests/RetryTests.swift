import Darwin
import Foundation
import Testing
@testable import TFTCore

final class RuntimeRetryTests: TemporaryTests {
    private let manifest = "https://ks-foundation.secure.dyn.riotcdn.net/channels/public/releases/1234567890ABCDEF.manifest"

    private var current: URL { resolved(directory.appendingPathComponent("seed")) }
    private var candidate: URL { resolved(directory.appendingPathComponent("runtimes/1234567890ABCDEF")) }

    private func runtime(fetch: ((URL) throws -> JSON)? = nil) throws -> RiotRuntime {
        let info = try PropertyListSerialization.data(fromPropertyList: ["FileVersion": "1"], format: .xml, options: 0)
        _ = try file("seed/" + riotAppName + "/Contents/Info.plist", info)
        let configuration = try Configuration(assets: directory, data: directory)
        return RiotRuntime(configuration, api: { _, _, _, _ in HTTPResult(0) },
                           fetch: fetch ?? { _ in ["keystone.self_update.manifest_url": self.manifest] }, report: { _ in })
    }

    private func pending(_ runtime: RiotRuntime) throws {
        try runtime.writeState(["root": candidate.path, "manifest": manifest, "pending": true,
                                "previous_root": current.path, "previous_manifest": NSNull()])
    }

    @Test func legacyRejectionDoesNotDelayTheSameManifest() throws {
        let runtime = try runtime()
        try runtime.writeState(["root": current.path, "rejected_manifest": manifest, "rejected_at": Date().timeIntervalSince1970])
        let selected = try runtime.ensureRuntime { root, offered in
            #expect(root == current)
            #expect(offered == manifest)
            return candidate
        }
        #expect(selected == candidate)
        #expect(try runtime.state()["pending"] as? Bool == true)
    }

    @Test func diskAndInstallationFailuresCanRetryTheSameManifest() throws {
        let runtime = try runtime()
        let errors: [any Error] = [
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
            LauncherError("The Riot runtime download failed."),
            LauncherError("codesign failed.")
        ]
        for error in errors {
            let selected = try runtime.ensureRuntime { _, _ in throw error }
            #expect(selected == current)
            #expect(try runtime.state().isEmpty)
        }
        #expect(try runtime.ensureRuntime { _, _ in candidate } == candidate)
    }

    @Test func networkFailureCanRetryTheSameManifest() throws {
        var unavailable = true
        let runtime = try runtime { _ in
            if unavailable { throw URLError(.notConnectedToInternet) }
            return ["keystone.self_update.manifest_url": self.manifest]
        }
        #expect(try runtime.ensureRuntime { _, _ in
            Issue.record("A candidate was prepared without retrieving the manifest.")
            return candidate
        } == current)
        unavailable = false
        #expect(try runtime.ensureRuntime { _, _ in candidate } == candidate)
    }

    @Test func signInFailureRollsBackAndAllowsAnotherAttempt() throws {
        let runtime = try runtime()
        try pending(runtime)
        var attempts: [URL] = []
        let running = try runtime.finishSetup(candidate, prepare: { root in
            attempts.append(root)
            if root == candidate { throw LauncherError("Riot sign-in is still pending.") }
            return true
        }, restore: { $0 })
        #expect(running)
        #expect(attempts == [candidate, current])
        #expect(try runtime.selectedRoot(runtime.state()) == current)
        #expect(try runtime.ensureRuntime { _, _ in candidate } == candidate)
    }

    @Test func interruptedActivationKeepsThePreviousRuntimeUntilTheNextAttempt() throws {
        let runtime = try runtime()
        try pending(runtime)
        let restored = try runtime.ensureRuntime { _, _ in
            Issue.record("An interrupted update was retried before the restored runtime could finish setup.")
            return candidate
        }
        #expect(restored == current)
        #expect(try runtime.state()["pending"] == nil)
        #expect(try runtime.state()["manifest"] is NSNull)
        let selected = try runtime.ensureRuntime { root, offered in
            #expect(root == current)
            #expect(offered == manifest)
            return candidate
        }
        #expect(selected == candidate)
        #expect(try runtime.state()["pending"] as? Bool == true)
    }

    @Test func deterministicIncompatibilityDefersOnlyTheSameManifestAndExpires() throws {
        let runtime = try runtime()
        let sdk = try file("RiotGamesApi", syntheticSDK(duplicate: true))
        let first = try runtime.ensureRuntime { _, _ in
            _ = try patchWindowsSDK(sdk)
            return candidate
        }
        #expect(first == current)
        var state = try runtime.state()
        #expect(text(state["incompatible_manifest"]) == manifest)
        #expect(try runtime.ensureRuntime { _, _ in
            Issue.record("An incompatible manifest was retried during its delay.")
            return candidate
        } == current)

        let otherIdentifier = "1234567890ABCDF0"
        let otherManifest = manifest.replacingOccurrences(of: "1234567890ABCDEF", with: otherIdentifier)
        let otherCandidate = resolved(directory.appendingPathComponent("runtimes/" + otherIdentifier))
        let otherRuntime = try self.runtime { _ in ["keystone.self_update.manifest_url": otherManifest] }
        #expect(try otherRuntime.ensureRuntime { _, _ in otherCandidate } == otherCandidate)

        state["incompatible_at"] = Date().timeIntervalSince1970 - 86_401
        try runtime.writeState(state)
        #expect(try runtime.ensureRuntime { _, _ in candidate } == candidate)
    }
}
