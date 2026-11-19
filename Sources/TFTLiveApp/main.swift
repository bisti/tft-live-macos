import AppKit
import TFTCore

final class LauncherDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum State {
        case idle, preparing, cancelling, quittingAfterPreparation
    }

    private struct Panel {
        let window: NSWindow
        let status: NSTextField
        let progress: NSProgressIndicator
        let hint: NSTextField
    }

    private var panel: Panel?
    private var state = State.idle
    private var pending = Data()
    private var lastLine = "Setup did not complete."
    private var progressTimer: Timer?
    private var allowsAutomaticProgress = true
    private var isUpdatingComponents = false
    private var componentPercentage: Int?
    private var cancellationInput: FileHandle?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        state == .idle
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard (state == .preparing && isUpdatingComponents) || state == .idle else { return false }
        progressTimer?.invalidate()
        progressTimer = nil
        if isUpdatingComponents && panel == nil { showComponentProgress() }
        panel?.window.makeKeyAndOrderFront(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if isUpdatingComponents && state == .preparing {
            state = .cancelling
            cancelUpdate()
        }
        allowsAutomaticProgress = false
        panel = nil
        progressTimer?.invalidate()
        progressTimer = nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard state != .idle else { return .terminateNow }
        if isUpdatingComponents && state == .preparing { cancelUpdate() }
        state = .quittingAfterPreparation
        return .terminateCancel
    }

    private func cancelUpdate() {
        panel?.hint.stringValue = "Cancelling the Riot component update…"
        try? cancellationInput?.close()
        cancellationInput = nil
    }

    private func makePanel() -> Panel {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 178), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "TFT Live"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let status = NSTextField(wrappingLabelWithString: "")
        status.frame = NSRect(x: 28, y: 69, width: 424, height: 60)
        status.font = .systemFont(ofSize: 14)
        window.contentView?.addSubview(status)
        let progress = NSProgressIndicator(frame: NSRect(x: 28, y: 50, width: 424, height: 12))
        progress.style = .bar
        window.contentView?.addSubview(progress)
        let hint = NSTextField(wrappingLabelWithString: "Close this window to cancel the update.")
        hint.frame = NSRect(x: 28, y: 12, width: 424, height: 32)
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        window.contentView?.addSubview(hint)
        return Panel(window: window, status: status, progress: progress, hint: hint)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = Bundle.main.url(forResource: "TFTLive", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: icon)
        }
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
            task.arguments = ["--gui"]
            let cancellation = Pipe()
            task.standardInput = cancellation
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            try task.run()
            cancellationInput = cancellation.fileHandleForWriting
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
        let updatingComponents = line.hasPrefix("Updating Riot components, ")
        if updatingComponents {
            isUpdatingComponents = true
        } else if line == Launcher.signInStatus || line == Launcher.gameUpdateStatus ||
                    line == RiotRuntime.applyingUpdateStatus ||
                    line.hasPrefix("Riot update deferred.") ||
                    (line.hasSuffix(" %") && Int(line.dropLast(2)) != nil) {
            // The game patcher reports its progress directly in Riot Client.
            isUpdatingComponents = false
            progressTimer?.invalidate()
            progressTimer = nil
            panel?.window.delegate = nil
            panel?.window.close()
            panel = nil
        }

        guard isUpdatingComponents else { return }
        componentPercentage = updatingComponents && line.hasSuffix(" %")
            ? line.dropLast(2).split(separator: " ").last.flatMap { Int($0) } : nil
        if let panel {
            renderProgress(in: panel)
            return
        }

        guard allowsAutomaticProgress,
              state == .preparing, progressTimer == nil else { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.progressTimer = nil
            guard self.state == .preparing, self.isUpdatingComponents, self.panel == nil else { return }
            self.showComponentProgress()
        }
    }

    private func showComponentProgress() {
        let panel = makePanel()
        self.panel = panel
        renderProgress(in: panel)
        panel.window.orderFrontRegardless()
    }

    private func renderProgress(in panel: Panel) {
        panel.status.stringValue = lastLine
        if let percentage = componentPercentage, (0...100).contains(percentage) {
            panel.progress.stopAnimation(nil)
            panel.progress.isIndeterminate = false
            panel.progress.doubleValue = Double(percentage)
        } else {
            panel.progress.isIndeterminate = true
            panel.progress.startAnimation(nil)
        }
    }

    private func finish(exitStatus: Int32) {
        try? cancellationInput?.close()
        cancellationInput = nil
        progressTimer?.invalidate()
        progressTimer = nil
        let quitting = state == .quittingAfterPreparation
        state = .idle
        if quitting || exitStatus == 0 {
            NSApp.terminate(nil)
        } else {
            let tail = String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            failure(tail.isEmpty ? lastLine : tail)
        }
    }

    private func failure(_ message: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.progress.stopAnimation(nil)
        panel.progress.isHidden = true
        panel.hint.isHidden = true
        panel.status.stringValue = message
        let button = NSButton(title: "Close", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        button.frame = NSRect(x: 370, y: 15, width: 85, height: 30)
        panel.window.contentView?.addSubview(button)
        panel.window.makeKeyAndOrderFront(nil)
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
