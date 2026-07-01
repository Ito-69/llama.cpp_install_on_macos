import AppKit
import Foundation

// MARK: - App Support

let APP_SUPPORT_DIR = NSHomeDirectory() + "/Library/Application Support/llama-menubar"
let INSTALL_SCRIPT_PATH = APP_SUPPORT_DIR + "/install-llama.sh"
let CONFIG_PATH = "\(NSHomeDirectory())/.config/llama/server.conf"

func ensureSupportDir() -> Bool {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: APP_SUPPORT_DIR, isDirectory: &isDir), isDir.boolValue {
        return true
    }
    do {
        try fm.createDirectory(atPath: APP_SUPPORT_DIR, withIntermediateDirectories: true)
        return true
    } catch {
        return false
    }
}

func copyBundledScript() -> Bool {
    guard let resPath = Bundle.main.resourcePath else { return false }
    let bundled = resPath + "/install-llama.sh"
    guard FileManager.default.fileExists(atPath: bundled) else { return false }
    let fm = FileManager.default
    try? fm.removeItem(atPath: INSTALL_SCRIPT_PATH)
    do {
        try fm.copyItem(atPath: bundled, toPath: INSTALL_SCRIPT_PATH)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: INSTALL_SCRIPT_PATH)
        return true
    } catch {
        return false
    }
}

func isInstalled() -> Bool {
    FileManager.default.fileExists(atPath: CONFIG_PATH)
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard ensureSupportDir(), copyBundledScript() else {
            let alert = NSAlert()
            alert.messageText = "Setup Failed"
            alert.informativeText = "Could not prepare the support directory."
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        if isInstalled() {
            showMenuBar()
        } else {
            showWelcomeAndInstall()
        }
    }

    private func showWelcomeAndInstall() {
        let alert = NSAlert()
        alert.messageText = "Welcome to llama-menubar"
        alert.informativeText = "This app will install llama.cpp, download a language model, and set up a local AI server in your menu bar.\n\nThis may take a few minutes depending on your internet speed."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return }

        InstallManager.shared.install { [weak self] success in
            DispatchQueue.main.async {
                self?.showMenuBar()
                if success {
                    self?.menuBar?.ensureServerRunning()
                } else {
                    let err = NSAlert()
                    err.messageText = "Installation incomplete"
                    err.informativeText = "Check the output for details. You can re-install later from the menu."
                    err.runModal()
                }
            }
        }
    }

    private func showMenuBar() {
        menuBar = MenuBarController()
    }
}

// MARK: - Server Manager

final class ServerManager {
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
        guard let content = try? String(contentsOfFile: CONFIG_PATH, encoding: .utf8) else { return }
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

// MARK: - Launch at Login

import ServiceManagement

final class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()

    private let service = SMAppService.mainApp

    var isEnabled: Bool { service.status == .enabled }

    var isInApplicationsFolder: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if !isInApplicationsFolder { return false }
                try service.register()
            } else {
                try service.unregister()
            }
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Process Runner

@discardableResult
func runProcess(executable: String, arguments: [String], currentDirectory: String? = nil, outputCallback: ((String) -> Void)? = nil) -> (exitCode: Int32, fullOutput: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    var env = ProcessInfo.processInfo.environment
    env["DYLD_LIBRARY_PATH"] = NSHomeDirectory() + "/.local/lib"
    if let hfToken = UserDefaults.standard.string(forKey: "hf_token"), !hfToken.isEmpty {
        env["HF_TOKEN"] = hfToken
    }
    task.environment = env
    let outPipe = Pipe()
    let errPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = errPipe
    if let dir = currentDirectory {
        task.currentDirectoryURL = URL(fileURLWithPath: dir)
    }

    do {
        try task.run()
    } catch {
        return (-1, "Failed to start: \(error.localizedDescription)")
    }

    let outHandle = outPipe.fileHandleForReading
    let errHandle = errPipe.fileHandleForReading
    var fullOutput = ""
    let lock = NSLock()

    outHandle.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
        lock.lock(); fullOutput += s; lock.unlock()
        outputCallback?(s)
    }

    errHandle.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
        lock.lock(); fullOutput += s; lock.unlock()
        outputCallback?(s)
    }

    task.waitUntilExit()
    outHandle.readabilityHandler = nil
    errHandle.readabilityHandler = nil

    for handle in [outHandle, errHandle] {
        if let rest = String(data: handle.readDataToEndOfFile(), encoding: .utf8), !rest.isEmpty {
            lock.lock(); fullOutput += rest; lock.unlock()
            outputCallback?(rest)
        }
    }

    return (task.terminationStatus, fullOutput)
}

// MARK: - Hugging Face Token

func promptForHfTokenIfNeeded() {
    guard UserDefaults.standard.string(forKey: "hf_token") == nil else { return }

    let alert = NSAlert()
    alert.messageText = "Hugging Face Token"
    alert.informativeText = "Model downloads are rate-limited without a Hugging Face token.\n\nYou can get a free token at:\nhttps://huggingface.co/settings/tokens\n\nPaste your token below or leave empty to continue with slower downloads."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Skip")

    let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 22))
    textField.placeholderString = "hf_..."
    alert.accessoryView = textField

    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
        let token = textField.stringValue.trimmingCharacters(in: .whitespaces)
        if !token.isEmpty {
            UserDefaults.standard.set(token, forKey: "hf_token")
        }
    }
}

// MARK: - Install Manager

final class InstallManager: NSObject {
    static let shared = InstallManager()
    private var activeControllers: [OutputWindowController] = []

    func install(completion: @escaping (Bool) -> Void) {
        promptForHfTokenIfNeeded()

        let controller = OutputWindowController(title: "Installing llama.cpp…", showApplyInitially: false)
        activeControllers.append(controller)
        controller.show()
        let append: (String) -> Void = { s in DispatchQueue.main.async { controller.appendText(s) } }

        DispatchQueue.global(qos: .userInitiated).async {
            append("Installing…\n")
            append("Preparing dependencies…\n")

            // Ensure huggingface_hub is available and up to date
            let (pipCode, _) = runProcess(
                executable: "/usr/bin/pip3",
                arguments: ["install", "-U", "huggingface_hub", "--user", "--quiet", "-q"],
                outputCallback: nil
            )

            if pipCode != 0 {
                append("\n⚠️  Failed to install required Python package.\n")
                DispatchQueue.main.async {
                    controller.finish(exitCode: pipCode, applyEnabled: false) { _ in
                        self.activeControllers.removeAll { $0 === controller }
                        completion(false)
                    }
                }
                return
            }

            // Run main install script
            let scriptDir = URL(fileURLWithPath: INSTALL_SCRIPT_PATH).deletingLastPathComponent().path

            // Run main install script with LaunchAgent setup
            let (exitCode, _) = runProcess(
                executable: "/bin/bash",
                arguments: [INSTALL_SCRIPT_PATH, "--install-agent"],
                currentDirectory: scriptDir,
                outputCallback: { append($0) }
            )

            let success = exitCode == 0

            DispatchQueue.main.async {
                controller.finish(exitCode: exitCode, applyEnabled: false) { _ in
                    self.activeControllers.removeAll { $0 === controller }
                    completion(success)
                }
            }
        }
    }
}

// MARK: - Update Manager

final class UpdateManager: NSObject {
    static let shared = UpdateManager()

    private var activeControllers: [OutputWindowController] = []

    func isAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: INSTALL_SCRIPT_PATH)
    }

    func checkUpdate() {
        runScript(args: ["--check-update"], title: "Update Check") { [weak self] applyRequested in
            if applyRequested {
                self?.applyUpdate()
            }
        }
    }

    func applyUpdate() {
        runScript(args: ["--upgrade"], title: "Update Result") { [weak self] _ in
            self?.cleanupArchive(APP_SUPPORT_DIR)
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

    private func runScript(args: [String], title: String, onComplete: ((Bool) -> Void)? = nil) {
        let isCheck = args.first == "--check-update"
        let controller = OutputWindowController(title: title, showApplyInitially: isCheck)
        activeControllers.append(controller)
        controller.show()
        controller.appendText("Working…\n")
        let append: (String) -> Void = { s in DispatchQueue.main.async { controller.appendText(s) } }

        let scriptDir = URL(fileURLWithPath: INSTALL_SCRIPT_PATH).deletingLastPathComponent().path

        DispatchQueue.global(qos: .userInitiated).async {
            let (exitCode, fullOut) = runProcess(
                executable: "/bin/bash",
                arguments: [INSTALL_SCRIPT_PATH] + args,
                currentDirectory: scriptDir,
                outputCallback: { append($0) }
            )

            let updateAvailable = isCheck && fullOut.contains("newer version available")

            DispatchQueue.main.async {
                controller.finish(exitCode: exitCode, applyEnabled: updateAvailable) { applyClicked in
                    self.activeControllers.removeAll { $0 === controller }
                    onComplete?(isCheck && applyClicked && updateAvailable)
                }
            }
        }
    }
}

// MARK: - App Update Manager

final class AppUpdateManager {
    static let shared = AppUpdateManager()

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func check(completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/Ito-69/llama.cpp_install_on_macos/releases/latest") else {
            completion(nil)
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let isNewer = self.compareVersions(latestVersion, self.currentVersion) > 0

            DispatchQueue.main.async {
                completion(isNewer ? latestVersion : nil)
            }
        }.resume()
    }

    private func compareVersions(_ a: String, _ b: String) -> Int {
        let aParts = a.components(separatedBy: ".").map { Int($0) ?? 0 }
        let bParts = b.components(separatedBy: ".").map { Int($0) ?? 0 }
        let count = max(aParts.count, bParts.count)
        for i in 0..<count {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av > bv { return 1 }
            if av < bv { return -1 }
        }
        return 0
    }

    func showResult() {
        let version = currentVersion
        check { latestVersion in
            if let v = latestVersion {
                let alert = NSAlert()
                alert.messageText = "Update Available"
                alert.informativeText = "llama-menubar v\(v) is available. Download from GitHub?"
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    guard let url = URL(string: "https://github.com/Ito-69/llama.cpp_install_on_macos/releases/latest") else { return }
                    NSWorkspace.shared.open(url)
                }
            } else {
                let alert = NSAlert()
                alert.messageText = "Up to Date"
                alert.informativeText = "llama-menubar v\(version) is the latest version."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
}

// MARK: - Output Window Controller

final class OutputWindowController: NSObject, NSWindowDelegate {
    private let window: NSPanel
    private let textView: NSTextView
    private let applyButton: NSButton
    private let closeButton: NSButton
    private let progress: NSProgressIndicator
    private var onFinish: ((Bool) -> Void)?

    init(title: String, showApplyInitially: Bool) {
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = title
        win.isFloatingPanel = true
        win.hidesOnDeactivate = false

        let content = NSView(frame: win.contentView!.bounds)
        content.autoresizingMask = [.width, .height]

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 60, width: 608, height: 360))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.borderType = .bezelBorder

        let tv = NSTextView(frame: scroll.bounds)
        tv.autoresizingMask = [.width, .height]
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainer?.containerSize = NSSize(width: 608, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true

        scroll.documentView = tv

        let spinner = NSProgressIndicator(frame: NSRect(x: 16, y: 20, width: 16, height: 16))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        let apply = NSButton(title: "Apply Update", target: nil, action: nil)
        apply.bezelStyle = .rounded
        apply.isEnabled = false
        apply.setButtonType(.momentaryPushIn)
        apply.frame = NSRect(x: 640 - 16 - 80 - 8 - 80, y: 14, width: 80, height: 24)
        apply.autoresizingMask = [.minXMargin]

        let close = NSButton(title: "Close", target: nil, action: nil)
        close.bezelStyle = .rounded
        close.isEnabled = false
        close.setButtonType(.momentaryPushIn)
        close.frame = NSRect(x: 640 - 16 - 80, y: 14, width: 80, height: 24)
        close.autoresizingMask = [.minXMargin]

        content.addSubview(scroll)
        content.addSubview(spinner)
        content.addSubview(apply)
        content.addSubview(close)

        win.contentView = content

        self.window = win
        self.textView = tv
        self.applyButton = apply
        self.closeButton = close
        self.progress = spinner

        super.init()
        win.delegate = self
        apply.target = self
        apply.action = #selector(applyClicked)
        close.target = self
        close.action = #selector(closeClicked)
        apply.isHidden = !showApplyInitially
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func appendText(_ s: String) {
        let attr = NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ])
        textView.textStorage?.append(attr)
        textView.scrollToEndOfDocument(nil)
    }

    func setOutput(_ text: String) {
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ])
        textView.textStorage?.setAttributedString(attr)
        textView.scrollToEndOfDocument(nil)
    }

    func finish(exitCode: Int32, applyEnabled: Bool, onFinish: @escaping (Bool) -> Void) {
        progress.stopAnimation(nil)
        progress.isHidden = true
        appendText("\n--- finished (exit \(exitCode)) ---\n")
        if applyEnabled {
            applyButton.isHidden = false
            applyButton.isEnabled = true
        }
        closeButton.isEnabled = true
        self.onFinish = onFinish
    }

    @objc private func applyClicked() {
        window.close()
        onFinish?(true)
        onFinish = nil
    }

    @objc private func closeClicked() {
        window.close()
        onFinish?(false)
        onFinish = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let cb = onFinish {
            cb(false)
            onFinish = nil
        }
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

        // App Update
        let appUpdate = NSMenuItem(title: "Check for App Update...", action: #selector(checkAppUpdate), keyEquivalent: "")
        appUpdate.target = self
        menu.addItem(appUpdate)

        // llama.cpp Update
        if UpdateManager.shared.isAvailable() {
            let checkLlama = NSMenuItem(title: "Check for llama.cpp Update...", action: #selector(checkLlamaUpdate), keyEquivalent: "")
            checkLlama.target = self
            menu.addItem(checkLlama)

            let applyLlama = NSMenuItem(title: "Apply llama.cpp Update...", action: #selector(applyLlamaUpdate), keyEquivalent: "")
            applyLlama.target = self
            menu.addItem(applyLlama)
        }

        menu.addItem(.separator())

        // Launch at Login
        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLaunchAtLogin),
                               keyEquivalent: "")
        login.target = self
        login.state = LaunchAtLoginManager.shared.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        // Uninstall
        let uninstall = NSMenuItem(title: "Uninstall...", action: #selector(uninstallAll), keyEquivalent: "")
        uninstall.target = self
        menu.addItem(uninstall)

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

    func ensureServerRunning() {
        server.checkStatus()
        if !server.isRunning {
            server.startServer()
            queueRefresh()
        }
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

    @objc private func checkAppUpdate() {
        AppUpdateManager.shared.showResult()
    }

    @objc private func checkLlamaUpdate() {
        UpdateManager.shared.checkUpdate()
    }

    @objc private func applyLlamaUpdate() {
        UpdateManager.shared.applyUpdate()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let manager = LaunchAtLoginManager.shared
        let newState = !manager.isEnabled

        if newState && !manager.isInApplicationsFolder {
            let alert = NSAlert()
            alert.messageText = "Move app to /Applications first"
            alert.informativeText = "Launch at Login requires the app to live in /Applications so it can be found reliably on boot."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        if !manager.setEnabled(newState) {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = "Check System Settings → General → Login Items for the current status."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        refresh()
    }

    @objc private func uninstallAll() {
        let alert = NSAlert()
        alert.messageText = "Uninstall llama.cpp"
        alert.informativeText = "This will remove:\n  • llama.cpp binaries and libraries\n  • LaunchAgent\n  • Configuration files\n  • App support data\n\nRemove downloaded models too?"
        alert.addButton(withTitle: "Remove Everything")
        alert.addButton(withTitle: "Keep Models")
        alert.addButton(withTitle: "Cancel")

        let choice = alert.runModal()
        guard choice != .alertThirdButtonReturn else { return }
        let removeModels = choice == .alertFirstButtonReturn

        pollTimer?.invalidate()

        let fm = FileManager.default
        let home = NSHomeDirectory()

        // Stop server and remove LaunchAgent
        server.stopServer()
        let uninstallAgent = Process()
        uninstallAgent.executableURL = URL(fileURLWithPath: "/bin/bash")
        uninstallAgent.arguments = [INSTALL_SCRIPT_PATH, "--uninstall-agent"]
        try? uninstallAgent.run()
        uninstallAgent.waitUntilExit()

        // Remove binaries
        if let items = try? fm.contentsOfDirectory(atPath: home + "/.local/bin") {
            for name in items where name.hasPrefix("llama-") || name == "rpc-server" || name == "ggml-rpc-server" {
                try? fm.removeItem(atPath: home + "/.local/bin/" + name)
            }
        }

        // Remove libraries
        if let items = try? fm.contentsOfDirectory(atPath: home + "/.local/lib") {
            for name in items where name.hasPrefix("libggml") || name.hasPrefix("libllama") || name.hasPrefix("libmtmd") {
                try? fm.removeItem(atPath: home + "/.local/lib/" + name)
            }
        }

        // Remove config
        try? fm.removeItem(atPath: home + "/.config/llama")

        // Remove app support
        try? fm.removeItem(atPath: APP_SUPPORT_DIR)

        // Remove models
        if removeModels {
            try? fm.removeItem(atPath: home + "/models")
        }

        // Remove shell RC entries
        for rcFile in [home + "/.zshrc", home + "/.bash_profile"] {
            guard let content = try? String(contentsOfFile: rcFile, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: .newlines)
            var cleaned: [String] = []
            var skip = false
            for line in lines {
                if line == "# llama.cpp (install-llama.sh)" { skip = true }
                if !skip { cleaned.append(line) }
                if skip && line.isEmpty { skip = false }
            }
            try? cleaned.joined(separator: "\n").write(toFile: rcFile, atomically: true, encoding: .utf8)
        }

        // Show completion
        let done = NSAlert()
        done.messageText = "Uninstall Complete"
        done.informativeText = "llama.cpp and all related files have been removed.\n\nThe app will now quit and remove itself from /Applications."
        done.addButton(withTitle: "OK")
        done.runModal()

        // Self-destruct: remove the .app bundle after quitting
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "(sleep 1; rm -rf \"\(bundlePath)\") &"]
        try? task.run()

        NSApplication.shared.terminate(nil)
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
