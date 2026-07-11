import AppKit
import Foundation

// MARK: - Curated Shortlist

struct CuratedModel {
    let id: String
    let displayName: String
    let sizeGB: String
    let description: String
}

let curatedModels: [CuratedModel] = [
    CuratedModel(id: "bartowski/Qwen2.5-7B-Instruct-GGUF",
                 displayName: "Qwen2.5 7B Instruct",
                 sizeGB: "4.7",
                 description: "Fast, good quality. Default."),
    CuratedModel(id: "bartowski/Qwen2.5-14B-Instruct-GGUF",
                 displayName: "Qwen2.5 14B Instruct",
                 sizeGB: "8.4",
                 description: "Balanced quality and speed."),
    CuratedModel(id: "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF",
                 displayName: "Llama 3.1 8B Instruct",
                 sizeGB: "5.0",
                 description: "Meta's flagship small model."),
    CuratedModel(id: "bartowski/Qwen2.5-32B-Instruct-GGUF",
                 displayName: "Qwen2.5 32B Instruct",
                 sizeGB: "19",
                 description: "Best quality. Needs 24 GB+ RAM."),
    CuratedModel(id: "bartowski/Mistral-Nemo-Instruct-2407-GGUF",
                 displayName: "Mistral Nemo 12B",
                 sizeGB: "7.0",
                 description: "Multilingual, strong reasoning."),
    CuratedModel(id: "bartowski/Phi-3.5-mini-instruct-GGUF",
                 displayName: "Phi 3.5 Mini",
                 sizeGB: "2.3",
                 description: "Microsoft's tiny powerhouse."),
    CuratedModel(id: "bartowski/gemma-2-9b-it-GGUF",
                 displayName: "Gemma 2 9B IT",
                 sizeGB: "5.8",
                 description: "Google's instruction-tuned model."),
    CuratedModel(id: "bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF",
                 displayName: "DeepSeek R1 Distill 7B",
                 sizeGB: "4.7",
                 description: "Reasoning model, chain-of-thought."),
    CuratedModel(id: "bartowski/Llama-3.2-3B-Instruct-GGUF",
                 displayName: "Llama 3.2 3B Instruct",
                 sizeGB: "2.0",
                 description: "Very small, fast, lower quality."),
    CuratedModel(id: "openbmb/MiniCPM5-1B-GGUF",
                 displayName: "MiniCPM5 1B",
                 sizeGB: "0.7",
                 description: "Tiny on-device model, fast and efficient."),
    CuratedModel(id: "bartowski/Qwen2.5-Coder-7B-Instruct-GGUF",
                 displayName: "Qwen2.5 Coder 7B",
                 sizeGB: "4.7",
                 description: "Code-focused model."),
]

// MARK: - Models Window Controller

final class ModelsWindowController: NSObject, NSWindowDelegate {
    static let shared = ModelsWindowController()

    private var window: NSPanel!
    private var headerLabel: NSTextField!
    private var tabView: NSTabView!
    private var descriptionLabel: NSTextField!
    private var progressBar: NSProgressIndicator!
    private var progressLabel: NSTextField!
    private var logTextView: NSTextView!
    private var logScroll: NSScrollView!
    private var cancelButton: NSButton!
    private var closeButton: NSButton!

    private var browseTable: NSTableView!
    private var browseData: [CuratedModel] = curatedModels
    private var searchField: NSSearchField!
    private var searchTable: NSTableView!
    private var searchData: [HFModelSummary] = []
    private var searchStatus: NSTextField!

    private var installedTable: NSTableView!
    private var installedStatus: NSTextField!

    private var urlField: NSTextField!
    private var urlStatus: NSTextField!

    private var activeDownloadTask: Process?
    private var isDownloading = false

    private var browseContainerView: NSView!
    private var searchContainerView: NSView!

    private override init() { super.init() }

    // MARK: Public

    func showWindow() {
        if window == nil { buildWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refreshActive()
        refreshInstalled()
    }

    // MARK: Window construction

    private func buildWindow() {
        let w = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        w.title = "Models"
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.minSize = NSSize(width: 640, height: 380)
        w.delegate = self
        w.center()

        let content = NSView(frame: w.contentView!.bounds)
        content.autoresizingMask = [.width, .height]

        // Header
        headerLabel = NSTextField(labelWithString: "Active: —")
        headerLabel.frame = NSRect(x: 16, y: 360, width: 688, height: 20)
        headerLabel.font = NSFont.boldSystemFont(ofSize: 12)
        headerLabel.autoresizingMask = [.width, .minYMargin]

        // Tab view
        let tabHeight: CGFloat = 330
        tabView = NSTabView(frame: NSRect(x: 16, y: 20, width: 688, height: tabHeight))
        tabView.autoresizingMask = [.width, .height]

        addTab("Active", view: buildActiveTab())
        addTab("Browse", view: buildBrowseTab())
        addTab("Installed", view: buildInstalledTab())
        addTab("Install from URL", view: buildURLTab())
        tabView.selectTabViewItem(at: 0)

        // Description / status panel (below tabs)
        descriptionLabel = NSTextField(wrappingLabelWithString: "")
        descriptionLabel.frame = NSRect(x: 16, y: 110, width: 688, height: 50)
        descriptionLabel.font = NSFont.systemFont(ofSize: 11)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.isHidden = true
        descriptionLabel.autoresizingMask = [.width, .minYMargin]

        // Footer
        progressBar = NSProgressIndicator(frame: NSRect(x: 16, y: 86, width: 568, height: 14))
        progressBar.autoresizingMask = [.width, .minYMargin]
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.isHidden = true

        progressLabel = NSTextField(labelWithString: "")
        progressLabel.frame = NSRect(x: 16, y: 64, width: 688, height: 18)
        progressLabel.font = NSFont.systemFont(ofSize: 11)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.autoresizingMask = [.width, .minYMargin]
        progressLabel.isHidden = true

        let logScroll = NSScrollView(frame: NSRect(x: 16, y: 16, width: 568, height: 42))
        logScroll.autoresizingMask = [.width, .minYMargin]
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.isHidden = true
        let tv = NSTextView(frame: logScroll.bounds)
        tv.autoresizingMask = [.width, .height]
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        logScroll.documentView = tv
        self.logScroll = logScroll
        logTextView = tv

        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelDownload))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: 592, y: 24, width: 80, height: 24)
        cancelButton.autoresizingMask = [.minXMargin, .minYMargin]
        cancelButton.isHidden = true

        closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        closeButton.frame = NSRect(x: 624, y: 24, width: 80, height: 24)
        closeButton.isHidden = true

        content.addSubview(headerLabel)
        content.addSubview(tabView)
        content.addSubview(descriptionLabel)
        content.addSubview(progressBar)
        content.addSubview(progressLabel)
        content.addSubview(logScroll)
        content.addSubview(cancelButton)
        content.addSubview(closeButton)

        w.contentView = content
        window = w
    }

    private func addTab(_ label: String, view: NSView) {
        let item = NSTabViewItem()
        item.label = label
        item.view = view
        tabView.addTabViewItem(item)
    }

    private func buildActiveTab() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 688, height: 320))
        let lbl = NSTextField(labelWithString: "Current active model is shown in the header above.\n\nTo change it:\n  • Click Browse to pick a new model from Hugging Face\n  • Click Installed to switch to a model you already downloaded\n  • Click Install from URL if you have a specific repo URL")
        lbl.frame = NSRect(x: 16, y: 16, width: 656, height: 248)
        lbl.font = NSFont.systemFont(ofSize: 12)
        lbl.usesSingleLineMode = false
        lbl.maximumNumberOfLines = 0
        lbl.autoresizingMask = [.width, .height]
        v.addSubview(lbl)
        return v
    }

    // MARK: Browse tab

    private func buildBrowseTab() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 688, height: 320))
        // Top toolbar: popup on left, search field on right
        let modePopup = NSPopUpButton(frame: NSRect(x: 16, y: 244, width: 200, height: 24))
        modePopup.addItems(withTitles: ["Shortlist", "Search Hugging Face"])
        modePopup.target = self
        modePopup.action = #selector(browseModeChanged(_:))
        v.addSubview(modePopup)

        searchField = NSSearchField(frame: NSRect(x: 232, y: 244, width: 440, height: 24))
        searchField.placeholderString = "Search GGUF models on Hugging Face"
        searchField.target = self
        searchField.action = #selector(performSearch)
        searchField.isHidden = true
        v.addSubview(searchField)

        // Search status (only shown in search mode)
        searchStatus = NSTextField(labelWithString: "Type a query and press Return.")
        searchStatus.frame = NSRect(x: 16, y: 222, width: 656, height: 18)
        searchStatus.font = NSFont.systemFont(ofSize: 11)
        searchStatus.textColor = .secondaryLabelColor
        searchStatus.isHidden = true
        v.addSubview(searchStatus)

        // Table area (below toolbar)
        let browseScroll = NSScrollView(frame: NSRect(x: 16, y: 16, width: 656, height: 200))
        browseTable = NSTableView(frame: browseScroll.bounds)
        browseTable.autoresizingMask = [.width, .height]
        browseTable.allowsMultipleSelection = false
        browseTable.allowsEmptySelection = true
        browseTable.rowSizeStyle = .small
        let col1 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col1.title = "Model"
        col1.width = 280
        browseTable.addTableColumn(col1)
        let col2 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        col2.title = "Size"
        col2.width = 60
        browseTable.addTableColumn(col2)
        let col3 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("desc"))
        col3.title = "Description"
        col3.width = 290
        browseTable.addTableColumn(col3)
        browseTable.dataSource = self
        browseTable.delegate = self
        browseTable.tag = 100
        browseTable.target = self
        browseTable.doubleAction = #selector(browseRowDoubleClicked)
        browseScroll.documentView = browseTable
        browseScroll.hasVerticalScroller = true
        browseScroll.autoresizingMask = [.width, .height]
        browseContainerView = browseScroll
        v.addSubview(browseScroll)

        let searchScroll = NSScrollView(frame: NSRect(x: 16, y: 16, width: 656, height: 200))
        searchTable = NSTableView(frame: searchScroll.bounds)
        searchTable.autoresizingMask = [.width, .height]
        searchTable.allowsMultipleSelection = false
        searchTable.allowsEmptySelection = true
        searchTable.rowSizeStyle = .small
        let sc1 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("id"))
        sc1.title = "Repository"
        sc1.width = 320
        searchTable.addTableColumn(sc1)
        let sc2 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("dl"))
        sc2.title = "Downloads"
        sc2.width = 90
        searchTable.addTableColumn(sc2)
        let sc3 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mod"))
        sc3.title = "Last modified"
        sc3.width = 220
        searchTable.addTableColumn(sc3)
        searchTable.dataSource = self
        searchTable.delegate = self
        searchTable.tag = 101
        searchTable.target = self
        searchTable.doubleAction = #selector(searchRowDoubleClicked)
        searchScroll.documentView = searchTable
        searchScroll.hasVerticalScroller = true
        searchScroll.autoresizingMask = [.width, .height]
        searchScroll.isHidden = true
        searchContainerView = searchScroll
        v.addSubview(searchScroll)

        return v
    }

    @objc private func browseModeChanged(_ popup: NSPopUpButton) {
        let isSearch = popup.indexOfSelectedItem == 1
        searchField.isHidden = !isSearch
        searchStatus.isHidden = !isSearch
        searchContainerView.isHidden = !isSearch
        browseContainerView.isHidden = isSearch
    }

    @objc private func performSearch() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchStatus.stringValue = "Searching…"
        searchData = []
        searchTable.reloadData()
        HuggingFaceAPI.shared.searchModels(query: q) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let models):
                self.searchData = models
                self.searchTable.reloadData()
                self.searchStatus.stringValue = models.isEmpty ? "No GGUF models found for '\(q)'." : "\(models.count) results."
            case .failure(let err):
                self.searchStatus.stringValue = err.errorDescription ?? "Search failed."
            }
        }
    }

    @objc private func browseRowDoubleClicked() {
        let row = browseTable.clickedRow
        guard row >= 0 && row < browseData.count else { return }
        let m = browseData[row]
        showFilePicker(forRepo: m.id, suggestedLabel: m.displayName)
    }

    @objc private func searchRowDoubleClicked() {
        let row = searchTable.clickedRow
        guard row >= 0 && row < searchData.count else { return }
        let m = searchData[row]
        showFilePicker(forRepo: m.id, suggestedLabel: m.id)
    }

    // MARK: Installed tab

    private func buildInstalledTab() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 688, height: 320))

        installedStatus = NSTextField(labelWithString: "")
        installedStatus.frame = NSRect(x: 16, y: 248, width: 656, height: 18)
        installedStatus.font = NSFont.systemFont(ofSize: 11)
        installedStatus.textColor = .secondaryLabelColor
        v.addSubview(installedStatus)

        installedTable = NSTableView(frame: NSRect(x: 16, y: 16, width: 656, height: 220))
        installedTable.autoresizingMask = [.width, .height]
        installedTable.allowsMultipleSelection = false
        installedTable.allowsEmptySelection = true
        installedTable.rowSizeStyle = .small
        let c1 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("active"))
        c1.title = ""
        c1.width = 24
        installedTable.addTableColumn(c1)
        let c2 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        c2.title = "Filename"
        c2.width = 460
        installedTable.addTableColumn(c2)
        let c3 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        c3.title = "Size"
        c3.width = 90
        installedTable.addTableColumn(c3)
        installedTable.dataSource = self
        installedTable.delegate = self
        installedTable.tag = 102
        installedTable.target = self
        installedTable.doubleAction = #selector(installedRowDoubleClicked)

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 16, width: 656, height: 220))
        scroll.documentView = installedTable
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        v.addSubview(scroll)

        let makeActive = NSButton(title: "Make Active", target: self, action: #selector(makeActiveClicked))
        makeActive.bezelStyle = .rounded
        makeActive.frame = NSRect(x: 480, y: 246, width: 90, height: 22)
        makeActive.autoresizingMask = [.minXMargin, .minYMargin]
        let deleteBtn = NSButton(title: "Delete…", target: self, action: #selector(deleteClicked))
        deleteBtn.bezelStyle = .rounded
        deleteBtn.frame = NSRect(x: 580, y: 246, width: 90, height: 22)
        deleteBtn.autoresizingMask = [.minXMargin, .minYMargin]
        v.addSubview(makeActive)
        v.addSubview(deleteBtn)
        return v
    }

    @objc private func installedRowDoubleClicked() {
        let row = installedTable.clickedRow
        guard row >= 0 else { return }
        let models = ModelManager.shared.listInstalled()
        guard row < models.count else { return }
        if !models[row].isActive {
            activateModel(models[row])
        }
    }

    @objc private func makeActiveClicked() {
        let row = installedTable.selectedRow
        guard row >= 0 else { return }
        let models = ModelManager.shared.listInstalled()
        guard row < models.count else { return }
        if models[row].isActive {
            NSSound.beep()
            return
        }
        activateModel(models[row])
    }

    @objc private func deleteClicked() {
        let row = installedTable.selectedRow
        guard row >= 0 else { return }
        let models = ModelManager.shared.listInstalled()
        guard row < models.count else { return }
        let m = models[row]
        let alert = NSAlert()
        alert.messageText = "Delete model?"
        alert.informativeText = "\(m.filename) (\(Self.formatSize(m.size))) will be removed from disk. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try ModelManager.shared.deleteModel(at: m.path)
                refreshInstalled()
            } catch {
                let a = NSAlert()
                a.messageText = "Could not delete"
                a.informativeText = error.localizedDescription
                a.runModal()
            }
        }
    }

    // MARK: URL tab

    private func buildURLTab() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 688, height: 320))
        let help = NSTextField(labelWithString: "Paste a Hugging Face URL or repo id. Examples:")
        help.frame = NSRect(x: 16, y: 248, width: 656, height: 18)
        help.font = NSFont.systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        v.addSubview(help)

        urlField = NSTextField(frame: NSRect(x: 16, y: 218, width: 568, height: 22))
        urlField.placeholderString = "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF"
        v.addSubview(urlField)

        let fetchBtn = NSButton(title: "Fetch", target: self, action: #selector(fetchFromURL))
        fetchBtn.bezelStyle = .rounded
        fetchBtn.frame = NSRect(x: 592, y: 217, width: 80, height: 24)
        v.addSubview(fetchBtn)

        urlStatus = NSTextField(labelWithString: "")
        urlStatus.frame = NSRect(x: 16, y: 16, width: 656, height: 180)
        urlStatus.font = NSFont.systemFont(ofSize: 11)
        urlStatus.textColor = .secondaryLabelColor
        urlStatus.isEditable = false
        urlStatus.usesSingleLineMode = false
        urlStatus.maximumNumberOfLines = 0
        v.addSubview(urlStatus)
        return v
    }

    @objc private func fetchFromURL() {
        let raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let (repo, file) = Self.parseHFInput(raw)
        guard let repo = repo else {
            urlStatus.stringValue = "Could not parse a repo from: \(raw)"
            return
        }
        if let file = file {
            // Direct: skip picker
            startDownload(repo: repo, file: file, label: file)
        } else {
            showFilePicker(forRepo: repo, suggestedLabel: repo, suggestedFile: nil, sourceStatus: urlStatus)
        }
    }

    static func parseHFInput(_ raw: String) -> (repo: String?, file: String?) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // https://huggingface.co/<repo>/resolve/main/<file>
        if let range = s.range(of: "huggingface.co/") {
            let after = s[range.upperBound...]
            let parts = after.split(separator: "/").map(String.init)
            if parts.count >= 2 {
                let repo = "\(parts[0])/\(parts[1])"
                if parts.count >= 5 && parts[2] == "resolve", parts[4].hasSuffix(".gguf") {
                    return (repo, parts[4])
                }
                return (repo, nil)
            }
        }
        // bare "owner/name"
        let parts = s.split(separator: "/").map(String.init)
        if parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty {
            return ("\(parts[0])/\(parts[1])", nil)
        }
        return (nil, nil)
    }

    // MARK: Refresh

    func refreshActive() {
        if !isInstalled() {
            headerLabel.stringValue = "Active: (llama.cpp not installed yet)"
            return
        }
        let s = ServerManager.shared
        // Strip trailing "(~X.X GB)" from label so we don't double-print size
        var label = s.modelLabel
        if let r = label.range(of: #"\s*\(~[\d.]+ GB\)$"#, options: .regularExpression) {
            label.removeSubrange(r)
        }
        let sizeStr: String
        let path = s.modelPath
        if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            sizeStr = " — \(Self.formatSize(size))"
        } else {
            sizeStr = ""
        }
        let status = s.isRunning ? "running" : "stopped"
        headerLabel.stringValue = "Active: \(label.isEmpty ? "—" : label)\(sizeStr) — \(status)"
    }

    func refreshInstalled() {
        let models = ModelManager.shared.listInstalled()
        installedTable.reloadData()
        if models.isEmpty {
            installedStatus.stringValue = "(none — use Browse or Install from URL)"
        } else {
            let active = models.filter { $0.isActive }.count
            installedStatus.stringValue = "\(models.count) installed, \(active) active"
        }
    }

    // MARK: Activate

    private func activateModel(_ m: InstalledModel) {
        do {
            try ModelManager.shared.activateModel(at: m.path, label: m.filename, repo: m.filename)
            refreshActive()
            refreshInstalled()
            tabView.selectTabViewItem(at: 0)
            let a = NSAlert()
            a.messageText = "Model activated"
            a.informativeText = "\(m.filename) is now active. Server has been restarted."
            a.addButton(withTitle: "OK")
            a.runModal()
        } catch {
            let a = NSAlert()
            a.messageText = "Could not activate"
            a.informativeText = error.localizedDescription
            a.addButton(withTitle: "OK")
            a.runModal()
        }
    }

    // MARK: File picker

    private func showFilePicker(forRepo repo: String, suggestedLabel: String, suggestedFile: String? = nil, sourceStatus: NSTextField? = nil) {
        if let sourceStatus = sourceStatus {
            sourceStatus.stringValue = "Loading files for \(repo)…"
        } else {
            searchStatus.stringValue = "Loading files for \(repo)…"
        }
        HuggingFaceAPI.shared.listRepoFiles(repo: repo) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let files):
                guard !files.isEmpty else {
                    let msg = "No GGUF quantizations found in this repo."
                    if let sourceStatus = sourceStatus { sourceStatus.stringValue = msg }
                    else { self.searchStatus.stringValue = msg }
                    return
                }
                self.presentFilePicker(repo: repo, files: files, suggestedLabel: suggestedLabel)
            case .failure(let err):
                let msg = err.errorDescription ?? "Could not load repo."
                if let sourceStatus = sourceStatus { sourceStatus.stringValue = msg }
                else { self.searchStatus.stringValue = msg }
            }
        }
    }

    private func presentFilePicker(repo: String, files: [HFRepoFile], suggestedLabel: String) {
        let picker = FilePickerController(repo: repo, files: files) { [weak self] file, label in
            self?.startDownload(repo: repo, file: file, label: label)
        }
        picker.runModal()
    }

    // MARK: Download

    private func startDownload(repo: String, file: String, label: String) {
        if isDownloading {
            NSSound.beep()
            return
        }
        tabView.selectTabViewItem(at: 0)
        logTextView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        progressBar.doubleValue = 0
        progressBar.isHidden = false
        progressLabel.isHidden = false
        logScroll.isHidden = false
        descriptionLabel.isHidden = true
        cancelButton.isHidden = false
        closeButton.isHidden = true
        progressLabel.stringValue = "Downloading \(file)…"
        isDownloading = true

        let model = ModelManager.shared
        let task = model.downloadModel(
            repo: repo,
            file: file,
            logCallback: { [weak self] s in
                guard let self = self else { return }
                let attr = NSAttributedString(string: s, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: NSColor.textColor,
                ])
                self.logTextView.textStorage?.append(attr)
                self.logTextView.scrollToEndOfDocument(nil)
            },
            progressCallback: { [weak self] p in
                guard let self = self else { return }
                self.progressBar.doubleValue = p
                self.progressLabel.stringValue = String(format: "Downloading %@ — %.0f%%", file, p * 100)
            }
        )
        activeDownloadTask = task
        DispatchQueue.global(qos: .userInitiated).async {
            task.waitUntilExit()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let code = task.terminationStatus
                self.isDownloading = false
                self.activeDownloadTask = nil
                self.progressBar.isHidden = true
                self.cancelButton.isHidden = true
                self.closeButton.isHidden = false
                self.logScroll.isHidden = true
                if code == 0 {
                    self.progressLabel.stringValue = "Download finished."
                    self.afterDownload(repo: repo, file: file, label: label)
                } else {
                    self.progressLabel.stringValue = "Download failed (exit \(code))."
                }
            }
        }
    }

    @objc private func cancelDownload() {
        activeDownloadTask?.terminate()
    }

    private func afterDownload(repo: String, file: String, label: String) {
        let path = ModelManager.shared.modelsDir + "/" + file
        refreshInstalled()
        let alert = NSAlert()
        alert.messageText = "Download complete"
        alert.informativeText = "\(file) was downloaded successfully.\n\nUse this model now?"
        alert.addButton(withTitle: "Use This Model")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try ModelManager.shared.activateModel(at: path, label: label, repo: repo)
                refreshActive()
                refreshInstalled()
            } catch {
                let a = NSAlert()
                a.messageText = "Could not activate"
                a.informativeText = error.localizedDescription
                a.addButton(withTitle: "OK")
                a.runModal()
            }
        }
    }

    @objc private func closeWindow() {
        window.close()
    }

    // MARK: Helpers

    static func formatSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000.0
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_000_000.0
        return String(format: "%.0f MB", mb)
    }
}

// MARK: - NSTableView DataSource / Delegate

extension ModelsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        let row = table.selectedRow
        if row < 0 {
            descriptionLabel.stringValue = ""
            descriptionLabel.isHidden = true
            return
        }
        switch table.tag {
        case 100:
            let m = browseData[row]
            descriptionLabel.stringValue = "Repo: \(m.id)  •  ~\(m.sizeGB) GB  •  \(m.description)"
            descriptionLabel.isHidden = false
        case 101:
            let m = searchData[row]
            descriptionLabel.stringValue = "Repo: \(m.id)  •  Downloads: \(m.downloads)"
            descriptionLabel.isHidden = false
        case 102:
            let m = ModelManager.shared.listInstalled()[row]
            descriptionLabel.stringValue = (m.isActive ? "Active  •  " : "") + "\(m.filename)  •  \(ModelsWindowController.formatSize(m.size))"
            descriptionLabel.isHidden = false
        default:
            descriptionLabel.isHidden = true
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView.tag {
        case 100: return browseData.count
        case 101: return searchData.count
        case 102: return ModelManager.shared.listInstalled().count
        default: return 0
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("")
        let cellID = NSUserInterfaceItemIdentifier("cell")
        let text: String
        switch tableView.tag {
        case 100:
            let m = browseData[row]
            switch id.rawValue {
            case "name": text = m.displayName
            case "size": text = "~\(m.sizeGB) GB"
            case "desc": text = m.description
            default: text = ""
            }
        case 101:
            let m = searchData[row]
            switch id.rawValue {
            case "id": text = m.id
            case "dl": text = "\(m.downloads)"
            case "mod": text = String(m.lastModified.prefix(10))
            default: text = ""
            }
        case 102:
            let m = ModelManager.shared.listInstalled()[row]
            switch id.rawValue {
            case "active": text = m.isActive ? "✓" : ""
            case "file": text = m.filename
            case "size": text = ModelsWindowController.formatSize(m.size)
            default: text = ""
            }
        default:
            text = ""
        }
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: text)
        tf.frame = NSRect(x: 4, y: 2, width: 280, height: 16)
        tf.font = NSFont.systemFont(ofSize: 11)
        if tableView.tag == 102 && id.rawValue == "active" {
            tf.font = NSFont.boldSystemFont(ofSize: 12)
            tf.textColor = .systemGreen
            tf.alignment = .center
        }
        cell.addSubview(tf)
        cell.identifier = cellID
        return cell
    }
}

// MARK: - File Picker

final class FilePickerController: NSObject {
    private let repo: String
    private let files: [HFRepoFile]
    private let onPick: (String, String) -> Void
    private var panel: NSPanel!
    private var table: NSTableView!

    init(repo: String, files: [HFRepoFile], onPick: @escaping (String, String) -> Void) {
        self.repo = repo
        self.files = files
        self.onPick = onPick
    }

    func runModal() {
        let w = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        w.title = "Pick a file — \(repo)"
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        let content = NSView(frame: w.contentView!.bounds)
        content.autoresizingMask = [.width, .height]

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 56, width: 576, height: 280))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        scroll.borderType = .bezelBorder
        let t = NSTableView(frame: scroll.bounds)
        t.allowsMultipleSelection = false
        t.allowsEmptySelection = true
        t.rowSizeStyle = .small
        let c1 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        c1.title = "File"
        c1.width = 360
        t.addTableColumn(c1)
        let c2 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        c2.title = "Size"
        c2.width = 80
        t.addTableColumn(c2)
        let c3 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("quant"))
        c3.title = "Quant"
        c3.width = 70
        t.addTableColumn(c3)
        t.dataSource = self
        t.delegate = self
        t.target = self
        t.doubleAction = #selector(rowDoubleClicked)
        scroll.documentView = t
        table = t

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 412, y: 16, width: 80, height: 24)
        let download = NSButton(title: "Download", target: self, action: #selector(downloadClicked))
        download.bezelStyle = .rounded
        download.frame = NSRect(x: 500, y: 16, width: 88, height: 24)

        content.addSubview(scroll)
        content.addSubview(cancel)
        content.addSubview(download)
        w.contentView = content
        panel = w
        NSApp.runModal(for: w)
    }

    @objc private func cancelClicked() {
        NSApp.stopModal(withCode: .cancel)
        panel.close()
    }

    @objc private func downloadClicked() {
        let row = table.selectedRow
        guard row >= 0 else {
            NSSound.beep()
            return
        }
        let f = files[row]
        onPick(f.path, f.path)
        NSApp.stopModal(withCode: .OK)
        panel.close()
    }

    @objc private func rowDoubleClicked() {
        downloadClicked()
    }
}

extension FilePickerController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("")
        let f = files[row]
        let text: String
        switch id.rawValue {
        case "file": text = f.path
        case "size": text = ModelsWindowController.formatSize(f.size)
        case "quant": text = f.quant
        default: text = ""
        }
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: text)
        tf.frame = NSRect(x: 4, y: 2, width: 360, height: 16)
        tf.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        cell.addSubview(tf)
        return cell
    }
}

// MARK: - Helpers

private extension NSObject {
    func also(_ block: (Self) -> Void) -> Self {
        block(self)
        return self
    }
}