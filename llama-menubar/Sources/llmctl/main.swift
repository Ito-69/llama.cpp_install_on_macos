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

    private func icon(running: Bool, size: NSSize = NSSize(width: 20, height: 20)) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocusFlipped(false)
        let color: NSColor = running ? .systemGreen : .tertiaryLabelColor
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 12, height: 12)).fill()
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    // MARK: Menu

    private func refresh() {
        statusItem.button?.image = icon(running: server.isRunning)
        statusItem.button?.image?.isTemplate = false

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
