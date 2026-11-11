import Foundation
import Darwin
import TFTCore

let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let bundledAssets = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
let assets = exists(bundledAssets.appendingPathComponent("SDKHost")) ? bundledAssets : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
do {
    let configuration = try Configuration(assets: assets)
    if CommandLine.arguments.contains("--self-check") {
        let value: JSON = ["architecture": "arm64", "implementation": "swift", "data_directory": configuration.data.path,
                           "bundled_host": exists(configuration.hostSource), "installed_riot": try configuration.installedRiot().path]
        print(String(decoding: try jsonData(value), as: UTF8.self))
    } else {
        let logger = CommandLine.arguments.contains("--log-output") ? RotatingLog(configuration.data.appendingPathComponent("launcher.log")) : nil
        let runtime = RiotRuntime(configuration, report: { message in
            if let logger { logger.line(message) } else { print(message); fflush(stdout) }
        })
        try Launcher(configuration, runtime: runtime).run()
    }
} catch {
    if CommandLine.arguments.contains("--log-output"), let config = try? Configuration(assets: assets) {
        try? makeDirectory(config.data)
        RotatingLog(config.data.appendingPathComponent("launcher.log")).line(error.localizedDescription)
    }
    fputs(error.localizedDescription + "\n", stderr)
    exit(1)
}
