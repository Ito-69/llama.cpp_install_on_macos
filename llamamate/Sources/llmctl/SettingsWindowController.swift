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
    private var applyButton: NSButton!

    private override init() { super.init() }

    func showWindow() {
        if window == nil { buildWindow() }
        syncFromServerManager()
        updateRamEstimate()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Window

    private func buildWindow() {
        let w = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
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

        var y: CGFloat = 420

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
        nglSlider.target = self
        nglSlider.action = #selector(nglChanged(_:))
        content.addSubview(nglSlider)
        nglLabel = NSTextField(labelWithString: "40")
        nglLabel.frame = NSRect(x: 400, y: y - 2, width: 40, height: 18)
        nglLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        nglLabel.alignment = .right
        content.addSubview(nglLabel)
        y -= 34

        // ── Context row ──
        addLabel("Context:", x: 16, y: y - 2, width: 110, to: content)
        contextPopup = NSPopUpButton(frame: NSRect(x: 130, y: y, width: 150, height: 24))
        let ctxValues = ["2048", "4096", "8192", "16384", "32768"]
        contextPopup.addItems(withTitles: ctxValues)
        content.addSubview(contextPopup)
        addHint("tokens", x: 290, y: y, to: content)
        y -= 34

        // ── Flash attention row ──
        addLabel("Flash attn:", x: 16, y: y - 2, width: 110, to: content)
        faCheckbox = NSButton(checkboxWithTitle: "Enabled (faster inference)", target: self, action: #selector(checkboxChanged(_:)))
        faCheckbox.frame = NSRect(x: 130, y: y, width: 200, height: 22)
        content.addSubview(faCheckbox)
        y -= 34

        // ── KV cache row ──
        addLabel("KV cache:", x: 16, y: y - 2, width: 110, to: content)
        cachePopup = NSPopUpButton(frame: NSRect(x: 130, y: y, width: 150, height: 24))
        cachePopup.addItems(withTitles: ["f16", "q8_0", "q4_0"])
        content.addSubview(cachePopup)
        addHint("quant type (saves RAM)", x: 290, y: y, to: content)
        y -= 34

        // ── Threads row ──
        addLabel("Threads:", x: 16, y: y - 2, width: 110, to: content)
        threadsField = NSTextField(frame: NSRect(x: 130, y: y, width: 80, height: 22))
        threadsField.placeholderString = "0"
        content.addSubview(threadsField)
        let pcores = ServerManager.perfLevelCores()
        let threadHint = pcores > 0 ? "0 = auto (\(pcores) P-cores detected)" : "0 = auto"
        addHint(threadHint, x: 220, y: y, to: content)
        y -= 34

        // ── Batch size row ──
        addLabel("Batch:", x: 16, y: y - 2, width: 110, to: content)
        batchField = NSTextField(frame: NSRect(x: 130, y: y, width: 80, height: 22))
        batchField.placeholderString = "512"
        content.addSubview(batchField)
        addHint("tokens per batch", x: 220, y: y, to: content)
        y -= 34

        // ── Port row ──
        addLabel("Port:", x: 16, y: y - 2, width: 110, to: content)
        portField = NSTextField(frame: NSRect(x: 130, y: y, width: 100, height: 22))
        portField.placeholderString = "8080"
        content.addSubview(portField)
        y -= 34

        // ── Separator ──
        let sep2 = separator(frame: NSRect(x: 16, y: y, width: 488, height: 1))
        content.addSubview(sep2)
        y -= 20

        // ── RAM estimate ──
        ramLabel = NSTextField(wrappingLabelWithString: "")
        ramLabel.frame = NSRect(x: 16, y: y, width: 488, height: 36)
        ramLabel.font = NSFont.systemFont(ofSize: 11)
        content.addSubview(ramLabel)
        y -= 60

        // ── Buttons ──
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: 520 - 16 - 130 - 8 - 80, y: 16, width: 80, height: 24)
        cancelButton.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(cancelButton)

        applyButton = NSButton(title: "Apply & Restart", target: self, action: #selector(applyClicked))
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.frame = NSRect(x: 520 - 16 - 130, y: 16, width: 130, height: 24)
        applyButton.autoresizingMask = [.minXMargin, .minYMargin]
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
        // re-sync in case user opens again
    }
}
