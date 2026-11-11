import AppKit
import TFTCore

final class LauncherDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var status: NSTextField!
    private var progress: NSProgressIndicator!
    private var process: Process?
    private var pending = Data()
    private var lastLine = "Setup did not complete."

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = Bundle.main.url(forResource: "TFTLive", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: icon)
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 155), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "TFT Live"
        window.center()
        status = NSTextField(wrappingLabelWithString: "Preparing Riot Client…")
        status.frame = NSRect(x: 28, y: 48, width: 424, height: 60)
        status.font = .systemFont(ofSize: 14)
        window.contentView?.addSubview(status)
        progress = NSProgressIndicator(frame: NSRect(x: 28, y: 24, width: 424, height: 12))
        progress.style = .bar
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        window.contentView?.addSubview(progress)
        window.makeKeyAndOrderFront(nil)
        do {
            let configuration = try Configuration(assets: Bundle.main.resourceURL!)
            try makeDirectory(configuration.data)
            let log = RotatingLog(configuration.data.appendingPathComponent("launcher.log"))
            try log.append(Data())
            let task = Process()
            task.executableURL = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("TFTLiveCLI")
            task.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            try task.run()
            process = task
            DispatchQueue.global(qos: .utility).async { [weak self] in
                while true {
                    let bytes = pipe.fileHandleForReading.availableData
                    if bytes.isEmpty { break }
                    try? log.append(bytes)
                    DispatchQueue.main.async { self?.consume(bytes) }
                }
                task.waitUntilExit()
                try? pipe.fileHandleForReading.close()
                DispatchQueue.main.async {
                    if task.terminationStatus == 0 { NSApp.terminate(nil) }
                    else { self?.failure(self?.lastLine ?? "Setup did not complete.") }
                }
            }
        } catch { failure(error.localizedDescription) }
    }
    private func consume(_ bytes: Data) {
        pending.append(bytes)
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending.prefix(upTo: newline), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(...newline)
            if line.isEmpty { continue }
            lastLine = line
            if ["Preparing", "Repairing", "Sign in", "Closing", "Live version", "Installing", "Updating", "Update complete", "New Riot components", "Riot is ready"].contains(where: line.hasPrefix) || line.hasSuffix(" %") {
                status.stringValue = line
            }
        }
        if !pending.isEmpty { lastLine = String(decoding: pending, as: UTF8.self) }
    }
    private func failure(_ message: String) {
        progress.stopAnimation(nil)
        progress.isHidden = true
        status.stringValue = message
        let button = NSButton(title: "Close", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        button.frame = NSRect(x: 370, y: 15, width: 85, height: 30)
        window.contentView?.addSubview(button)
        NSApp.activate(ignoringOtherApps: true)
    }
}

if CommandLine.arguments.contains("--self-check") {
    let process = Process()
    process.executableURL = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("TFTLiveCLI")
    process.arguments = ["--self-check"]
    do { try process.run(); process.waitUntilExit(); exit(process.terminationStatus) }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
let app = NSApplication.shared
let delegate = LauncherDelegate()
app.delegate = delegate
app.run()
