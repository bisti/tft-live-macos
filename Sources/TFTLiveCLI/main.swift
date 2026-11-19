import Foundation
import Darwin
import TFTCore

let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let bundledAssets = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let launchedByApp = arguments == ["--gui"]
    try require(arguments.isEmpty || arguments == ["--self-check"] || launchedByApp, "Usage: TFTLiveCLI [--self-check]")
    try require(exists(bundledAssets.appendingPathComponent("SDKHost")), "Run TFT Live.app or build it with ./build.sh.")
    let configuration = try Configuration(assets: bundledAssets)
    if arguments == ["--self-check"] {
        let value: JSON = ["architecture": "arm64", "implementation": "swift", "data_directory": configuration.data.path,
                           "installed_riot": try configuration.installedRiot().path]
        print(String(decoding: try jsonData(value), as: UTF8.self))
    } else {
        let runtime = RiotRuntime(configuration, checkCancellation: {
            guard launchedByApp else { return }
            // The app keeps stdin open without writing. Closing it requests cancellation.
            var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            if poll(&input, 1, 0) > 0 { throw PreparationCancelled() }
        })
        try Launcher(configuration, runtime: runtime).run()
    }
} catch is PreparationCancelled {
    print("TFT preparation cancelled.")
    exit(0)
} catch {
    fputs(error.localizedDescription + "\n", stderr)
    exit(1)
}
