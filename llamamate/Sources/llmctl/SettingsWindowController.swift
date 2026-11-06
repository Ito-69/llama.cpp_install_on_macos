import AppKit
import Foundation
import Metal
import Security

final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSPanel!

    private var profilePopup: NSPopUpButton!
    private var nglSlider: NSSlider!
    private var nglLabel: NSTextField!
    private var contextPopup: NSPopUpButton!
    private var faCheckbox: NSButton!
    private var cachePopup: NSPopUpButton!
    private var cacheHint: NSTextField!
    private var threadsField: NSTextField!
    private var batchField: NSTextField!
    private var portField: NSTextField!
    private var lanCheckbox: NSButton!
    private var lanWarning: NSTextField!
    private var apiKeyField: NSTextField!
    private var cacheReuseCheckbox: NSButton!
    private var mlockCheckbox: NSButton!
    private var threadsBatchField: NSTextField!
    private var ramLabel: NSTextField!
    private var diagnosticsLabel: NSTextField!
    private var usageLabel: NSTextField!
    private var applyButton: NSButton!
    private var usageTimer: Timer?
    private var lastSelfCpuTime: Double = 0
    private var lastSelfSampleTime: TimeInterval = 0
    private var previousContextValue = "8192"
    private var originalHost = "127.0.0.1"

    static let standardContextValues = [
        "2048",
        "4096",
        "8192",
        "16384",
        "32768",
        "65536",
        "131072",
        "262144"
    ]

    private override init() { super.init() }

    func showWindow() {
        if window == nil { buildWindow() }
        syncFromServerManager()
        loadPerfControls()
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 724),
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

        var y: CGFloat = 684

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
        nglSlider.toolTip = "Number of transformer layers offloaded to the GPU. 99 = maximum GPU acceleration (all layers on Metal). 0 = CPU only."
        nglSlider.target = self
        nglSlider.action = #selector(nglChanged(_:))
        content.addSubview(nglSlider)
        nglLabel = NSTextField(labelWithString: "99")
        nglLabel.frame = NSRect(x: 395, y: y - 2, width: 85, height: 18)
        nglLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        nglLabel.alignment = .left
        nglLabel.toolTip = "Current GPU layers value (99 = all layers on Metal GPU)."
        content.addSubview(nglLabel)
        y -= 34

        // ── Context row ──
        addLabel("Context:", x: 16, y: y - 2, width: 110, to: content)
        contextPopup = NSPopUpButton(frame: NSRect(x: 130, y: y, width: 150, height: 24))
        contextPopup.addItems(withTitles: SettingsWindowController.standardContextValues)
        contextPopup.menu?.addItem(NSMenuItem.separator())
        contextPopup.addItem(withTitle: "Custom…")
        contextPopup.target = self
        contextPopup.action = #selector(contextChanged(_:))
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
        cachePopup.autoenablesItems = false
        cachePopup.target = self
        cachePopup.action = #selector(cacheChanged(_:))
        cachePopup.toolTip = "Quantization of the key/value cache. Lower precision = less RAM, but may reduce quality. Quantized types require Flash Attention."
        content.addSubview(cachePopup)
        cacheHint = NSTextField(labelWithString: "quant type (saves RAM)")
        cacheHint.frame = NSRect(x: 290, y: y + 2, width: 230, height: 18)
        cacheHint.font = NSFont.systemFont(ofSize: 11)
        cacheHint.textColor = .secondaryLabelColor
        content.addSubview(cacheHint)
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
        batchField.placeholderString = "2048"
        batchField.toolTip = "Number of tokens processed per logical batch. 2048 is recommended for Apple Silicon Metal."
        content.addSubview(batchField)
        addHint("tokens (2048 rec. for Metal)", x: 220, y: y, to: content)
        y -= 34

        // ── Port row ──
        addLabel("Port:", x: 16, y: y - 2, width: 110, to: content)
        portField = NSTextField(frame: NSRect(x: 130, y: y, width: 100, height: 22))
        portField.placeholderString = "8080"
        portField.toolTip = "TCP port for the llama-server HTTP API and WebUI."
        content.addSubview(portField)
        y -= 34

        // ── Network (LAN) row ──
        addLabel("Network:", x: 16, y: y - 2, width: 110, to: content)
        lanCheckbox = NSButton(checkboxWithTitle: "Allow access from local network",
                               target: self, action: #selector(lanChanged(_:)))
        lanCheckbox.frame = NSRect(x: 130, y: y, width: 320, height: 22)
        lanCheckbox.toolTip = "Off: the server binds 127.0.0.1 (this Mac only). On: it binds 0.0.0.0 and is reachable from other devices on your network."
        content.addSubview(lanCheckbox)
        y -= 24
        lanWarning = NSTextField(labelWithString: "")
        lanWarning.frame = NSRect(x: 130, y: y, width: 374, height: 28)
        lanWarning.font = NSFont.systemFont(ofSize: 10)
        lanWarning.textColor = .systemOrange
        (lanWarning.cell as? NSTextFieldCell)?.wraps = true
        content.addSubview(lanWarning)
        y -= 34

        // ── API key row ──
        addLabel("API key:", x: 16, y: y - 2, width: 110, to: content)
        apiKeyField = NSTextField(frame: NSRect(x: 130, y: y, width: 250, height: 22))
        apiKeyField.placeholderString = "none (open access)"
        apiKeyField.toolTip = "Optional bearer token required for API requests. The /health endpoint stays open so status checks keep working."
        apiKeyField.target = self
        apiKeyField.action = #selector(apiKeyEdited)
        content.addSubview(apiKeyField)
        let genBtn = NSButton(title: "Generate", target: self, action: #selector(generateApiKey))
        genBtn.bezelStyle = .rounded
        genBtn.frame = NSRect(x: 388, y: y - 1, width: 100, height: 24)
        genBtn.toolTip = "Generate a random 32-character key."
        content.addSubview(genBtn)
        y -= 34

        // ── Cache reuse row ──
        addLabel("Speed:", x: 16, y: y - 2, width: 110, to: content)
        cacheReuseCheckbox = NSButton(checkboxWithTitle: "Faster regenerate / chat (cache reuse)", target: nil, action: nil)
        cacheReuseCheckbox.frame = NSRect(x: 130, y: y, width: 330, height: 22)
        cacheReuseCheckbox.toolTip = "Reuse the KV cache across requests with a common prefix (--cache-reuse 256). Speeds up multi-turn chat and regenerate."
        content.addSubview(cacheReuseCheckbox)
        y -= 28

        // ── mlock row ──
        mlockCheckbox = NSButton(checkboxWithTitle: "Keep model in RAM (mlock)", target: nil, action: nil)
        mlockCheckbox.frame = NSRect(x: 130, y: y, width: 330, height: 22)
        mlockCheckbox.toolTip = "Keeps the model in RAM (no swapping). Only if you have free RAM for the whole model; limited effect with full GPU offload."
        content.addSubview(mlockCheckbox)
        y -= 28

        // ── Threads-batch row ──
        addLabel("Batch threads:", x: 16, y: y - 2, width: 110, to: content)
        threadsBatchField = NSTextField(frame: NSRect(x: 130, y: y, width: 80, height: 22))
        threadsBatchField.placeholderString = "auto"
        threadsBatchField.toolTip = "Threads for prompt/batch processing (-tb). Empty = auto. Modest effect with full GPU offload."
        content.addSubview(threadsBatchField)
        addHint("empty = auto", x: 220, y: y, to: content)
        y -= 36

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

        let nglInt = Int(sm.ngl) ?? 99
        nglSlider.doubleValue = Double(nglInt)
        nglLabel.stringValue = nglInt >= 99 ? "99 (All)" : sm.ngl

        if let idx = contextPopup.itemTitles.firstIndex(of: sm.context) {
            contextPopup.selectItem(at: idx)
            previousContextValue = sm.context
        } else if !sm.context.isEmpty {
            let customIdx = contextPopup.indexOfItem(withTitle: "Custom…")
            let insertIdx = customIdx > 0 ? customIdx - 1 : max(0, contextPopup.numberOfItems - 2)
            contextPopup.insertItem(withTitle: sm.context, at: insertIdx)
            contextPopup.selectItem(withTitle: sm.context)
            previousContextValue = sm.context
        }

        faCheckbox.state = (sm.fa == "1") ? .on : .off

        if let idx = cachePopup.itemTitles.firstIndex(of: sm.ctk) {
            cachePopup.selectItem(at: idx)
        }

        threadsField.stringValue = sm.threads == "0" ? "" : sm.threads
        batchField.stringValue = sm.batchSize == "2048" ? "" : sm.batchSize
        portField.stringValue = sm.port

        // Reflect the current bind address without changing it.
        originalHost = sm.host
        lanCheckbox.isEnabled = true
        lanCheckbox.title = "Allow access from local network"
        lanCheckbox.toolTip = "Off: the server binds 127.0.0.1 (this Mac only). On: it binds 0.0.0.0 and is reachable from other devices on your network."
        switch sm.host {
        case "0.0.0.0":
            lanCheckbox.state = .on
        case "127.0.0.1", "localhost", "":
            lanCheckbox.state = .off
        default:
            // A custom host — don't offer to flip it; preserve it on Apply.
            lanCheckbox.state = .off
            lanCheckbox.isEnabled = false
            lanCheckbox.title = "Custom host: \(sm.host)"
            lanCheckbox.toolTip = "server.conf sets a custom host (\(sm.host)); it is left unchanged."
        }
        apiKeyField.stringValue = sm.apiKey

        applyFaCacheGuard()
        updateLanWarning()
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

    private func currentContext() -> String {
        guard let title = contextPopup.titleOfSelectedItem, title != "Custom…" else {
            return previousContextValue
        }
        return title
    }

    // MARK: Profile presets & controls

    @objc private func profileChanged(_ sender: NSPopUpButton) {
        let profile = ["fast", "balanced", "accurate"][sender.indexOfSelectedItem]
        ServerManager.shared.applyProfile(profile)
        syncFromServerManager()
        updateRamEstimate()
    }

    @objc private func nglChanged(_ sender: NSSlider) {
        let v = Int(sender.doubleValue)
        nglLabel.stringValue = (v >= 99) ? "99 (All)" : String(v)
        updateRamEstimate()
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        applyFaCacheGuard()
        updateRamEstimate()
    }

    /// Enforces the Metal constraint that a quantized KV cache (q8_0/q4_0)
    /// requires Flash Attention. When FA is off, the quantized options are
    /// disabled and the selection is forced to f16.
    private func applyFaCacheGuard() {
        let faOn = faCheckbox.state == .on
        for item in cachePopup.itemArray where item.title == "q8_0" || item.title == "q4_0" {
            item.isEnabled = faOn
        }
        if !faOn {
            if cachePopup.titleOfSelectedItem != "f16" {
                cachePopup.selectItem(withTitle: "f16")
            }
            cacheHint.stringValue = "Quantized KV cache requires Flash Attention"
            cacheHint.textColor = .systemOrange
        } else {
            cacheHint.stringValue = "quant type (saves RAM)"
            cacheHint.textColor = .secondaryLabelColor
        }
    }

    @objc private func contextChanged(_ sender: NSPopUpButton) {
        if sender.titleOfSelectedItem == "Custom…" {
            promptCustomContext()
        } else if let title = sender.titleOfSelectedItem {
            previousContextValue = title
        }
        updateRamEstimate()
    }

    @objc private func cacheChanged(_ sender: NSPopUpButton) {
        updateRamEstimate()
    }

    // MARK: Network / API key

    @objc private func lanChanged(_ sender: NSButton) {
        updateLanWarning()
    }

    @objc private func apiKeyEdited(_ sender: NSTextField) {
        updateLanWarning()
    }

    @objc private func generateApiKey(_ sender: NSButton) {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            apiKeyField.stringValue = bytes.map { String(format: "%02x", $0) }.joined()
            updateLanWarning()
        }
    }

    private func currentHost() -> String {
        // A disabled checkbox means the config holds a custom host we preserve.
        if !lanCheckbox.isEnabled { return originalHost }
        return lanCheckbox.state == .on ? "0.0.0.0" : "127.0.0.1"
    }

    /// Populated only when the window opens, so changing the profile does not
    /// reset these three performance options.
    private func loadPerfControls() {
        let sm = ServerManager.shared
        cacheReuseCheckbox.state = (sm.cacheReuse != "0" && !sm.cacheReuse.isEmpty) ? .on : .off
        mlockCheckbox.state = (sm.mlock == "1") ? .on : .off
        threadsBatchField.stringValue = sm.threadsBatch
    }

    private func currentCacheReuse() -> String { cacheReuseCheckbox.state == .on ? "256" : "0" }
    private func currentMlock() -> String { mlockCheckbox.state == .on ? "1" : "0" }
    private func currentThreadsBatch() -> String {
        threadsBatchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func currentApiKey() -> String {
        apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateLanWarning() {
        if lanCheckbox.state == .on && currentApiKey().isEmpty {
            lanWarning.stringValue = "⚠️  LAN access is on without an API key — anyone on your network can use the server. Click Generate."
        } else {
            lanWarning.stringValue = ""
        }
    }

    private func promptCustomContext() {
        let alert = NSAlert()
        alert.messageText = "Custom Context Size"
        alert.informativeText = "Enter context length in tokens (e.g. 65536, 131072, 262144):"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.placeholderString = "e.g. 262144"
        input.stringValue = previousContextValue
        alert.accessoryView = input
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input

        if alert.runModal() == .alertFirstButtonReturn {
            let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let num = Int(trimmed), num >= 512 {
                let strVal = String(num)
                if !contextPopup.itemTitles.contains(strVal) {
                    let customIdx = contextPopup.indexOfItem(withTitle: "Custom…")
                    let insertIdx = customIdx > 0 ? customIdx - 1 : max(0, contextPopup.numberOfItems - 2)
                    contextPopup.insertItem(withTitle: strVal, at: insertIdx)
                }
                contextPopup.selectItem(withTitle: strVal)
                previousContextValue = strVal
                updateRamEstimate()
                return
            }
        }
        contextPopup.selectItem(withTitle: previousContextValue)
        updateRamEstimate()
    }

    // MARK: RAM estimate

    /// Bytes per KV-cache element for a cache type.
    private func kvBytesPerElement(_ t: String) -> Double {
        switch t {
        case "q4_0": return 0.5625   // 4.5 bits
        case "q8_0": return 1.0625   // 8.5 bits
        default:     return 2.0      // f16
        }
    }

    private func updateRamEstimate() {
        let sm = ServerManager.shared
        let modelSize = (try? FileManager.default.attributesOfItem(atPath: sm.modelPath)[.size] as? Int64) ?? 0

        if modelSize == 0 {
            ramLabel.stringValue = "No active model detected. Set a model in the Models window first."
            ramLabel.textColor = .secondaryLabelColor
            return
        }

        let modelGB = Double(modelSize) / 1_000_000_000.0
        let ctxVal = Int(currentContext()) ?? 8192
        let cacheType = currentCtk()

        // "Available" for a GPU-offloaded model is the Metal working-set budget
        // (Metal only gets a fraction of RAM), falling back to 70% of physical.
        let availBytes: Double
        if let dev = MTLCreateSystemDefaultDevice(), dev.recommendedMaxWorkingSetSize > 0 {
            availBytes = Double(dev.recommendedMaxWorkingSetSize)
        } else {
            availBytes = Double(ProcessInfo.processInfo.physicalMemory) * 0.70
        }
        let availGB = availBytes / 1_000_000_000.0

        // Precise KV-cache size from the GGUF header when we can read it.
        var ctxGB: Double
        var approx: Bool
        var modelCtx: Int? = nil
        if let meta = GGUFInfo.read(path: sm.modelPath), meta.isComplete,
           let nLayer = meta.blockCount, let nKV = meta.headCountKV, let kDim = meta.effectiveKeyLength {
            let kvBytes = 2.0 * Double(nLayer) * Double(nKV) * Double(kDim) * Double(ctxVal) * kvBytesPerElement(cacheType)
            ctxGB = kvBytes / 1_000_000_000.0
            approx = false
            modelCtx = meta.contextLength
        } else {
            // Fallback: the old heuristic (~30% of model at 8k), clearly marked.
            let ctxFactor = Double(ctxVal) / 8192.0
            let cacheFactor: Double = (cacheType == "q4_0") ? 0.25 : (cacheType == "q8_0" ? 0.5 : 1.0)
            ctxGB = modelGB * 0.3 * ctxFactor * cacheFactor
            approx = true
        }

        let neededGB = modelGB + ctxGB
        let suffix = approx ? " (approx.)" : ""
        var ctxWarn = ""
        if let mc = modelCtx, ctxVal > mc {
            ctxWarn = String(format: "  ⚠︎ context %d exceeds model max %d", ctxVal, mc)
        }

        if neededGB > availGB {
            ramLabel.stringValue = String(format: "⚠️  ~%.1f GB needed, %.0f GB available — may crash or swap!%@%@", neededGB, availGB, suffix, ctxWarn)
            ramLabel.textColor = .systemRed
        } else if neededGB > availGB * 0.8 {
            ramLabel.stringValue = String(format: "⚠️  ~%.1f GB needed, %.0f GB available — close other apps%@%@", neededGB, availGB, suffix, ctxWarn)
            ramLabel.textColor = .systemOrange
        } else {
            ramLabel.stringValue = String(format: "%.1f GB model + %.1f GB ctx ≈ %.1f GB needed, %.0f GB available ✓%@%@", modelGB, ctxGB, neededGB, availGB, suffix, ctxWarn)
            ramLabel.textColor = ctxWarn.isEmpty ? .secondaryLabelColor : .systemOrange
        }
    }

    // MARK: Actions

    /// Field must be empty (→ caller's default/auto) or all digits.
    private func validateNumericField(_ value: String, name: String, range: ClosedRange<Int>? = nil) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return true }
        guard v.allSatisfy({ $0.isNumber }), let n = Int(v) else {
            showInvalid(name, "must be a whole number.")
            return false
        }
        if let range = range, !range.contains(n) {
            showInvalid(name, "must be between \(range.lowerBound) and \(range.upperBound).")
            return false
        }
        return true
    }

    private func showInvalid(_ name: String, _ why: String) {
        let alert = NSAlert()
        alert.messageText = "Invalid \(name)"
        alert.informativeText = "\(name) \(why) The settings were not saved."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func applyClicked() {
        // Validate numeric fields before writing anything (server.conf is
        // sourced, so only digits are allowed through).
        guard validateNumericField(threadsField.stringValue, name: "Threads"),
              validateNumericField(batchField.stringValue, name: "Batch"),
              validateNumericField(threadsBatchField.stringValue, name: "Batch threads"),
              validateNumericField(portField.stringValue, name: "Port", range: 1024...65535),
              validateNumericField(currentContext(), name: "Context")
        else { return }

        do {
            // Belt-and-suspenders guard: a quantized KV cache requires Flash
            // Attention on Metal. If FA is off, persist f16 regardless of the
            // (disabled) popup selection.
            let faOn = currentFa() == "1"
            let cacheType = faOn ? currentCtk() : "f16"
            try ModelManager.shared.saveSettings(
                ngl: currentNgl(),
                fa: currentFa(),
                ctk: cacheType,
                ctv: cacheType,
                threads: threadsField.stringValue.isEmpty ? "0" : threadsField.stringValue,
                batchSize: batchField.stringValue.isEmpty ? "2048" : batchField.stringValue,
                context: currentContext(),
                port: portField.stringValue.isEmpty ? "8080" : portField.stringValue,
                host: currentHost(),
                apiKey: currentApiKey(),
                cacheReuse: currentCacheReuse(),
                mlock: currentMlock(),
                threadsBatch: currentThreadsBatch(),
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
                    // ioreg "Device Utilization %" is not exposed on every GPU,
                    // so label it approximate and omit it when unavailable.
                    let gpuText = gpu != nil ? String(format: " · GPU ~%.0f%% (approx)", gpu!) : ""
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
