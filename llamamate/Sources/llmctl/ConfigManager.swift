import AppKit
import CryptoKit
import Foundation

// MARK: - Server Config

struct ServerConfig: Equatable {
    var modelLabel = ""
    var modelRepo = ""
    var modelFile = ""
    var modelPath = ""
    var port = "8080"
    var context = "8192"
    var host = "127.0.0.1"
    var apiKey = ""
    var ngl = "99"
    var fa = "1"
    var ctk = "q8_0"
    var ctv = "q8_0"
    var threads = "0"
    var batchSize = "2048"
    var ubatchSize = "512"
    var cacheReuse = "256"
    var mlock = "0"
    var threadsBatch = ""
    var reasoningEffort = "default"   // default | low | medium | high
    var reasoningBudget = ""          // "" = unlimited, "0" = off, N = token limit
    var profile = "balanced"

    static let defaultKeys: [(key: String, value: KeyPath<ServerConfig, String>)] = [
        ("PORT", \.port),
        ("CONTEXT", \.context),
        ("HOST", \.host),
        ("API_KEY", \.apiKey),
        ("NGL", \.ngl),
        ("FA", \.fa),
        ("CTK", \.ctk),
        ("CTV", \.ctv),
        ("THREADS", \.threads),
        ("BATCH_SIZE", \.batchSize),
        ("UBATCH_SIZE", \.ubatchSize),
        ("PROFILE", \.profile),
        ("MODEL_LABEL", \.modelLabel),
        ("MODEL_REPO", \.modelRepo),
        ("MODEL_FILE", \.modelFile),
        ("MODEL_PATH", \.modelPath),
    ]
}

// MARK: - Config Manager

final class ConfigManager {
    static let shared = ConfigManager()

    private let configPath = "\(NSHomeDirectory())/.config/llama/server.conf"
    private let startScriptPath = "\(NSHomeDirectory())/.local/bin/llama-server-start.sh"
    private let startScriptHashPath = "\(NSHomeDirectory())/.config/llama/.start-script.sha256"
    let localConfigPath = "\(NSHomeDirectory())/.config/llama/server.local.conf"

    /// Keys this app writes to server.conf. Any other KEY=… line (for example a
    /// user's EXTRA_ARGS, or LLAMA_VERSION written by install-llama.sh) is
    /// preserved when the file is rewritten.
    static let managedKeys: Set<String> = [
        "MODEL_LABEL", "MODEL_REPO", "MODEL_FILE", "MODEL_PATH", "PORT", "CONTEXT",
        "HOST", "API_KEY", "NGL", "FA", "CTK", "CTV", "THREADS", "BATCH_SIZE",
        "UBATCH_SIZE", "CACHE_REUSE", "MLOCK", "THREADS_BATCH", "REASONING_EFFORT",
        "REASONING_BUDGET", "PROFILE",
    ]

    /// SHA-256 of start scripts shipped by LlamaMate (v2.4.0 …). An installed
    /// script matching one of these is an unmodified older copy and is replaced
    /// silently. Keep in sync with KNOWN_START_SCRIPT_HASHES in install-llama.sh.
    static let knownShippedStartScriptHashes: Set<String> = [
        "66488562d9ebb401d0517417c77488f239016cea5e6272ee9c66f70467257c72",
        "cdfe5ee9e1ff5335038f811d68b589030b4b55067a0ca4ebbe50a82dae32f706",
    ]

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Lines of the current server.conf whose key LlamaMate does not manage,
    /// returned verbatim (including an optional leading `export `).
    private func unmanagedLines() -> [String] {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return [] }
        var kept: [String] = []
        for line in content.components(separatedBy: .newlines) {
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            if t.hasPrefix("export ") { t = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = t.firstIndex(of: "=") else { continue }
            let key = String(t[t.startIndex..<eq])
            let isIdentifier = !key.isEmpty
                && key.allSatisfy({ $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) })
                && !(key.first?.isNumber ?? true)
            if isIdentifier && !Self.managedKeys.contains(key) {
                kept.append(line)
            }
        }
        return kept
    }

    // MARK: Read

    /// Inverse of `q(_:)` — unwraps a bash double-quoted value and unescapes
    /// \\ \" \$ \`. Falls back to stripping quotes for legacy unquoted confs.
    private static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") else {
            return t.replacingOccurrences(of: "\"", with: "")
        }
        let inner = String(t.dropFirst().dropLast())
        var out = ""
        var i = inner.startIndex
        while i < inner.endIndex {
            if inner[i] == "\\" {
                let n = inner.index(after: i)
                if n < inner.endIndex, "\\\"$`".contains(inner[n]) {
                    out.append(inner[n]); i = inner.index(after: n); continue
                }
            }
            out.append(inner[i]); i = inner.index(after: i)
        }
        return out
    }

    func read() -> ServerConfig {
        var config = ServerConfig()
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return config }
        for line in content.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let raw = Self.unquote(parts[1])
            switch parts[0] {
            case "PORT":        config.port = raw
            case "CONTEXT":     config.context = raw
            case "HOST":        config.host = raw
            case "API_KEY":     config.apiKey = raw
            case "NGL":         config.ngl = raw
            case "FA":          config.fa = raw
            case "CTK":         config.ctk = raw
            case "CTV":         config.ctv = raw
            case "THREADS":     config.threads = raw
            case "BATCH_SIZE":  config.batchSize = raw
            case "UBATCH_SIZE": config.ubatchSize = raw
            case "CACHE_REUSE": config.cacheReuse = raw
            case "MLOCK":       config.mlock = raw
            case "THREADS_BATCH": config.threadsBatch = raw
            case "REASONING_EFFORT": config.reasoningEffort = raw
            case "REASONING_BUDGET": config.reasoningBudget = raw
            case "PROFILE":     config.profile = raw
            case "MODEL_LABEL": config.modelLabel = raw
            case "MODEL_REPO":  config.modelRepo = raw
            case "MODEL_FILE":  config.modelFile = raw
            case "MODEL_PATH":  config.modelPath = raw
            default: break
            }
        }
        return config
    }

    // MARK: Write server.conf

    /// Escapes a value so it is a safe bash double-quoted string when the conf
    /// is `source`d: backslash first, then `"`, `$` and backtick; newlines
    /// removed so a value can never span lines.
    private func q(_ s: String) -> String {
        var v = s.replacingOccurrences(of: "\r", with: "")
        v = v.replacingOccurrences(of: "\n", with: " ")
        v = v.replacingOccurrences(of: "\\", with: "\\\\")
        v = v.replacingOccurrences(of: "\"", with: "\\\"")
        v = v.replacingOccurrences(of: "$", with: "\\$")
        v = v.replacingOccurrences(of: "`", with: "\\`")
        return v
    }

    func write(_ config: ServerConfig) throws {
        let content = """
        # llama.cpp — generated by LlamaMate
        MODEL_LABEL="\(q(config.modelLabel))"
        MODEL_REPO="\(q(config.modelRepo))"
        MODEL_FILE="\(q(config.modelFile))"
        MODEL_PATH="\(q(config.modelPath))"
        PORT="\(q(config.port))"
        CONTEXT="\(q(config.context))"
        HOST="\(q(config.host))"
        API_KEY="\(q(config.apiKey))"
        NGL="\(q(config.ngl))"
        FA="\(q(config.fa))"
        CTK="\(q(config.ctk))"
        CTV="\(q(config.ctv))"
        THREADS="\(q(config.threads))"
        BATCH_SIZE="\(q(config.batchSize))"
        UBATCH_SIZE="\(q(config.ubatchSize))"
        CACHE_REUSE="\(q(config.cacheReuse))"
        MLOCK="\(q(config.mlock))"
        THREADS_BATCH="\(q(config.threadsBatch))"
        REASONING_EFFORT="\(q(config.reasoningEffort))"
        REASONING_BUDGET="\(q(config.reasoningBudget))"
        PROFILE="\(q(config.profile))"
        """
        let preserved = unmanagedLines()
        let fullContent = preserved.isEmpty
            ? content + "\n"
            : content + "\n\n# ── Preserved (not managed by LlamaMate) ──\n" + preserved.joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fullContent.write(toFile: configPath, atomically: true, encoding: .utf8)
        // server.conf may hold an API key — keep it owner-only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
        if let backup = try writeStartScript() {
            notifyStartScriptBackup(backup)
        }
    }

    // MARK: Apply changes (write + reload + restart)

    func apply(_ config: ServerConfig) throws {
        // Restarting clears llama-server's prompt cache (a long agent prompt can
        // take a minute to process again), so only restart when something
        // actually changed — or when the server is not running.
        let changed = config != read()
        try write(config)
        if changed || ServerManager.shared.state == .stopped {
            ServerManager.shared.reloadConfigAndRestart()
        }
    }

    // MARK: Start script

    /// Installs the start script by copying the canonical
    /// `llama-server-start.sh` bundled in the app's Resources. The script is a
    /// single source of truth shared with `install-llama.sh`; it reads all of
    /// its parameters from `server.conf` at launch, so it does not need to be
    /// regenerated when settings change — only (re)installed.
    /// Returns the path of a backup if the installed script had been edited by
    /// hand (it is saved as llama-server-start.sh.user-<timestamp> first).
    @discardableResult
    func writeStartScript() throws -> String? {
        try FileManager.default.createDirectory(atPath: (startScriptPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        guard let resPath = Bundle.main.resourcePath else {
            throw NSError(domain: "LlamaMate", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not locate app resources."])
        }
        let bundled = resPath + "/llama-server-start.sh"
        guard FileManager.default.fileExists(atPath: bundled) else {
            throw NSError(domain: "LlamaMate", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Bundled llama-server-start.sh is missing from the app."])
        }

        // Atomic install: stage into a temp file in the same directory, make it
        // executable, then swap it into place — there is never a window where
        // the start script is missing or half-written.
        let fm = FileManager.default

        // Keep hand edits: back up an installed script that is neither the new
        // one, nor a known shipped version, nor the last one we installed.
        var backupPath: String?
        if let current = fm.contents(atPath: startScriptPath),
           let incoming = fm.contents(atPath: bundled),
           current != incoming {
            let currentHash = Self.sha256Hex(current)
            let lastInstalled = (try? String(contentsOfFile: startScriptHashPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if currentHash != lastInstalled && !Self.knownShippedStartScriptHashes.contains(currentHash) {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyyMMdd-HHmmss"
                fmt.locale = Locale(identifier: "en_US_POSIX")
                let bak = startScriptPath + ".user-" + fmt.string(from: Date())
                if (try? fm.copyItem(atPath: startScriptPath, toPath: bak)) != nil {
                    backupPath = bak
                }
            }
        }

        let tmpPath = startScriptPath + ".new-\(ProcessInfo.processInfo.processIdentifier)"
        if fm.fileExists(atPath: tmpPath) { try fm.removeItem(atPath: tmpPath) }
        try fm.copyItem(atPath: bundled, toPath: tmpPath)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpPath)

        if fm.fileExists(atPath: startScriptPath) {
            _ = try fm.replaceItemAt(URL(fileURLWithPath: startScriptPath),
                                     withItemAt: URL(fileURLWithPath: tmpPath))
        } else {
            try fm.moveItem(atPath: tmpPath, toPath: startScriptPath)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: startScriptPath)

        if let installed = fm.contents(atPath: startScriptPath) {
            try? fm.createDirectory(atPath: (startScriptHashPath as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            try? (Self.sha256Hex(installed) + "\n").write(toFile: startScriptHashPath, atomically: true, encoding: .utf8)
        }
        writeLocalConfigTemplateIfMissing()
        return backupPath
    }

    /// Creates a commented server.local.conf once. Never touches an existing one.
    func writeLocalConfigTemplateIfMissing() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: localConfigPath) else { return }
        let template = """
        # server.local.conf — your own llama-server settings.
        # LlamaMate never writes or overwrites this file, so it survives updates.
        # It is read after server.conf, before the server starts.
        #
        # Extra llama-server flags (space-separated; values with spaces not supported):
        # EXTRA_ARGS="-np 1"
        #
        # Many llama-server options can also be set as environment variables
        # (used only when LlamaMate does not pass that flag itself):
        # export LLAMA_ARG_N_PARALLEL=1

        """
        try? fm.createDirectory(atPath: (localConfigPath as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        if (try? template.write(toFile: localConfigPath, atomically: true, encoding: .utf8)) != nil {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localConfigPath)
        }
    }

    // MARK: Paths (read-only access)

    var configFilePath: String { configPath }
    var startScriptFilePath: String { startScriptPath }
}
