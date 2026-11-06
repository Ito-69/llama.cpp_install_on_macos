import AppKit
import Foundation

final class LogViewerController: NSObject, NSWindowDelegate {
    static let shared = LogViewerController()

    private var window: NSPanel!
    private var textView: NSTextView!
    private var refreshTimer: Timer?

    private let logPath = NSHomeDirectory() + "/Library/Logs/llama-server.log"
    private let errPath = NSHomeDirectory() + "/Library/Logs/llama-server.err.log"

    private override init() { super.init() }

    // Remember what we last rendered so the timer only redraws on change.
    private var lastSignature = ""

    func showWindow() {
        if window == nil { buildWindow() }
        refreshTimer?.invalidate()   // never stack timers across reopens
        lastSignature = ""
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let w = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        w.title = "Server Logs"
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.delegate = self
        w.center()

        let content = NSView(frame: w.contentView!.bounds)
        content.autoresizingMask = [.width, .height]

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 44, width: 696, height: 380))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]

        let tv = NSTextView(frame: scroll.bounds)
        tv.autoresizingMask = [.width, .height]
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        scroll.documentView = tv
        textView = tv

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        refreshButton.bezelStyle = .rounded
        refreshButton.frame = NSRect(x: 12, y: 12, width: 80, height: 24)

        let openFolder = NSButton(title: "Open in Finder", target: self, action: #selector(openFolderClicked))
        openFolder.bezelStyle = .rounded
        openFolder.frame = NSRect(x: 100, y: 12, width: 140, height: 24)

        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        close.bezelStyle = .rounded
        close.frame = NSRect(x: 720 - 16 - 80, y: 12, width: 80, height: 24)
        close.autoresizingMask = [.minXMargin]

        content.addSubview(scroll)
        content.addSubview(refreshButton)
        content.addSubview(openFolder)
        content.addSubview(close)

        w.contentView = content
        window = w
    }

    /// Reads only the last `maxBytes` of a possibly-huge log via a seek, and
    /// starts decoding at the first newline after the offset so a multi-byte
    /// UTF-8 character is never cut in half.
    private func readTailed(_ path: String, maxBytes: Int = 256_000) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let end = handle.seekToEndOfFile()
        var start: UInt64 = 0
        var trimmed = false
        if end > UInt64(maxBytes) {
            start = end - UInt64(maxBytes)
            trimmed = true
        }
        handle.seek(toFileOffset: start)
        guard var data = try? handle.readToEnd() else { return "" }
        if trimmed, let nl = data.firstIndex(of: 0x0A) {
            data = data.suffix(from: data.index(after: nl))
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Cheap change signature: size + mtime of both logs.
    private func fileSignature(_ path: String) -> String {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return "-" }
        let size = (a[.size] as? Int) ?? 0
        let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size):\(mtime)"
    }

    private func refresh() {
        let sig = fileSignature(logPath) + "|" + fileSignature(errPath)
        if sig == lastSignature { return } // nothing changed since last draw
        lastSignature = sig

        let main = readTailed(logPath)
        let err = readTailed(errPath)
        var combined = ""
        if !main.isEmpty { combined += "─── stdout ───\n" + main }
        if !err.isEmpty  { combined += "\n\n─── stderr ───\n" + err }
        if combined.isEmpty { combined = "(no logs yet — server hasn't been started, or has not produced output)" }
        textView.string = combined
        textView.scrollToEndOfDocument(nil)
    }

    @objc private func refreshClicked() { lastSignature = ""; refresh() }

    @objc private func openFolderClicked() {
        let dir = NSHomeDirectory() + "/Library/Logs"
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    @objc private func closeClicked() { window.close() }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
