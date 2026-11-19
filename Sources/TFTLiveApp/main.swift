import AppKit
import TFTCore

final class LauncherDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum State {
        case idle, preparing, quittingAfterPreparation
    }

    private var window: NSWindow!
    private var status: NSTextField!
    private var progress: NSProgressIndicator!
    private var hint: NSTextField!
    private var state = State.idle
    private var pending = Data()
    private var lastLine = "Setup did not complete."
    private var progressTimer: Timer?
    private var allowsAutomaticProgress = true
    private var presentedAutomatically = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        state == .idle
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        progressTimer?.invalidate()
        progressTimer = nil
        presentedAutomatically = false
        window?.makeKeyAndOrderFront(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        allowsAutomaticProgress = false
        presentedAutomatically = false
        progressTimer?.invalidate()
        progressTimer = nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard state != .idle else { return .terminateNow }
        state = .quittingAfterPreparation
        hint.stringValue = "TFT Live will quit when setup finishes."
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = Bundle.main.url(forResource: "TFTLive", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: icon)
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 178), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "TFT Live"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        status = NSTextField(wrappingLabelWithString: "Preparing Riot Client…")
        status.frame = NSRect(x: 28, y: 69, width: 424, height: 60)
        status.font = .systemFont(ofSize: 14)
        window.contentView?.addSubview(status)
        progress = NSProgressIndicator(frame: NSRect(x: 28, y: 50, width: 424, height: 12))
        progress.style = .bar
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        window.contentView?.addSubview(progress)
        hint = NSTextField(wrappingLabelWithString: "Setup keeps running when you close this window. Open TFT Live again to see progress.")
        hint.frame = NSRect(x: 28, y: 12, width: 424, height: 32)
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        window.contentView?.addSubview(hint)
        // The launcher is an accessory app without a Quit menu item.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "q" else { return event }
            NSApp.terminate(nil)
            return nil
        }
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
            state = .preparing
            DispatchQueue.global(qos: .utility).async {
                while true {
                    let bytes = pipe.fileHandleForReading.availableData
                    if bytes.isEmpty { break }
                    try? log.append(bytes)
                    DispatchQueue.main.async { self.consume(bytes) }
                }
                task.waitUntilExit()
                try? pipe.fileHandleForReading.close()
                DispatchQueue.main.async { self.finish(exitStatus: task.terminationStatus) }
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
            showStatus(line)
        }
    }

    private func showStatus(_ line: String) {
        status.stringValue = line
        if line == Launcher.signInStatus {
            progressTimer?.invalidate()
            progressTimer = nil
            if presentedAutomatically { window.orderOut(nil); presentedAutomatically = false }
        }

        let downloading = line == Launcher.gameUpdateStatus || line.hasPrefix("Updating Riot components, ")
        let percentage = line.hasSuffix(" %") ? line.dropLast(2).split(separator: " ").last.flatMap { Int($0) } : nil
        if let percentage, (0...100).contains(percentage) {
            progress.stopAnimation(nil)
            progress.isIndeterminate = false
            progress.doubleValue = Double(percentage)
            if !downloading { status.stringValue = "Updating TFT, \(percentage) %" }
        } else {
            progress.isIndeterminate = true
            progress.startAnimation(nil)
        }

        guard (downloading || percentage != nil), allowsAutomaticProgress, !window.isVisible,
              state == .preparing, progressTimer == nil else { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.progressTimer = nil
            guard self.state == .preparing, !self.window.isVisible else { return }
            self.presentedAutomatically = true
            self.window.orderFrontRegardless()
        }
    }

    private func finish(exitStatus: Int32) {
        progressTimer?.invalidate()
        progressTimer = nil
        let quitting = state == .quittingAfterPreparation
        state = .idle
        if quitting {
            NSApp.reply(toApplicationShouldTerminate: true)
        } else if exitStatus == 0 {
            NSApp.terminate(nil)
        } else {
            let tail = String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            failure(tail.isEmpty ? lastLine : tail)
        }
    }

    private func failure(_ message: String) {
        progress.stopAnimation(nil)
        progress.isHidden = true
        hint.isHidden = true
        status.stringValue = message
        let button = NSButton(title: "Close", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        button.frame = NSRect(x: 370, y: 15, width: 85, height: 30)
        window.contentView?.addSubview(button)
        window.makeKeyAndOrderFront(nil)
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
