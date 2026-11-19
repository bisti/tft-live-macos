import Foundation
import Darwin
import TFTCore

let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let bundledAssets = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    try require(arguments.isEmpty || arguments == ["--self-check"], "Usage: TFTLiveCLI [--self-check]")
    try require(exists(bundledAssets.appendingPathComponent("SDKHost")), "Run TFT Live.app or build it with ./build.sh.")
    let configuration = try Configuration(assets: bundledAssets)
    if arguments == ["--self-check"] {
        let value: JSON = ["architecture": "arm64", "implementation": "swift", "data_directory": configuration.data.path,
                           "bundled_host": exists(configuration.hostSource), "installed_riot": try configuration.installedRiot().path]
        print(String(decoding: try jsonData(value), as: UTF8.self))
    } else {
        try Launcher(configuration).run()
    }
} catch {
    fputs(error.localizedDescription + "\n", stderr)
    exit(1)
}
