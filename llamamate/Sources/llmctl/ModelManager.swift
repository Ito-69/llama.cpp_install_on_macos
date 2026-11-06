import AppKit
import Foundation

// MARK: - Installed Model

struct InstalledModel {
    let path: String
    let filename: String
    let size: Int64
    var isActive: Bool { path == ModelManager.shared.activeModelPath() }
}

// MARK: - Download Session

/// Handle the caller holds to cancel an in-flight download (single or split).
final class ModelDownloadSession {
    private let coordinator: DownloadCoordinator
    init(coordinator: DownloadCoordinator) { self.coordinator = coordinator }
    func cancel() { coordinator.cancel() }
}

/// One part of a (possibly split) GGUF download.
struct DownloadPart {
    let file: String       // repo-relative path, may contain a subfolder
    let expectedSize: Int64 // bytes from the HF tree API; 0 = unknown
}

// MARK: - Model Manager

final class ModelManager {
    static let shared = ModelManager()

    let modelsDir = NSHomeDirectory() + "/models"

    func activeModelPath() -> String {
        ConfigManager.shared.read().modelPath
    }

    // MARK: Installed list

    func listInstalled() -> [InstalledModel] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: modelsDir) else { return [] }
        let ggufs = items.filter { $0.hasSuffix(".gguf") }
        func fileSize(_ name: String) -> Int64 {
            (try? fm.attributesOfItem(atPath: modelsDir + "/" + name)[.size] as? Int64) ?? 0
        }

        // Group split files (…-00001-of-00003.gguf) under one entry; the rest
        // are standalone models.
        var splitGroups: [String: [String]] = [:]
        var result: [InstalledModel] = []
        for name in ggufs {
            if let base = Self.splitBase(of: name) {
                splitGroups[base, default: []].append(name)
            } else {
                result.append(InstalledModel(path: modelsDir + "/" + name, filename: name, size: fileSize(name)))
            }
        }
        for (_, parts) in splitGroups {
            let sorted = parts.sorted()
            guard let first = sorted.first else { continue }
            let total = sorted.reduce(Int64(0)) { $0 + fileSize($1) }
            result.append(InstalledModel(path: modelsDir + "/" + first, filename: first, size: total))
        }
        return result.sorted { $0.filename < $1.filename }
    }

    /// A grouping key shared by all parts of a split GGUF set, or nil for a
    /// standalone file. Keyed on the prefix plus the part total so unrelated
    /// sets never merge.
    static func splitBase(of filename: String) -> String? {
        guard let r = filename.range(of: #"-\d{5}-of-\d{5}\.gguf$"#, options: .regularExpression) else { return nil }
        let prefix = String(filename[filename.startIndex..<r.lowerBound])
        let matched = String(filename[r])  // e.g. -00001-of-00003.gguf
        let total = matched.replacingOccurrences(of: #"^-\d{5}-of-"#, with: "", options: .regularExpression)
        return prefix + "|" + total
    }

    /// All part paths that belong with the given first-part path (or just the
    /// path itself if it is not a split file).
    func splitParts(forFirst firstPath: String) -> [String] {
        let name = (firstPath as NSString).lastPathComponent
        guard let base = Self.splitBase(of: name) else { return [firstPath] }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: modelsDir) else { return [firstPath] }
        return items.filter { $0.hasSuffix(".gguf") && Self.splitBase(of: $0) == base }
            .sorted()
            .map { modelsDir + "/" + $0 }
    }

    // MARK: Delete

    func deleteModel(at path: String) throws {
        // Deleting a split model removes every part.
        for part in splitParts(forFirst: path) {
            try? FileManager.default.removeItem(atPath: part)
        }
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: Activate

    func activateModel(at path: String, label: String? = nil, repo: String? = nil) throws {
        let filename = (path as NSString).lastPathComponent
        let resolvedLabel = label ?? filename
        let resolvedRepo = repo ?? filename
        var config = ConfigManager.shared.read()
        config.modelPath = path
        config.modelFile = filename
        config.modelLabel = resolvedLabel
        config.modelRepo = resolvedRepo
        try ConfigManager.shared.apply(config)
    }

    // MARK: Save Settings

    func saveSettings(ngl: String, fa: String, ctk: String, ctv: String, threads: String, batchSize: String, context: String, port: String, host: String, apiKey: String, cacheReuse: String, mlock: String, threadsBatch: String, reasoningEffort: String, reasoningBudget: String, profile: String) throws {
        var config = ConfigManager.shared.read()
        config.ngl = ngl
        config.fa = fa
        config.ctk = ctk
        config.ctv = ctv
        config.threads = threads
        config.batchSize = batchSize
        // ubatchSize is intentionally left as read from the config (no UI yet).
        config.context = context
        config.port = port
        config.host = host
        config.apiKey = apiKey
        config.cacheReuse = cacheReuse
        config.mlock = mlock
        config.threadsBatch = threadsBatch
        config.reasoningEffort = reasoningEffort
        config.reasoningBudget = reasoningBudget
        config.profile = profile
        try ConfigManager.shared.apply(config)
    }

    // MARK: Download

    /// Free-space override for tests (bytes). When set, used instead of the
    /// real volume capacity so a shortage can be simulated.
    static var debugFreeBytesOverride: Int64? = {
        if let s = ProcessInfo.processInfo.environment["LLAMAMATE_DEBUG_FREE_BYTES"], let v = Int64(s) { return v }
        return nil
    }()

    /// Download a single GGUF file (convenience over `downloadModelParts`).
    func downloadModel(
        repo: String,
        file: String,
        expectedSize: Int64 = 0,
        logCallback: @escaping (String) -> Void,
        progressCallback: @escaping (Double) -> Void,
        completion: @escaping (Bool) -> Void
    ) -> ModelDownloadSession {
        downloadModelParts(repo: repo,
                           parts: [DownloadPart(file: file, expectedSize: expectedSize)],
                           logCallback: logCallback, progressCallback: progressCallback, completion: completion)
    }

    /// Download one or more parts (a split GGUF set) sequentially with resume.
    /// Overall progress is measured in bytes across all parts.
    func downloadModelParts(
        repo: String,
        parts: [DownloadPart],
        logCallback: @escaping (String) -> Void,
        progressCallback: @escaping (Double) -> Void,
        completion: @escaping (Bool) -> Void
    ) -> ModelDownloadSession {
        try? FileManager.default.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)
        let coordinator = DownloadCoordinator(modelsDir: modelsDir, repo: repo, parts: parts,
                                              log: logCallback, progress: progressCallback, completion: completion)
        coordinator.start()
        return ModelDownloadSession(coordinator: coordinator)
    }
}

// MARK: - Download Coordinator

/// Drives a resumable, size-verified download of one or more GGUF parts into
/// ~/models, using a `Range:` request against a freshly-resolved HF URL for
/// each attempt (so expired CDN redirects don't matter).
final class DownloadCoordinator: NSObject, URLSessionDataDelegate {
    private let modelsDir: String
    private let repo: String
    private let parts: [DownloadPart]
    private let log: (String) -> Void
    private let progress: (Double) -> Void
    private let completion: (Bool) -> Void

    private var session: URLSession!
    private var currentTask: URLSessionDataTask?
    private var cancelled = false
    private var finished = false

    private let totalExpected: Int64
    private var completedBytes: Int64 = 0     // bytes from parts already finished/skipped
    private var currentPartBytes: Int64 = 0   // bytes on disk for the in-flight part
    private var index = 0

    private var tempHandle: FileHandle?
    private var currentTempPath = ""
    private var currentFinalPath = ""
    private var currentExpected: Int64 = 0
    private var part416 = false               // 416 => part already complete on disk
    private var partStartOffset: Int64 = 0    // byte offset this attempt resumes from
    private var lastProgressTime: TimeInterval = 0

    init(modelsDir: String, repo: String, parts: [DownloadPart],
         log: @escaping (String) -> Void, progress: @escaping (Double) -> Void, completion: @escaping (Bool) -> Void) {
        self.modelsDir = modelsDir
        self.repo = repo
        self.parts = parts
        self.log = log
        self.progress = progress
        self.completion = completion
        self.totalExpected = parts.reduce(Int64(0)) { $0 + max(0, $1.expectedSize) }
        super.init()
    }

    private func fileSize(_ path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
    }

    func start() {
        let cfg = URLSessionConfiguration.default
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: q)

        if !hasEnoughFreeSpace() { return } // emits error + completion itself
        startPart(0)
    }

    func cancel() {
        cancelled = true
        // Cancel on the delegate queue so it can't race the delegate callbacks.
        if let q = session?.delegateQueue {
            q.addOperation { [weak self] in self?.currentTask?.cancel() }
        } else {
            currentTask?.cancel()
        }
    }

    // MARK: space

    private func hasEnoughFreeSpace() -> Bool {
        // Remaining bytes = expected minus whatever is already on disk.
        var remaining: Int64 = 0
        var unknown = false
        for p in parts {
            let final = modelsDir + "/" + (p.file as NSString).lastPathComponent
            let temp = final + ".download"
            let onDisk = FileManager.default.fileExists(atPath: final) ? fileSize(final)
                       : (FileManager.default.fileExists(atPath: temp) ? fileSize(temp) : 0)
            if p.expectedSize <= 0 { unknown = true; continue }
            remaining += max(0, p.expectedSize - onDisk)
        }
        if unknown || remaining == 0 { return true } // can't compute; let it proceed
        let needed = remaining + remaining / 20 // +5% headroom

        let available: Int64
        if let override = ModelManager.debugFreeBytesOverride {
            available = override
        } else if let vals = try? URL(fileURLWithPath: modelsDir).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
                  let cap = vals.volumeAvailableCapacityForImportantUsage {
            available = cap
        } else {
            return true // couldn't determine; don't block
        }

        if available < needed {
            let needGB = Double(needed) / 1_000_000_000
            let availGB = Double(available) / 1_000_000_000
            emitLog(String(format: "Not enough free space: need ~%.1f GB, only %.1f GB available. Free up space and try again.\n", needGB, availGB))
            finish(false)
            return false
        }
        return true
    }

    // MARK: part sequencing

    private func startPart(_ i: Int) {
        if cancelled { finish(false); return }
        if i >= parts.count {
            emitProgress(1.0, force: true)
            finish(true)
            return
        }
        index = i
        part416 = false
        let part = parts[i]
        currentExpected = part.expectedSize
        let name = (part.file as NSString).lastPathComponent
        currentFinalPath = modelsDir + "/" + name
        currentTempPath = currentFinalPath + ".download"
        let fm = FileManager.default

        // Already fully downloaded? Skip (size matches, or unknown expected).
        if fm.fileExists(atPath: currentFinalPath) {
            let sz = fileSize(currentFinalPath)
            if currentExpected == 0 || sz == currentExpected {
                completedBytes += sz
                emitLog("Already present: \(name)\n")
                startPart(i + 1)
                return
            }
            try? fm.removeItem(atPath: currentFinalPath) // wrong size, redo
        }

        let existing = fm.fileExists(atPath: currentTempPath) ? fileSize(currentTempPath) : 0
        currentPartBytes = existing
        partStartOffset = existing

        // Percent-encode each path segment but keep the slashes.
        let encoded = part.file.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encoded)") else {
            emitLog("Invalid URL for \(name)\n"); finish(false); return
        }
        var req = URLRequest(url: url)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        if let token = KeychainStore.hfToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if existing > 0 {
            req.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
            emitLog("Resuming \(name) from \(existing) bytes\n")
        } else {
            emitLog("Downloading \(name)\n")
        }
        let task = session.dataTask(with: req)
        currentTask = task
        task.resume()
    }

    // MARK: URLSessionDataDelegate

    /// Parses the start offset from a `Content-Range: bytes START-END/TOTAL` header.
    private func contentRangeStart(_ response: URLResponse) -> Int64? {
        guard let http = response as? HTTPURLResponse,
              let cr = http.value(forHTTPHeaderField: "Content-Range"),
              let r = cr.range(of: #"bytes\s+(\d+)-"#, options: .regularExpression) else { return nil }
        let digits = cr[r].filter { $0.isNumber }
        return Int64(digits)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let fm = FileManager.default
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0

        if code == 416 {
            // Range beyond EOF: the .download may already hold the whole file.
            part416 = true
            completionHandler(.cancel)
            return
        }

        if code == 200 {
            // Full body. Only a *resume attempt* being ignored is noteworthy.
            if partStartOffset > 0 { emitLog("Server ignored resume; restarting from scratch\n") }
            try? fm.removeItem(atPath: currentTempPath)
            fm.createFile(atPath: currentTempPath, contents: nil)
            tempHandle = FileHandle(forWritingAtPath: currentTempPath)
            currentPartBytes = 0
            completionHandler(.allow)
            return
        }

        if code == 206 {
            // Partial content — must resume exactly from where we left off.
            let start = contentRangeStart(response)
            guard start == partStartOffset else {
                emitLog("Unexpected Content-Range (start \(start.map(String.init) ?? "?"), expected \(partStartOffset)); discarding partial file.\n")
                try? fm.removeItem(atPath: currentTempPath)
                completionHandler(.cancel)
                finish(false)
                return
            }
            if !fm.fileExists(atPath: currentTempPath) { fm.createFile(atPath: currentTempPath, contents: nil) }
            tempHandle = FileHandle(forWritingAtPath: currentTempPath)
            tempHandle?.seekToEndOfFile()
            currentPartBytes = partStartOffset
            completionHandler(.allow)
            return
        }

        // Any other status (401/403/404/5xx…): don't touch the file, keep the
        // partial download for a later retry.
        emitLog("\nDownload failed with HTTP \(code).\n")
        completionHandler(.cancel)
        finish(false)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try tempHandle?.write(contentsOf: data)
        } catch {
            emitLog("\nWrite failed (\(error.localizedDescription)); stopping. Partial file kept.\n")
            finish(false)          // sets finished before the cancel's didComplete
            currentTask?.cancel()
            return
        }
        currentPartBytes += Int64(data.count)
        if totalExpected > 0 {
            emitProgress(Double(completedBytes + currentPartBytes) / Double(totalExpected), force: false)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        tempHandle?.closeFile()
        tempHandle = nil

        // 416 success path (part may already be complete on disk).
        if part416 {
            finalize416()
            return
        }

        // A disposition of .cancel on an error/HTTP branch already finished us.
        if finished { return }

        if let error = error as NSError? {
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                emitLog(cancelled ? "\nDownload cancelled (progress kept for resume).\n" : "\nStopped.\n")
            } else {
                emitLog("\nDownload error: \(error.localizedDescription)\n")
            }
            finish(false) // keep .download for resume
            return
        }
        guard let http = task.response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (task.response as? HTTPURLResponse)?.statusCode ?? -1
            emitLog("\nDownload failed with HTTP \(code).\n")
            finish(false)
            return
        }
        finalizeCurrentPart()
    }

    /// Normal (2xx) completion: verify size, then move into place.
    private func finalizeCurrentPart() {
        let sz = fileSize(currentTempPath)
        if currentExpected > 0 {
            if sz > currentExpected {
                emitLog("Corrupt partial file (\(sz) > expected \(currentExpected)) — restarting from scratch; press Download again.\n")
                try? FileManager.default.removeItem(atPath: currentTempPath)
                finish(false)
                return
            }
            if sz < currentExpected {
                emitLog("Incomplete: \(sz)/\(currentExpected) bytes. Press Download again to resume.\n")
                finish(false) // keep .download
                return
            }
        }
        moveIntoPlaceAndContinue(sz)
    }

    /// 416 completion: the temp should already be the full file.
    private func finalize416() {
        let sz = fileSize(currentTempPath)
        if currentExpected > 0 && sz != currentExpected {
            emitLog("Corrupt partial file (\(sz), expected \(currentExpected)) — restarting from scratch; press Download again.\n")
            try? FileManager.default.removeItem(atPath: currentTempPath)
            finish(false)
            return
        }
        moveIntoPlaceAndContinue(sz)
    }

    private func moveIntoPlaceAndContinue(_ sz: Int64) {
        let fm = FileManager.default
        let name = (currentFinalPath as NSString).lastPathComponent
        do {
            if fm.fileExists(atPath: currentFinalPath) { try fm.removeItem(atPath: currentFinalPath) }
            try fm.moveItem(atPath: currentTempPath, toPath: currentFinalPath)
        } catch {
            emitLog("Could not finalize \(name): \(error.localizedDescription)\n")
            finish(false)
            return
        }
        completedBytes += sz
        emitLog("Saved \(name)\n")
        startPart(index + 1)
    }

    // MARK: helpers

    private func finish(_ ok: Bool) {
        guard !finished else { return }
        finished = true
        session.finishTasksAndInvalidate()
        DispatchQueue.main.async { self.completion(ok) }
    }

    private func emitLog(_ s: String) { DispatchQueue.main.async { self.log(s) } }

    private func emitProgress(_ value: Double, force: Bool) {
        let now = Date.timeIntervalSinceReferenceDate
        if force || now - lastProgressTime >= 0.1 { // throttle to ~10 Hz
            lastProgressTime = now
            DispatchQueue.main.async { self.progress(min(1.0, value)) }
        }
    }
}
