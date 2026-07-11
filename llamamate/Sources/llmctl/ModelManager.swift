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

/// Holds a URLSessionDataTask and its delegate so the session does not deallocate the delegate.
final class ModelDownloadSession {
    private let session: URLSession
    let task: URLSessionDataTask

    init(session: URLSession, task: URLSessionDataTask) {
        self.session = session
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
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
        return items.filter { $0.hasSuffix(".gguf") }.map { name in
            let path = modelsDir + "/" + name
            let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            return InstalledModel(path: path, filename: name, size: size)
        }.sorted { $0.filename < $1.filename }.map { m in
            InstalledModel(path: m.path, filename: m.filename, size: m.size)
        }
    }

    // MARK: Delete

    func deleteModel(at path: String) throws {
        try FileManager.default.removeItem(atPath: path)
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

    func saveSettings(ngl: String, fa: String, ctk: String, ctv: String, threads: String, batchSize: String, context: String, port: String, profile: String) throws {
        var config = ConfigManager.shared.read()
        config.ngl = ngl
        config.fa = fa
        config.ctk = ctk
        config.ctv = ctv
        config.threads = threads
        config.batchSize = batchSize
        config.context = context
        config.port = port
        config.profile = profile
        try ConfigManager.shared.apply(config)
    }

    // MARK: Download

    /// Downloads a GGUF file directly from Hugging Face using URLSession.
    /// Tracks progress and streams short status messages to logCallback.
    /// Returns a ModelDownloadSession so the caller can cancel.
    func downloadModel(
        repo: String,
        file: String,
        logCallback: @escaping (String) -> Void,
        progressCallback: @escaping (Double) -> Void,
        completion: @escaping (Bool) -> Void
    ) -> ModelDownloadSession {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: modelsDir, withIntermediateDirectories: true, attributes: nil)

        let destination = modelsDir + "/" + file
        let tempDestination = destination + ".download"
        let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file)")!

        var request = URLRequest(url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        if let token = UserDefaults.standard.string(forKey: "hf_token"), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let delegate = DownloadDelegate(
            destination: tempDestination,
            finalDestination: destination,
            logCallback: logCallback,
            progressCallback: progressCallback,
            completion: completion
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: .main)
        let task = session.dataTask(with: request)
        delegate.task = task

        logCallback("Downloading \(file) from \(repo)\n")
        task.resume()

        return ModelDownloadSession(session: session, task: task)
    }
}

// MARK: - Download Delegate

private final class DownloadDelegate: NSObject, URLSessionDataDelegate {
    private let destination: String
    private let finalDestination: String
    private let logCallback: (String) -> Void
    private let progressCallback: (Double) -> Void
    private let completion: (Bool) -> Void
    private var outputHandle: FileHandle?
    private var expectedLength: Int64 = -1
    private var receivedLength: Int64 = 0
    private var lastLoggedPercent: Int = -1
    private var success = false
    weak var task: URLSessionDataTask?

    init(destination: String, finalDestination: String, logCallback: @escaping (String) -> Void, progressCallback: @escaping (Double) -> Void, completion: @escaping (Bool) -> Void) {
        self.destination = destination
        self.finalDestination = finalDestination
        self.logCallback = logCallback
        self.progressCallback = progressCallback
        self.completion = completion
        super.init()

        let fm = FileManager.default
        if fm.fileExists(atPath: destination) {
            try? fm.removeItem(atPath: destination)
        }
        fm.createFile(atPath: destination, contents: nil, attributes: nil)
        outputHandle = FileHandle(forWritingAtPath: destination)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        expectedLength = response.expectedContentLength
        if let http = response as? HTTPURLResponse {
            logCallback("Server returned HTTP \(http.statusCode)\n")
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        outputHandle?.write(data)
        receivedLength += Int64(data.count)
        if expectedLength > 0 {
            let pct = Int(Double(receivedLength) / Double(expectedLength) * 100)
            progressCallback(Double(receivedLength) / Double(expectedLength))
            if pct != lastLoggedPercent && pct % 10 == 0 {
                lastLoggedPercent = pct
                logCallback("\(pct)% downloaded\n")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        outputHandle?.closeFile()

        if let error = error as NSError? {
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                logCallback("\nDownload cancelled.\n")
            } else {
                logCallback("\nDownload error: \(error.localizedDescription)\n")
            }
            completion(false)
            return
        }

        guard let http = task.response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (task.response as? HTTPURLResponse)?.statusCode ?? -1
            logCallback("\nDownload failed with HTTP \(code).\n")
            completion(false)
            return
        }

        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: finalDestination) {
                try fm.removeItem(atPath: finalDestination)
            }
            try fm.moveItem(atPath: destination, toPath: finalDestination)
            success = true
            logCallback("\nSaved to \(finalDestination)\n")
            completion(true)
        } catch {
            logCallback("\nCould not finalize download: \(error.localizedDescription)\n")
            completion(false)
        }
    }
}
