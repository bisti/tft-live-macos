import Foundation
import Darwin
import TFTCore

let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let bundledAssets = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
let logOutput = CommandLine.arguments.contains("--log-output")

func appendLog(_ message: String, to log: RotatingLog) -> Bool {
    do {
        try log.append(Data((message + "\n").utf8))
        return true
    } catch {
        fputs("Unable to write \(log.path.path): \(error.localizedDescription)\n", stderr)
        return false
    }
}

do {
    try require(exists(bundledAssets.appendingPathComponent("SDKHost")), "Run TFT Live.app or build it with ./build.sh.")
    let configuration = try Configuration(assets: bundledAssets)
    if CommandLine.arguments.contains("--self-check") {
        let value: JSON = ["architecture": "arm64", "implementation": "swift", "data_directory": configuration.data.path,
                           "bundled_host": exists(configuration.hostSource), "installed_riot": try configuration.installedRiot().path]
        print(String(decoding: try jsonData(value), as: UTF8.self))
    } else {
        let logger = logOutput ? RotatingLog(configuration.data.appendingPathComponent("launcher.log")) : nil
        let runtime = RiotRuntime(configuration, report: { message in
            if let logger, appendLog(message, to: logger) { return }
            print(message)
            fflush(stdout)
        })
        try Launcher(configuration, runtime: runtime).run()
    }
} catch {
    if logOutput, let config = try? Configuration(assets: bundledAssets) {
        let message = error.localizedDescription
        do {
            try makeDirectory(config.data)
            _ = appendLog(message, to: RotatingLog(config.data.appendingPathComponent("launcher.log")))
        } catch {
            fputs("Unable to create the log directory \(config.data.path): \(error.localizedDescription)\n", stderr)
        }
    }
    fputs(error.localizedDescription + "\n", stderr)
    exit(1)
}
