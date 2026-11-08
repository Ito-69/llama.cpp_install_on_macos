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
    private var effortPopup: NSPopUpButton!
    private var budgetPopup: NSPopUpButton!
    private var parallelPopup: NSPopUpButton!
    private var mtpPopup: NSPopUpButton!
    private var mtpDraftPopup: NSPopUpButton!
    private var mtpHint: NSTextField!
    private var extraArgsField: NSTextField!
    private var tabView: NSTabView!
    private var networkTab: NSTabViewItem?
    private static let selectedTabKey = "settingsSelectedTab"
    private var ramLabel: NSTextField!
    private var diagnosticsLabel: NSTextField!
    private var usageLabel: NSTextField!
    private var applyButton: NSButton!
    private var usageTimer: Timer?
    private var lastSelfCpuTime: Double = 0
    private var lastSelfSampleTime: TimeInterval = 0
    private var previousContextValue = "8192"
    private var originalHost = "127.0.0.1"

    /// Reasoning effort: (menu title, server.conf value).
    static let effortOptions: [(title: String, value: String)] = [
        ("Default (model decides)", "default"),
        ("Low", "low"),
        ("Medium", "medium"),
        ("High", "high"),
    ]

    /// Thinking token limit: (menu title, server.conf value). "" = unlimited.
    static let budgetOptions: [(title: String, value: String)] = [
        ("Unlimited", ""),
        ("Off (no thinking)", "0"),
        ("512 tokens", "512"),
        ("1024 tokens", "1024"),
        ("2048 tokens", "2048"),
        ("4096 tokens", "4096"),
        ("8192 tokens", "8192"),
    ]

    /// Parallel request slots: (menu title, server.conf value).
    /// Empty in server.conf means 1 (the default); "0" = llama.cpp auto.
    static let parallelOptions: [(title: String, value: String)] = [
        ("1 — single user (default)", "1"),
        ("Auto (llama.cpp decides)", "0"),
        ("2", "2"),
        ("4", "4"),
    ]

    /// MTP speculative decoding: (menu title, server.conf value).
    static let mtpOptions: [(title: String, value: String)] = [
        ("Auto (if model supports it)", "auto"),
        ("Off", "off"),
    ]

    static let mtpDraftValues = ["2", "3", "4", "5", "6"]

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
        let width: CGFloat = 540
        let height: CGFloat = 600
        let w = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
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

        // ── Header + profile (the preset spans several tabs) ──
        var y: CGFloat = height - 36
        let header = NSTextField(labelWithString: "Server Configuration")
        header.font = NSFont.boldSystemFont(ofSize: 13)
        header.frame = NSRect(x: 16, y: y, width: width - 32, height: 18)
        content.addSubview(header)
        y -= 34

        addLabel("Profile:", x: 16, y: y - 2, width: 110, to: content)
        profilePopup = NSPopUpButton(frame: NSRect(x: 130, y: y, width: 200, height: 24))
        profilePopup.addItems(withTitles: ["Fast", "Balanced", "Accurate"])
        profilePopup.toolTip = "Preset combinations of GPU layers, flash attention and KV cache quantization."
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged(_:))
        content.addSubview(profilePopup)
        addHint("GPU layers, flash attn, KV cache", x: 340, y: y, to: content)

        // ── Tabs ──
        let bottomPanelTop: CGFloat = 168
        let tabTop = y - 10
        tabView = NSTabView(frame: NSRect(x: 12, y: bottomPanelTop, width: width - 24, height: tabTop - bottomPanelTop))
        tabView.autoresizingMask = [.width, .height]
        content.addSubview(tabView)

        let rowStep: CGFloat = 36
        let cx: CGFloat = 124   // controls column inside a tab

        // Model
        let modelView = FlippedView()
        var ty: CGFloat = 16
        rowLabel("GPU layers:", y: ty, in: modelView)
        nglSlider = NSSlider(frame: NSRect(x: cx, y: ty, width: 250, height: 24))
        nglSlider.minValue = 0
        nglSlider.maxValue = 99
        nglSlider.numberOfTickMarks = 100
        nglSlider.allowsTickMarkValuesOnly = false
        nglSlider.toolTip = "Number of transformer layers offloaded to the GPU. 99 = maximum GPU acceleration (all layers on Metal). 0 = CPU only."
        nglSlider.target = self
        nglSlider.action = #selector(nglChanged(_:))
        modelView.addSubview(nglSlider)
        nglLabel = NSTextField(labelWithString: "99")
        nglLabel.frame = NSRect(x: cx + 258, y: ty + 3, width: 90, height: 18)
        nglLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        nglLabel.alignment = .left
        nglLabel.toolTip = "Current GPU layers value (99 = all layers on Metal GPU)."
        modelView.addSubview(nglLabel)
        ty += rowStep

        rowLabel("Context:", y: ty, in: modelView)
        contextPopup = NSPopUpButton(frame: NSRect(x: cx, y: ty, width: 150, height: 24))
        contextPopup.addItems(withTitles: SettingsWindowController.standardContextValues)
        contextPopup.menu?.addItem(NSMenuItem.separator())
        contextPopup.addItem(withTitle: "Custom…")
        contextPopup.target = self
        contextPopup.action = #selector(contextChanged(_:))
        contextPopup.toolTip = "Maximum number of tokens the model can keep in memory. Larger context uses more RAM."
        modelView.addSubview(contextPopup)
        rowHint("tokens", x: cx + 160, y: ty, in: modelView)
        ty += rowStep

        rowLabel("Flash attn:", y: ty, in: modelView)
        faCheckbox = NSButton(checkboxWithTitle: "Enabled (faster inference)", target: self, action: #selector(checkboxChanged(_:)))
        faCheckbox.frame = NSRect(x: cx, y: ty + 1, width: 260, height: 22)
        faCheckbox.toolTip = "Flash Attention speeds up inference on most models. Leave enabled unless the model crashes."
        modelView.addSubview(faCheckbox)
        ty += rowStep

        rowLabel("KV cache:", y: ty, in: modelView)
        cachePopup = NSPopUpButton(frame: NSRect(x: cx, y: ty, width: 150, height: 24))
        cachePopup.addItems(withTitles: ["f16", "q8_0", "q4_0"])
        cachePopup.autoenablesItems = false
        cachePopup.target = self
        cachePopup.action = #selector(cacheChanged(_:))
        cachePopup.toolTip = "Quantization of the key/value cache. Lower precision = less RAM, but may reduce quality. Quantized types require Flash Attention."
        modelView.addSubview(cachePopup)
        cacheHint = rowHint("quant type (saves RAM)", x: cx + 160, y: ty, in: modelView, width: 230)

        // Performance
        let perfView = FlippedView()
        ty = 16
        rowLabel("Threads:", y: ty, in: perfView)
        threadsField = NSTextField(frame: NSRect(x: cx, y: ty + 1, width: 80, height: 22))
        threadsField.placeholderString = "0"
        threadsField.toolTip = "CPU threads used for generation. 0 = auto: llama.cpp picks the performance cores."
        perfView.addSubview(threadsField)
        let pcores = ServerManager.perfLevelCores()
        rowHint(pcores > 0 ? "0 = auto (\(pcores) P-cores detected)" : "0 = auto", x: cx + 90, y: ty, in: perfView, width: 260)
        ty += rowStep

        rowLabel("Batch:", y: ty, in: perfView)
        batchField = NSTextField(frame: NSRect(x: cx, y: ty + 1, width: 80, height: 22))
        batchField.placeholderString = "2048"
        batchField.toolTip = "Number of tokens processed per logical batch. 2048 is recommended for Apple Silicon Metal."
        perfView.addSubview(batchField)
        rowHint("tokens (2048 rec. for Metal)", x: cx + 90, y: ty, in: perfView, width: 260)
        ty += rowStep

        rowLabel("Batch threads:", y: ty, in: perfView)
        threadsBatchField = NSTextField(frame: NSRect(x: cx, y: ty + 1, width: 80, height: 22))
        threadsBatchField.placeholderString = "auto"
        threadsBatchField.toolTip = "Threads for prompt/batch processing (-tb). Empty = auto. Modest effect with full GPU offload."
        perfView.addSubview(threadsBatchField)
        rowHint("empty = auto", x: cx + 90, y: ty, in: perfView)
        ty += rowStep

        rowLabel("Speed:", y: ty, in: perfView)
        cacheReuseCheckbox = NSButton(checkboxWithTitle: "Faster regenerate / chat (cache reuse)", target: nil, action: nil)
        cacheReuseCheckbox.frame = NSRect(x: cx, y: ty + 1, width: 340, height: 22)
        cacheReuseCheckbox.toolTip = "Reuse the KV cache across requests with a common prefix (--cache-reuse 256). Speeds up multi-turn chat and regenerate."
        perfView.addSubview(cacheReuseCheckbox)
        ty += 28
        mlockCheckbox = NSButton(checkboxWithTitle: "Keep model in RAM (mlock)", target: nil, action: nil)
        mlockCheckbox.frame = NSRect(x: cx, y: ty + 1, width: 340, height: 22)
        mlockCheckbox.toolTip = "Keeps the model in RAM (no swapping). Only if you have free RAM for the whole model; limited effect with full GPU offload."
        perfView.addSubview(mlockCheckbox)
        ty += rowStep

        rowLabel("Parallel:", y: ty, in: perfView)
        parallelPopup = NSPopUpButton(frame: NSRect(x: cx, y: ty, width: 200, height: 24))
        parallelPopup.addItems(withTitles: SettingsWindowController.parallelOptions.map { $0.title })
        parallelPopup.toolTip = "How many requests the server handles at once (-np). 1 (default) is fastest for a single user and uses the least memory, especially with MTP; extra requests wait their turn. Choose more, or Auto (llama.cpp decides, usually 4), if several apps or people use the server at the same time (e.g. Open WebUI generates titles in parallel)."
        perfView.addSubview(parallelPopup)
        rowHint("requests at once", x: cx + 210, y: ty, in: perfView, width: 150)
        ty += rowStep

        rowLabel("MTP:", y: ty, in: perfView)
        mtpPopup = NSPopUpButton(frame: NSRect(x: cx, y: ty, width: 200, height: 24))
        mtpPopup.addItems(withTitles: SettingsWindowController.mtpOptions.map { $0.title })
        mtpPopup.target = self
        mtpPopup.action = #selector(mtpChanged(_:))
        mtpPopup.toolTip = "Multi-token prediction: models that ship MTP heads can draft several tokens per step (--spec-type draft-mtp), often ~2x faster generation. The main model checks every draft, so output quality is unchanged."
        perfView.addSubview(mtpPopup)
        mtpDraftPopup = NSPopUpButton(frame: NSRect(x: cx + 208, y: ty, width: 60, height: 24))
        mtpDraftPopup.addItems(withTitles: SettingsWindowController.mtpDraftValues)
        mtpDraftPopup.toolTip = "Draft tokens per step (--spec-draft-n-max). 4 is a good default; more can be slower when drafts get rejected."
        perfView.addSubview(mtpDraftPopup)
        mtpHint = rowHint("", x: cx + 274, y: ty, in: perfView, width: 110)

        // Network
        let netView = FlippedView()
        ty = 16
        rowLabel("Port:", y: ty, in: netView)
        portField = NSTextField(frame: NSRect(x: cx, y: ty + 1, width: 100, height: 22))
        portField.placeholderString = "8080"
        portField.toolTip = "TCP port for the llama-server HTTP API and WebUI."
        netView.addSubview(portField)
        ty += rowStep

        rowLabel("Network:", y: ty, in: netView)
        lanCheckbox = NSButton(checkboxWithTitle: "Allow access from local network",
                               target: self, action: #selector(lanChanged(_:)))
        lanCheckbox.frame = NSRect(x: cx, y: ty + 1, width: 340, height: 22)
        lanCheckbox.toolTip = "Off: the server binds 127.0.0.1 (this Mac only). On: it binds 0.0.0.0 and is reachable from other devices on your network."
        netView.addSubview(lanCheckbox)
        ty += 26
        lanWarning = NSTextField(wrappingLabelWithString: "")
        lanWarning.frame = NSRect(x: cx, y: ty, width: 370, height: 30)
        lanWarning.font = NSFont.systemFont(ofSize: 10)
        lanWarning.textColor = .systemOrange
        netView.addSubview(lanWarning)
        ty += 40

        rowLabel("API key:", y: ty, in: netView)
        apiKeyField = NSTextField(frame: NSRect(x: cx, y: ty + 1, width: 250, height: 22))
        apiKeyField.placeholderString = "none (open access)"
        apiKeyField.toolTip = "Optional bearer token required for API requests. The /health endpoint stays open so status checks keep working."
        apiKeyField.target = self
        apiKeyField.action = #selector(apiKeyEdited)
        netView.addSubview(apiKeyField)
        let genBtn = NSButton(title: "Generate", target: self, action: #selector(generateApiKey))
        genBtn.bezelStyle = .rounded
        genBtn.frame = NSRect(x: cx + 258, y: ty, width: 100, height: 24)
        genBtn.toolTip = "Generate a random 32-character key."
        netView.addSubview(genBtn)
        ty += 28
        rowHint("Clients send it as:  Authorization: Bearer <key>", x: cx, y: ty, in: netView, width: 370)

        // Advanced
        let advView = FlippedView()
        ty = 16
        rowLabel("Reasoning:", y: ty, in: advView)
        effortPopup = NSPopUpButton(frame: NSRect(x: cx, y: ty, width: 200, height: 24))
        effortPopup.addItems(withTitles: SettingsWindowController.effortOptions.map { $0.title })
        effortPopup.toolTip = "Reasoning effort passed to the model's chat template (--reasoning-effort). Only models trained with effort levels use it (e.g. gpt-oss); others ignore it — use Thinking limit for those."
        advView.addSubview(effortPopup)
        rowHint("models with effort levels", x: cx + 210, y: ty, in: advView, width: 170)
        ty += rowStep

        rowLabel("Thinking limit:", y: ty, in: advView)
        budgetPopup = NSPopUpButton(frame: NSRect(x: cx, y: ty, width: 200, height: 24))
        budgetPopup.addItems(withTitles: SettingsWindowController.budgetOptions.map { $0.title })
        budgetPopup.toolTip = "Maximum tokens a thinking model may spend reasoning before it must answer (--reasoning-budget). Works for Qwen3, DeepSeek-R1 and other thinking models. Off = answer without thinking."
        advView.addSubview(budgetPopup)
        rowHint("any thinking model", x: cx + 210, y: ty, in: advView, width: 170)
        ty += rowStep

        rowLabel("Extra flags:", y: ty, in: advView)
        extraArgsField = NSTextField(frame: NSRect(x: cx, y: ty + 1, width: 370, height: 22))
        extraArgsField.placeholderString = "e.g. -np 1 --spec-type draft-mtp"
        extraArgsField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        extraArgsField.toolTip = "Additional llama-server flags, appended last (EXTRA_ARGS). Space-separated; values with spaces are not supported. Saved in ~/.config/llama/server.local.conf, which LlamaMate never overwrites, so they survive updates. An unknown flag stops the server — check View Server Logs…"
        advView.addSubview(extraArgsField)
        ty += 26
        rowHint("Kept across updates (server.local.conf). Unknown flags stop the server.", x: cx, y: ty, in: advView, width: 370)

        for (label, view) in [("Model", modelView as NSView), ("Performance", perfView), ("Network", netView), ("Advanced", advView)] {
            let item = NSTabViewItem(identifier: label)
            item.label = label
            item.view = view
            tabView.addTabViewItem(item)
            if label == "Network" { networkTab = item }
        }
        let savedTab = UserDefaults.standard.integer(forKey: SettingsWindowController.selectedTabKey)
        if savedTab >= 0 && savedTab < tabView.numberOfTabViewItems {
            tabView.selectTabViewItem(at: savedTab)
        }

        // ── Bottom panel: visible from every tab ──
        let sep = separator(frame: NSRect(x: 16, y: bottomPanelTop - 8, width: width - 32, height: 1))
        content.addSubview(sep)

        ramLabel = NSTextField(wrappingLabelWithString: "")
        // Two lines: the estimate, plus an optional context warning below it.
        ramLabel.frame = NSRect(x: 16, y: 114, width: width - 32, height: 40)
        ramLabel.font = NSFont.systemFont(ofSize: 11)
        content.addSubview(ramLabel)

        diagnosticsLabel = NSTextField(wrappingLabelWithString: systemDiagnostics())
        diagnosticsLabel.frame = NSRect(x: 16, y: 90, width: width - 32, height: 18)
        diagnosticsLabel.font = NSFont.systemFont(ofSize: 11)
        diagnosticsLabel.textColor = .secondaryLabelColor
        content.addSubview(diagnosticsLabel)

        usageLabel = NSTextField(wrappingLabelWithString: "Gathering usage…")
        usageLabel.frame = NSRect(x: 16, y: 52, width: width - 32, height: 34)
        usageLabel.font = NSFont.systemFont(ofSize: 11)
        usageLabel.textColor = .secondaryLabelColor
        content.addSubview(usageLabel)

        // ── Buttons ──
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: width - 16 - 130 - 8 - 80, y: 14, width: 80, height: 24)
        cancelButton.autoresizingMask = [.minXMargin, .maxYMargin]
        cancelButton.toolTip = "Close without saving changes."
        content.addSubview(cancelButton)

        applyButton = NSButton(title: "Apply & Restart", target: self, action: #selector(applyClicked))
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.frame = NSRect(x: width - 16 - 130, y: 14, width: 130, height: 24)
        applyButton.autoresizingMask = [.minXMargin, .maxYMargin]
        applyButton.toolTip = "Save settings and restart the server if anything changed."
        content.addSubview(applyButton)

        w.contentView = content
        window = w
    }

    // MARK: Tab layout helpers (tab views are flipped: y grows downwards)

    private func rowLabel(_ text: String, y: CGFloat, in view: NSView) {
        let lbl = NSTextField(labelWithString: text)
        lbl.frame = NSRect(x: 4, y: y + 3, width: 112, height: 18)
        lbl.font = NSFont.systemFont(ofSize: 12)
        lbl.alignment = .right
        view.addSubview(lbl)
    }

    @discardableResult
    private func rowHint(_ text: String, x: CGFloat, y: CGFloat, in view: NSView, width: CGFloat = 200) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.frame = NSRect(x: x, y: y + 4, width: width, height: 18)
        lbl.font = NSFont.systemFont(ofSize: 11)
        lbl.textColor = .secondaryLabelColor
        lbl.lineBreakMode = .byTruncatingTail
        view.addSubview(lbl)
        return lbl
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

        // Same for effort: keep a hand-edited level (e.g. xhigh) as its own entry.
        while effortPopup.numberOfItems > SettingsWindowController.effortOptions.count {
            effortPopup.removeItem(at: effortPopup.numberOfItems - 1)
        }
        if let idx = SettingsWindowController.effortOptions.firstIndex(where: { $0.value == sm.reasoningEffort }) {
            effortPopup.selectItem(at: idx)
        } else if ["minimal", "xhigh", "max"].contains(sm.reasoningEffort) {
            effortPopup.addItem(withTitle: sm.reasoningEffort.capitalized)
            effortPopup.lastItem?.representedObject = sm.reasoningEffort
            effortPopup.selectItem(at: effortPopup.numberOfItems - 1)
        } else {
            effortPopup.selectItem(at: 0)
        }

        // Restore the thinking limit; keep a hand-edited value that isn't in
        // the list as its own entry so Apply never changes it silently.
        while budgetPopup.numberOfItems > SettingsWindowController.budgetOptions.count {
            budgetPopup.removeItem(at: budgetPopup.numberOfItems - 1)
        }
        if let idx = SettingsWindowController.budgetOptions.firstIndex(where: { $0.value == sm.reasoningBudget }) {
            budgetPopup.selectItem(at: idx)
        } else if sm.reasoningBudget.allSatisfy({ $0.isNumber }) {
            budgetPopup.addItem(withTitle: "\(sm.reasoningBudget) tokens")
            budgetPopup.lastItem?.representedObject = sm.reasoningBudget
            budgetPopup.selectItem(at: budgetPopup.numberOfItems - 1)
        } else {
            budgetPopup.selectItem(at: 0)
        }

        // Parallel slots (keep a hand-edited value as its own entry).
        while parallelPopup.numberOfItems > SettingsWindowController.parallelOptions.count {
            parallelPopup.removeItem(at: parallelPopup.numberOfItems - 1)
        }
        let parallel = sm.parallel.isEmpty ? "1" : sm.parallel
        if let idx = SettingsWindowController.parallelOptions.firstIndex(where: { $0.value == parallel }) {
            parallelPopup.selectItem(at: idx)
        } else if parallel.allSatisfy({ $0.isNumber }) {
            parallelPopup.addItem(withTitle: parallel)
            parallelPopup.lastItem?.representedObject = parallel
            parallelPopup.selectItem(at: parallelPopup.numberOfItems - 1)
        } else {
            parallelPopup.selectItem(at: 0)
        }

        // MTP mode and draft count.
        mtpPopup.selectItem(at: sm.mtp == "off" ? 1 : 0)
        while mtpDraftPopup.numberOfItems > SettingsWindowController.mtpDraftValues.count {
            mtpDraftPopup.removeItem(at: mtpDraftPopup.numberOfItems - 1)
        }
        if let idx = SettingsWindowController.mtpDraftValues.firstIndex(of: sm.mtpDraft) {
            mtpDraftPopup.selectItem(at: idx)
        } else if sm.mtpDraft.allSatisfy({ $0.isNumber }), !sm.mtpDraft.isEmpty {
            mtpDraftPopup.addItem(withTitle: sm.mtpDraft)
            mtpDraftPopup.lastItem?.representedObject = sm.mtpDraft
            mtpDraftPopup.selectItem(at: mtpDraftPopup.numberOfItems - 1)
        } else {
            mtpDraftPopup.selectItem(withTitle: "4")
        }
        updateMtpControls()

        extraArgsField.stringValue = ConfigManager.shared.readExtraArgs()
    }

    private func currentParallel() -> String {
        let i = parallelPopup.indexOfSelectedItem
        let opts = SettingsWindowController.parallelOptions
        if i >= 0 && i < opts.count { return opts[i].value }
        return (parallelPopup.selectedItem?.representedObject as? String) ?? ""
    }

    private func currentMtp() -> String {
        let i = mtpPopup.indexOfSelectedItem
        let opts = SettingsWindowController.mtpOptions
        return (i >= 0 && i < opts.count) ? opts[i].value : "auto"
    }

    private func currentMtpDraft() -> String {
        if let custom = mtpDraftPopup.selectedItem?.representedObject as? String { return custom }
        return mtpDraftPopup.titleOfSelectedItem ?? "4"
    }

    @objc private func mtpChanged(_ sender: NSPopUpButton) {
        updateMtpControls()
    }

    /// Shows whether the active model has MTP heads and enables the draft
    /// selector only when MTP will actually be used.
    private func updateMtpControls() {
        let hasMTP = ConfigManager.detectMTP(modelPath: ServerManager.shared.modelPath) == "1"
        mtpHint.stringValue = hasMTP ? "✓ model has MTP" : "no MTP heads"
        mtpHint.textColor = hasMTP ? .systemGreen : .secondaryLabelColor
        mtpDraftPopup.isEnabled = hasMTP && currentMtp() != "off"
    }

    private func currentReasoningEffort() -> String {
        let i = effortPopup.indexOfSelectedItem
        let opts = SettingsWindowController.effortOptions
        if i >= 0 && i < opts.count { return opts[i].value }
        return (effortPopup.selectedItem?.representedObject as? String) ?? "default"
    }

    private func currentReasoningBudget() -> String {
        let i = budgetPopup.indexOfSelectedItem
        let opts = SettingsWindowController.budgetOptions
        if i >= 0 && i < opts.count { return opts[i].value }
        return (budgetPopup.selectedItem?.representedObject as? String) ?? ""
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
        let warn = lanCheckbox.state == .on && currentApiKey().isEmpty
        lanWarning.stringValue = warn
            ? "⚠️  LAN access is on without an API key — anyone on your network can use the server. Click Generate."
            : ""
        // Visible from the other tabs too.
        networkTab?.label = warn ? "Network ⚠︎" : "Network"
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
           let kvHeads = meta.totalKVHeads, let kDim = meta.effectiveKeyLength {
            // K and V, for every KV head of every layer that keeps a KV cache
            // (hybrid models skip their recurrent layers).
            let kvBytes = 2.0 * Double(kvHeads) * Double(kDim) * Double(ctxVal) * kvBytesPerElement(cacheType)
            ctxGB = kvBytes / 1_000_000_000.0
            approx = meta.isApproximate
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
            ctxWarn = String(format: "\n⚠︎ Context %d is above this model's trained limit (%d) — answers may get worse.", ctxVal, mc)
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

        // Extra flags must start with a flag ("-x" / "--xyz"); values follow.
        let extraArgs = extraArgsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extraArgs.isEmpty && !extraArgs.hasPrefix("-") {
            showInvalid("Extra flags", "must start with a llama-server flag, for example \"-np 1\".")
            return
        }

        do {
            // Belt-and-suspenders guard: a quantized KV cache requires Flash
            // Attention on Metal. If FA is off, persist f16 regardless of the
            // (disabled) popup selection.
            let faOn = currentFa() == "1"
            let cacheType = faOn ? currentCtk() : "f16"
            // Written first so the restart below picks the new flags up.
            let extraChanged = try ConfigManager.shared.writeExtraArgs(extraArgs)
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
                reasoningEffort: currentReasoningEffort(),
                reasoningBudget: currentReasoningBudget(),
                mtp: currentMtp(),
                mtpDraft: currentMtpDraft(),
                parallel: currentParallel(),
                profile: currentProfile(),
                forceRestart: extraChanged
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
        if let item = tabView?.selectedTabViewItem {
            UserDefaults.standard.set(tabView.indexOfTabViewItem(item), forKey: SettingsWindowController.selectedTabKey)
        }
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

/// Plain view with a top-left origin, so tab rows can be laid out from the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
