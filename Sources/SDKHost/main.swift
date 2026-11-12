import AppKit
import Darwin
import MachO
import TFTCore

typealias RiotRun = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
typealias PlatformGetter = @convention(c) () -> UnsafePointer<CChar>?

func runHost() throws -> Int32 {
    let root = resolved(Bundle.main.bundleURL).deletingLastPathComponent()
    let sdk = root.appendingPathComponent("sdk-windows-override-arm64/RiotGamesApi.framework/RiotGamesApi")
    let riot = root.appendingPathComponent(riotAppName)
    let data = resolved(root.appendingPathComponent("sdk-host-data"))
    let arguments = CommandLine.arguments
    let checking = arguments.count == 3 && arguments[1] == "--check-sdk"
    if !checking { try captureConsole(data.appendingPathComponent("host-console.log"), executable: URL(fileURLWithPath: arguments[0])) }
    guard dlopen(sdk.path, RTLD_NOW | RTLD_GLOBAL) != nil else {
        throw LauncherError("SDK load failed. " + String(cString: dlerror()))
    }
    guard let foundation = dlopen(riot.appendingPathComponent("Contents/Frameworks/libRiotClientFoundation.dylib").path, RTLD_NOW | RTLD_GLOBAL) else {
        throw LauncherError("Foundation load failed. " + String(cString: dlerror()))
    }
    guard let symbol = dlsym(foundation, "Run") else { throw LauncherError("Foundation Run entry point missing.") }
    if checking {
        guard let offset = UInt(arguments[2], radix: 16), offset <= UInt(Int.max) else { throw LauncherError("Invalid SDK address.") }
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index), String(cString: name).contains("RiotGamesApi.framework/RiotGamesApi"),
                  let header = _dyld_get_image_header(index) else { continue }
            let getter = unsafeBitCast(UnsafeRawPointer(header).advanced(by: Int(offset)), to: PlatformGetter.self)
            guard let value = getter() else { throw LauncherError("The SDK returned no platform.") }
            let platform = String(cString: value)
            print(platform)
            return platform == "windows" ? 0 : 1
        }
        throw LauncherError("The SDK image was not loaded.")
    }
    var settings = arguments + [
        "--disable-launch-agent", "--app-root=" + riot.path,
        "--user-data-root=" + data.appendingPathComponent("user").path,
        "--data-root=" + data.appendingPathComponent("shared").path,
        "--log-root=" + data.appendingPathComponent("logs").path,
        "--update-root=" + data.appendingPathComponent("update").path,
        "--system-yaml-override=" + resolved(root.appendingPathComponent("sdk-host-system.yaml")).path,
        "--persistence-path=" + data.appendingPathComponent("sdk").path,
        "--client-config-override-file=" + resolved(root.appendingPathComponent("riot-sdk-host-override.json")).path
    ]
    if let region = try? readText(root.appendingPathComponent("riot-region.txt")).trimmingCharacters(in: .whitespacesAndNewlines), !region.isEmpty {
        settings.append("--region=" + region)
    }
    var pointers = settings.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    pointers.append(nil)
    let application = NSApplication.shared
    if let icon = Bundle.main.url(forResource: "TFTLive", withExtension: "icns") {
        application.applicationIconImage = NSImage(contentsOf: icon)
    }
    let run = unsafeBitCast(symbol, to: RiotRun.self)
    return pointers.withUnsafeMutableBufferPointer { run(Int32(settings.count), $0.baseAddress) }
}

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--console-relay" {
    relayConsole(URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}

let status: Int32 = autoreleasepool {
    do { return try runHost() }
    catch { fputs(error.localizedDescription + "\n", stderr); return 1 }
}
exit(status)
