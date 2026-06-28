import AppKit
import Foundation

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBar = MenuBarController()
    }
}

// MARK: - Server Manager

final class ServerManager {
    private let configPath = "\(NSHomeDirectory())/.config/llama/server.conf"
    private let launchAgentPlist = "\(NSHomeDirectory())/Library/LaunchAgents/com.llama.cpp.server.plist"
    private let launchAgentService = "gui/\(getuid())/com.llama.cpp.server"

    private(set) var isRunning = false
    private(set) var modelLabel = ""
    private(set) var port = "8080"

    var onStatusChange: (() -> Void)?

    var webUIURL: String { "http://127.0.0.1:\(port)" }

    init() {
        loadConfig()
    }

    private func loadConfig() {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
        for line in content.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "PORT":                   port = parts[1]
            case "MODEL_LABEL":            modelLabel = parts[1].replacingOccurrences(of: "\"", with: "")
            default:                       break
            }
        }
    }

    func checkStatus() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "llama-server"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try? task.run()
        task.waitUntilExit()
        isRunning = task.terminationStatus == 0
        onStatusChange?()
    }

    func startServer() {
        launchctl("bootstrap", "gui/\(getuid())", launchAgentPlist)
        launchctl("enable", launchAgentService)
        launchctl("kickstart", launchAgentService)
    }

    func stopServer() {
        launchctl("bootout", launchAgentService)
    }

    func restartServer() {
        launchctl("kickstart", "-k", launchAgentService)
    }

    private func launchctl(_ args: String...) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        try? task.run()
        task.waitUntilExit()
    }
}

// MARK: - Update Manager

final class UpdateManager: NSObject {
    static let shared = UpdateManager()

    private var scriptPath: String? {
        let saved = UserDefaults.standard.string(forKey: "installScriptPath")
        if let s = saved, FileManager.default.isExecutableFile(atPath: s) { return s }

        let candidates: [String] = {
            var c = [String]()

            // bundled inside .app Resources
            if let r = Bundle.main.resourcePath {
                c.append("\(r)/install-llama.sh")
            }

            // next to the executable (dev)
            if let exe = CommandLine.arguments.first {
                c.append(URL(fileURLWithPath: exe).deletingLastPathComponent().appendingPathComponent("install-llama.sh").path)
            }

            // common locations
            let home = NSHomeDirectory()
            c.append("\(home)/Documents/llama.cpp-macos-installer/install-llama.sh")
            c.append("\(home)/.config/llama/install-llama.sh")
            c.append("\(home)/Downloads/install-llama.sh")
            c.append("\(home)/Desktop/install-llama.sh")

            // XDG-like
            if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
                c.append("\(xdg)/llama/install-llama.sh")
            }

            return c
        }()

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                UserDefaults.standard.set(path, forKey: "installScriptPath")
                return path
            }
        }
        return nil
    }

    func isAvailable() -> Bool { scriptPath != nil }

    func checkUpdate() {
        guard let path = scriptPath else { return notFound() }
        runScript(path, args: ["--check-update"], title: "Update Check")
    }

    func applyUpdate() {
        guard let path = scriptPath else { return notFound() }
        runScript(path, args: ["--upgrade"], title: "Update Result") { scriptDir in
            self.cleanupArchive(scriptDir)
        }
    }

    private func cleanupArchive(_ dir: String) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for name in items {
            if name.hasPrefix("llama-b") {
                try? fm.removeItem(atPath: dir + "/" + name)
            }
        }
    }

    private func notFound() {
        let alert = NSAlert()
        alert.messageText = "install-llama.sh not found"
        alert.informativeText = "Locate the script to enable updates."
        alert.addButton(withTitle: "Locate…")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.shellScript]
            panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
            panel.message = "Select install-llama.sh"
            if panel.runModal() == .OK, let url = panel.url {
                UserDefaults.standard.set(url.path, forKey: "installScriptPath")
            }
        }
    }

    private func runScript(_ path: String, args: [String], title: String, done: ((String) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [path] + args
            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe
            let scriptDir = URL(fileURLWithPath: path).deletingLastPathComponent().path
            task.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
            try? task.run()
            task.waitUntilExit()

            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let output = out + (err.isEmpty ? "" : "\n--- stderr ---\n" + err)

            DispatchQueue.main.async {
                self?.showOutputWindow(title: title, text: output.isEmpty ? "Done (no output)" : output)
                done?(scriptDir)
            }
        }
    }

    private func showOutputWindow(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 580, height: 360))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.borderType = .bezelBorder

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 340))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = text
        textView.textContainer?.containerSize = NSSize(width: 560, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true

        scroll.documentView = textView
        alert.accessoryView = scroll

        alert.addButton(withTitle: "Close")
        alert.runModal()
    }
}

// MARK: - Menu Bar Controller

final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let server = ServerManager()
    private var pollTimer: Timer?

    override init() {
        super.init()

        statusItem.button?.image = icon(running: false)

        server.onStatusChange = { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }

        refresh()
        server.checkStatus()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.server.checkStatus()
        }
    }

    // MARK: Icon

    private let llamaImage: NSImage = {
        guard let url = Bundle.main.url(forResource: "llama", withExtension: "png"),
              let img = NSImage(contentsOf: url)
        else {
            return NSImage(size: NSSize(width: 20, height: 20))
        }
        img.size = NSSize(width: 20, height: 20)
        return img
    }()

    private func icon(running: Bool) -> NSImage {
        let fraction: CGFloat = running ? 1.0 : 0.35
        let img = NSImage(size: NSSize(width: 20, height: 20))
        img.lockFocusFlipped(false)
        llamaImage.draw(in: NSRect(x: 0, y: 0, width: 20, height: 20),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: fraction)
        img.unlockFocus()
        return img
    }

    // MARK: Menu

    private func refresh() {
        statusItem.button?.image = icon(running: server.isRunning)

        let menu = NSMenu()

        // Title
        let title = NSMenuItem(title: server.isRunning
                               ? "llama.cpp — running"
                               : "llama.cpp — stopped",
                               action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        // Model
        if !server.modelLabel.isEmpty {
            let model = NSMenuItem(title: server.modelLabel, action: nil, keyEquivalent: "")
            model.isEnabled = false
            menu.addItem(model)
        }

        menu.addItem(.separator())

        // Open WebUI
        let web = NSMenuItem(title: "Open WebUI", action: #selector(openWebUI), keyEquivalent: "o")
        web.target = self
        menu.addItem(web)

        // Start / Stop / Restart
        if server.isRunning {
            let restart = NSMenuItem(title: "Restart Server", action: #selector(restartServer), keyEquivalent: "r")
            restart.target = self
            menu.addItem(restart)

            let stop = NSMenuItem(title: "Stop Server", action: #selector(stopServer), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        } else {
            let start = NSMenuItem(title: "Start Server", action: #selector(startServer), keyEquivalent: "s")
            start.target = self
            menu.addItem(start)
        }

        menu.addItem(.separator())

        // Logs
        let logs = NSMenuItem(title: "Tail Logs", action: #selector(tailLogs), keyEquivalent: "l")
        logs.target = self
        menu.addItem(logs)

        menu.addItem(.separator())

        // Update
        if UpdateManager.shared.isAvailable() {
            let check = NSMenuItem(title: "Check for Update...", action: #selector(checkUpdate), keyEquivalent: "")
            check.target = self
            menu.addItem(check)

            let apply = NSMenuItem(title: "Apply Update...", action: #selector(applyUpdate), keyEquivalent: "")
            apply.target = self
            menu.addItem(apply)

            menu.addItem(.separator())
        }

        // Quit
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: Actions

    @objc private func openWebUI() {
        guard let url = URL(string: server.webUIURL) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func startServer() {
        server.startServer()
        queueRefresh()
    }

    @objc private func stopServer() {
        server.stopServer()
        queueRefresh()
    }

    @objc private func restartServer() {
        server.restartServer()
        queueRefresh()
    }

    @objc private func tailLogs() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["/Applications/Utilities/Console.app"]
        try? task.run()
    }

    @objc private func checkUpdate() {
        UpdateManager.shared.checkUpdate()
    }

    @objc private func applyUpdate() {
        UpdateManager.shared.applyUpdate()
    }

    @objc private func quitApp() {
        pollTimer?.invalidate()
        NSApplication.shared.terminate(nil)
    }

    private func queueRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.server.checkStatus()
        }
    }
}

// MARK: - Entry Point

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
