import AppKit
import Foundation

// MARK: - Installed Model

struct InstalledModel {
    let path: String
    let filename: String
    let size: Int64
    var isActive: Bool { path == ModelManager.shared.activeModelPath() }
}

// MARK: - Model Manager

final class ModelManager {
    static let shared = ModelManager()

    let modelsDir = NSHomeDirectory() + "/models"

    private static func pythonVersion() -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let ver = String(data: data, encoding: .utf8) ?? ""
        let parts = ver.split(separator: ".")
        if parts.count >= 2 { return "\(parts[0]).\(parts[1])" }
        return "3.11"
    }

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

    /// Spawns `python3 -m huggingface_hub download <repo> <filename> --local-dir <modelsDir>`
    /// Streams stdout/stderr to logCallback, parses percentage into progressCallback.
    /// Returns the Process so the caller can cancel.
    @discardableResult
    func downloadModel(
        repo: String,
        file: String,
        logCallback: @escaping (String) -> Void,
        progressCallback: @escaping (Double) -> Void
    ) -> Process {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["-m", "huggingface_hub", "download", repo, file, "--local-dir", modelsDir]
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

        let percentRegex = try? NSRegularExpression(pattern: "(\\d{1,3})%\\|", options: [])

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { logCallback(s) }
            if let regex = percentRegex {
                let range = NSRange(s.startIndex..<s.endIndex, in: s)
                if let m = regex.firstMatch(in: s, options: [], range: range),
                   let r = Range(m.range(at: 1), in: s), let pct = Double(s[r]) {
                    DispatchQueue.main.async { progressCallback(pct / 100.0) }
                }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { logCallback(s) }
        }

        do {
            try task.run()
        } catch {
            DispatchQueue.main.async { logCallback("\nFailed to start download: \(error.localizedDescription)\n") }
        }
        return task
    }
}