import AppKit
import Foundation

final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSPanel!

    private var profilePopup: NSPopUpButton!
    private var nglSlider: NSSlider!
    private var nglLabel: NSTextField!
    private var contextPopup: NSPopUpButton!
    private var faCheckbox: NSButton!
    private var cachePopup: NSPopUpButton!
    private var threadsField: NSTextField!
    private var batchField: NSTextField!
    private var portField: NSTextField!
    private var ramLabel: NSTextField!
    private var diagnosticsLabel: NSTextField!
    private var usageLabel: NSTextField!
    private var applyButton: NSButton!
    private var usageTimer: Timer?
    private var lastSelfCpuTime: Double = 0
    private var lastSelfSampleTime: TimeInterval = 0

    private override init() { super.init() }

    func showWindow() {
        if window == nil { buildWindow() }
        syncFromServerManager()
        updateRamEstimate()
        updateUsage()
        usageTimer?.invalidate()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateUsage()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Window

    private func buildWindow() {
        let w = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        w.title = "Server Settings"
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.delegate = self
        w.center()

        let content = NSView(frame: w.contentView!.bounds)
        content.autoresizingMask = [.width, .height]

        var y: CGFloat = 500

        // ── Header ──
        let header = NSTextField(labelWithString: "Server Configuration")
        header.font = NSFont.boldSystemFont(ofSize: 13)
        header.frame = NSRect(x: 16, y: y, width: 488, height: 18)
        content.addSubview(header)
        y -= 30

        // ── Profile row ──
        addLabel("Profile:", x: 16, y: y - 2, width: 110, to: content)
        profilePopup = NSPopUpButton(frame: NSRect(x: 130, y: y, width: 200, height: 24))
        profilePopup.addItems(withTitles: ["Fast", "Balanced", "Accurate"])
        profilePopup.toolTip = "Preset combinations of GPU layers, flash attention and KV cache quantization."
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged(_:))
        content.addSubview(profilePopup)
        y -= 34

        // ── Separator ──
        let sep1 = separator(frame: NSRect(x: 16, y: y, width: 488, height: 1))
        content.addSubview(sep1)
        y -= 16

        // ── GPU layers row ──
        addLabel("GPU layers:", x: 16, y: y - 2, width: 110, to: content)
        nglSlider = NSSlider(frame: NSRect(x: 130, y: y, width: 260, height: 24))
        nglSlider.minValue = 0
        nglSlider.maxValue = 99
        nglSlider.numberOfTickMarks = 100
        nglSlider.allowsTickMarkValuesOnly = false
        nglSlider.toolTip = "Number of transformer layers offloaded to the GPU. 99 = maximum GPU acceleration. 0 = CPU only."
        nglSlider.target = self
        nglSlider.action = #selector(nglChanged(_:))
        content.addSubview(nglSlider)
        nglLabel = NSTextField(labelWithString: "40")
        nglLabel.frame = NSRect(x: 400, y: y - 2, width: 40, height: 18)
        nglLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        nglLabel.alignment = .right
        nglLabel.toolTip = "Current GPU layers value."
        content.addSubview(nglLabel)
        y -= 34

        // ── Context row ──
        addLabel("Context:", x: 16, y: y - 2, width: 110, to: content)
        contextPopup = NSPopUpButton(frame: NSRect(x: 130, y: y, width: 150, height: 24))
        let ctxValues = ["2048", "4096", "8192", "16384", "32768"]
        contextPopup.addItems(withTitles: ctxValues)
        contextPopup.toolTip = "Maximum number of tokens the model can keep in memory. Larger context uses more RAM."
        content.addSubview(contextPopup)
        addHint("tokens", x: 290, y: y, to: content)
        y -= 34

        // ── Flash attention row ──
        addLabel("Flash attn:", x: 16, y: y - 2, width: 110, to: content)
        faCheckbox = NSButton(checkboxWithTitle: "Enabled (faster inference)", target: self, action: #selector(checkboxChanged(_:)))
        faCheckbox.frame = NSRect(x: 130, y: y, width: 200, height: 22)
        faCheckbox.toolTip = "Flash Attention speeds up inference on most models. Leave enabled unless the model crashes."
        content.addSubview(faCheckbox)
        y -= 34

        // ── KV cache row ──
        addLabel("KV cache:", x: 16, y: y - 2, width: 110, to: content)
        cachePopup = NSPopUpButton(frame: NSRect(x: 130, y: y, width: 150, height: 24))
        cachePopup.addItems(withTitles: ["f16", "q8_0", "q4_0"])
        cachePopup.toolTip = "Quantization of the key/value cache. Lower precision = less RAM, but may reduce quality."
        content.addSubview(cachePopup)
        addHint("quant type (saves RAM)", x: 290, y: y, to: content)
        y -= 34

        // ── Threads row ──
        addLabel("Threads:", x: 16, y: y - 2, width: 110, to: content)
        threadsField = NSTextField(frame: NSRect(x: 130, y: y, width: 80, height: 22))
        threadsField.placeholderString = "0"
        threadsField.toolTip = "CPU threads used for prompt processing. 0 = auto. On Apple Silicon, setting this to the number of P-cores is usually fastest."
        content.addSubview(threadsField)
        let pcores = ServerManager.perfLevelCores()
        let threadHint = pcores > 0 ? "0 = auto (\(pcores) P-cores detected)" : "0 = auto"
        addHint(threadHint, x: 220, y: y, to: content)
        y -= 34

        // ── Batch size row ──
        addLabel("Batch:", x: 16, y: y - 2, width: 110, to: content)
        batchField = NSTextField(frame: NSRect(x: 130, y: y, width: 80, height: 22))
        batchField.placeholderString = "512"
        batchField.toolTip = "Number of tokens processed in one batch. 512 is a good default. Larger batches use more memory."
        content.addSubview(batchField)
        addHint("tokens per batch", x: 220, y: y, to: content)
        y -= 34

        // ── Port row ──
        addLabel("Port:", x: 16, y: y - 2, width: 110, to: content)
        portField = NSTextField(frame: NSRect(x: 130, y: y, width: 100, height: 22))
        portField.placeholderString = "8080"
        portField.toolTip = "TCP port for the llama-server HTTP API and WebUI."
        content.addSubview(portField)
        y -= 34

        // ── Separator ──
        let sep2 = separator(frame: NSRect(x: 16, y: y, width: 488, height: 1))
        content.addSubview(sep2)
        y -= 32

        // ── RAM estimate ──
        ramLabel = NSTextField(wrappingLabelWithString: "")
        ramLabel.frame = NSRect(x: 16, y: y, width: 488, height: 26)
        ramLabel.font = NSFont.systemFont(ofSize: 11)
        content.addSubview(ramLabel)
        y -= 30

        // ── System diagnostics ──
        diagnosticsLabel = NSTextField(wrappingLabelWithString: systemDiagnostics())
        diagnosticsLabel.frame = NSRect(x: 16, y: y, width: 488, height: 26)
        diagnosticsLabel.font = NSFont.systemFont(ofSize: 11)
        diagnosticsLabel.textColor = .secondaryLabelColor
        content.addSubview(diagnosticsLabel)
        y -= 28

        // ── App usage ──
        usageLabel = NSTextField(wrappingLabelWithString: "Gathering usage…")
        usageLabel.frame = NSRect(x: 16, y: y, width: 488, height: 32)
        usageLabel.font = NSFont.systemFont(ofSize: 11)
        usageLabel.textColor = .secondaryLabelColor
        content.addSubview(usageLabel)
        y -= 28

        // ── Buttons ──
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: 520 - 16 - 130 - 8 - 80, y: 16, width: 80, height: 24)
        cancelButton.autoresizingMask = [.minXMargin, .minYMargin]
        cancelButton.toolTip = "Close without saving changes."
        content.addSubview(cancelButton)

        applyButton = NSButton(title: "Apply & Restart", target: self, action: #selector(applyClicked))
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.frame = NSRect(x: 520 - 16 - 130, y: 16, width: 130, height: 24)
        applyButton.autoresizingMask = [.minXMargin, .minYMargin]
        applyButton.toolTip = "Save settings, regenerate the start script and restart the server."
        content.addSubview(applyButton)

        w.contentView = content
        window = w
    }

    // MARK: Helpers

    private func addLabel(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, to view: NSView) {
        let lbl = NSTextField(labelWithString: text)
        lbl.frame = NSRect(x: x, y: y, width: width, height: 18)
        lbl.font = NSFont.systemFont(ofSize: 12)
        lbl.alignment = .right
        view.addSubview(lbl)
    }

    private func addHint(_ text: String, x: CGFloat, y: CGFloat, to view: NSView) {
        let lbl = NSTextField(labelWithString: text)
        lbl.frame = NSRect(x: x, y: y + 2, width: 200, height: 18)
        lbl.font = NSFont.systemFont(ofSize: 11)
        lbl.textColor = .secondaryLabelColor
        view.addSubview(lbl)
    }

    private func separator(frame: NSRect) -> NSView {
        let v = NSView(frame: frame)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return v
    }

    // MARK: Sync

    private func syncFromServerManager() {
        let sm = ServerManager.shared
        // Profile
        let profileIndex = ["fast", "balanced", "accurate"].firstIndex(of: sm.profile) ?? 1
        profilePopup.selectItem(at: profileIndex)

        nglSlider.doubleValue = Double(sm.ngl) ?? 40
        nglLabel.stringValue = sm.ngl

        if let idx = contextPopup.itemTitles.firstIndex(of: sm.context) {
            contextPopup.selectItem(at: idx)
        }

        faCheckbox.state = (sm.fa == "1") ? .on : .off

        if let idx = cachePopup.itemTitles.firstIndex(of: sm.ctk) {
            cachePopup.selectItem(at: idx)
        }

        threadsField.stringValue = sm.threads == "0" ? "" : sm.threads
        batchField.stringValue = sm.batchSize == "512" ? "" : sm.batchSize
        portField.stringValue = sm.port
    }

    private func currentProfile() -> String {
        let idx = profilePopup.indexOfSelectedItem
        return ["fast", "balanced", "accurate"][idx]
    }

    private func currentNgl() -> String {
        String(Int(nglSlider.doubleValue))
    }

    private func currentFa() -> String {
        faCheckbox.state == .on ? "1" : "0"
    }

    private func currentCtk() -> String {
        cachePopup.titleOfSelectedItem ?? "f16"
    }

    // MARK: Profile presets

    @objc private func profileChanged(_ sender: NSPopUpButton) {
        let profile = ["fast", "balanced", "accurate"][sender.indexOfSelectedItem]
        ServerManager.shared.applyProfile(profile)
        syncFromServerManager()
        updateRamEstimate()
    }

    @objc private func nglChanged(_ sender: NSSlider) {
        let v = Int(sender.doubleValue)
        nglLabel.stringValue = String(v)
        updateRamEstimate()
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        // nothing extra
    }

    // MARK: RAM estimate

    private func updateRamEstimate() {
        let sm = ServerManager.shared
        let modelSize = (try? FileManager.default.attributesOfItem(atPath: sm.modelPath)[.size] as? Int64) ?? 0
        let totalRAM = ProcessInfo.processInfo.physicalMemory
        let modelGB = Double(modelSize) / 1_000_000_000.0
        // Rough KV cache: ~30% of model size at 8192, scaling with context
        let ctxVal = Int(sm.context) ?? 8192
        let ctxFactor = Double(ctxVal) / 8192.0
        let ctxGB = modelGB * 0.3 * ctxFactor
        let neededGB = modelGB + ctxGB
        let availGB = Double(totalRAM) / 1_000_000_000.0

        if modelSize == 0 {
            ramLabel.stringValue = "No active model detected. Set a model in the Models window first."
            ramLabel.textColor = .secondaryLabelColor
            return
        }

        if neededGB > availGB {
            ramLabel.stringValue = String(format: "⚠️  ~%.1f GB needed, %.0f GB available — may crash or swap!", neededGB, availGB)
            ramLabel.textColor = .systemRed
        } else if neededGB > availGB * 0.8 {
            ramLabel.stringValue = String(format: "⚠️  ~%.1f GB needed, %.0f GB available — close other apps", neededGB, availGB)
            ramLabel.textColor = .systemOrange
        } else {
            ramLabel.stringValue = String(format: "%.1f GB model + %.1f GB ctx ≈ %.1f GB needed, %.0f GB available ✓", modelGB, ctxGB, neededGB, availGB)
            ramLabel.textColor = .secondaryLabelColor
        }
    }

    // MARK: Actions

    @objc private func applyClicked() {
        do {
            try ModelManager.shared.saveSettings(
                ngl: currentNgl(),
                fa: currentFa(),
                ctk: currentCtk(),
                ctv: currentCtk(),
                threads: threadsField.stringValue.isEmpty ? "0" : threadsField.stringValue,
                batchSize: batchField.stringValue.isEmpty ? "512" : batchField.stringValue,
                context: contextPopup.titleOfSelectedItem ?? "8192",
                port: portField.stringValue.isEmpty ? "8080" : portField.stringValue,
                profile: currentProfile()
            )
            window.close()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save settings"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func cancelClicked() {
        window.close()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        usageTimer?.invalidate()
        usageTimer = nil
    }

    // MARK: Diagnostics

    private func systemDiagnostics() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let chip = chipName()
        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_000_000_000.0
        let cores = ProcessInfo.processInfo.processorCount
        return "macOS \(os) · \(chip) · \(String(format: "%.1f", ramGB)) GB RAM · \(cores) cores"
    }

    private func chipName() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    private func updateUsage() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let selfCpu = self.cpuPercent()
            let selfMem = self.memoryBytes()
            let serverUsage = self.serverUsageFromPS()
            let gpu = self.gpuUtilization()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                var parts: [String] = []
                parts.append(String(format: "LlamaMate: %.1f%% CPU · %.1f MB RAM", selfCpu, Double(selfMem) / 1_000_000.0))

                if let server = serverUsage {
                    let gpuText = gpu != nil ? String(format: " · GPU %.0f%%", gpu!) : ""
                    parts.append(String(format: "llama-server: %.1f%% CPU · %.1f MB RAM%@", server.cpu, server.ramMB, gpuText))
                } else {
                    parts.append("llama-server: not running")
                }

                self.usageLabel.stringValue = parts.joined(separator: "  |  ")
            }
        }
    }

    private func appUsageString() -> String {
        return "Gathering usage…"
    }

    // MARK: - Self monitoring (Mach)

    private func memoryBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            return info.phys_footprint
        }
        return 0
    }

    private func cpuPercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let kr = task_threads(mach_task_self_, &threadList, &threadCount)
        guard kr == KERN_SUCCESS, let threads = threadList else { return 0 }
        var totalSeconds: Double = 0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(THREAD_INFO_MAX)
            let kr2 = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if kr2 == KERN_SUCCESS {
                totalSeconds += Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000.0
                totalSeconds += Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000.0
            }
        }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))

        let now = Date.timeIntervalSinceReferenceDate
        let delta = now - lastSelfSampleTime
        let cpuDelta = totalSeconds - lastSelfCpuTime
        lastSelfCpuTime = totalSeconds
        lastSelfSampleTime = now

        if delta > 0 {
            return (cpuDelta / delta) * 100.0
        }
        return 0
    }

    // MARK: - Server monitoring

    private func serverUsageFromPS() -> (cpu: Double, ramMB: Double)? {
        guard let output = runShell("/bin/ps", args: ["-A", "-o", "pid=,pcpu=,rss=,comm="]) else { return nil }
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("llama-server") else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }
            if let cpu = Double(parts[1]), let rss = Double(parts[2]) {
                return (cpu, rss / 1024.0)
            }
        }
        return nil
    }

    private func gpuUtilization() -> Double? {
        guard let output = runShell("/usr/sbin/ioreg", args: ["-r", "-c", "IOAccelerator"]) else { return nil }
        guard let range = output.range(of: "\"Device Utilization %\"=") else { return nil }
        let tail = output[range.upperBound...]
        let valuePart = tail.prefix(while: { $0.isNumber })
        return Double(valuePart)
    }

    private func runShell(_ path: String, args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = outPipe
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
