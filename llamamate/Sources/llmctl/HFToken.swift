import AppKit
import Foundation

extension Notification.Name {
    /// Posted on the main thread whenever the Hugging Face token is saved or removed.
    static let hfTokenChanged = Notification.Name("LlamaMateHFTokenChanged")
}

/// The Hugging Face token LlamaMate uses for downloads and API calls.
///
/// Order: the token saved in LlamaMate (Keychain), else the token from a
/// Hugging Face CLI login (`hf auth login`, ~/.cache/huggingface/token).
/// No token is needed for public models — it's only asked for when Hugging Face
/// rate-limits us or a model is gated.
enum HFToken {
    enum Source { case keychain, cli }

    /// Path of the token written by the Hugging Face CLI. Honours HF_TOKEN_PATH
    /// and HF_HOME like the CLI does.
    static var cliTokenPath: String {
        let env = ProcessInfo.processInfo.environment
        if let p = env["HF_TOKEN_PATH"], !p.isEmpty { return (p as NSString).expandingTildeInPath }
        if let home = env["HF_HOME"], !home.isEmpty { return (home as NSString).expandingTildeInPath + "/token" }
        return NSHomeDirectory() + "/.cache/huggingface/token"
    }

    /// Token from a Hugging Face CLI login, if any.
    static var cliToken: String? {
        guard let raw = try? String(contentsOfFile: cliTokenPath, encoding: .utf8) else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// The token to use right now and where it came from.
    static var current: (token: String, source: Source)? {
        if let k = KeychainStore.hfToken { return (k, .keychain) }
        if let c = cliToken { return (c, .cli) }
        return nil
    }

    static var value: String? { current?.token }

    // MARK: Account check

    private static var cachedNames: [String: String] = [:]   // token -> user name

    /// Checks a token with Hugging Face. Completion runs on the main thread with
    /// the account name, or an error message.
    static func whoami(_ token: String, completion: @escaping (Result<String, Error>) -> Void) {
        if let name = cachedNames[token] { completion(.success(name)); return }
        guard let url = URL(string: "https://huggingface.co/api/whoami-v2") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, response, error in
            let result: Result<String, Error>
            if let error = error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                result = .failure(TokenError.rejected)
            } else if let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = json["name"] as? String {
                result = .success(name)
            } else {
                result = .failure(TokenError.unexpected)
            }
            DispatchQueue.main.async {
                if case .success(let name) = result { cachedNames[token] = name }
                completion(result)
            }
        }.resume()
    }

    enum TokenError: LocalizedError {
        case rejected, unexpected
        var errorDescription: String? {
            switch self {
            case .rejected:   return "Hugging Face rejected this token."
            case .unexpected: return "Unexpected answer from Hugging Face."
            }
        }
    }

    // MARK: Token window

    /// Shows the token window (as a sheet on `parent` when given).
    /// `reason` is an optional first line explaining why it's being asked.
    static func presentEditor(parent: NSWindow?, reason: String? = nil) {
        let editor = TokenEditor(reason: reason)
        editor.present(parent: parent)
    }

    // MARK: Just-in-time help

    /// Explains a Hugging Face access error (rate limit, login required, licence
    /// not accepted, token rejected) and offers the right next step.
    static func handleAccessError(status: Int, repo: String?, parent: NSWindow?) {
        let hasToken = current != nil
        let alert = NSAlert()
        alert.alertStyle = .warning
        var actions: [(String, () -> Void)] = []
        let openRepo: () -> Void = {
            if let repo = repo, let url = URL(string: "https://huggingface.co/\(repo)") {
                NSWorkspace.shared.open(url)
            }
        }

        switch status {
        case 429:
            alert.messageText = "Hugging Face is limiting downloads"
            alert.informativeText = hasToken
                ? "Too many requests in a short time. Wait a few minutes and try again."
                : "Too many requests from this network without a login. A free Hugging Face token raises the limit — or wait a few minutes and try again."
            if !hasToken { actions.append(("Add Token…", { presentEditor(parent: parent, reason: "A token raises Hugging Face's download limits.") })) }
            actions.append(("OK", {}))
        case 401 where hasToken:
            alert.messageText = "Hugging Face rejected your token"
            alert.informativeText = "The token may have been deleted or expired. Add a new one, or remove it to continue without a login (public models don't need one)."
            actions.append(("Change Token…", { presentEditor(parent: parent) }))
            actions.append(("Cancel", {}))
        case 401, 403:
            if hasToken {
                alert.messageText = "This model needs your approval on Hugging Face"
                alert.informativeText = "\(repo ?? "This model") is gated. Open its page, sign in with the same account as your token, and accept the licence — then download again."
                if repo != nil { actions.append(("Open Model Page", openRepo)) }
                actions.append(("Change Token…", { presentEditor(parent: parent) }))
                actions.append(("Cancel", {}))
            } else {
                alert.messageText = "This model requires a Hugging Face login"
                alert.informativeText = "\(repo ?? "This model") is gated or private. Add a free Hugging Face token, and accept the model's licence on its page if it asks."
                actions.append(("Add Token…", { presentEditor(parent: parent, reason: "This model requires a Hugging Face login.") }))
                if repo != nil { actions.append(("Open Model Page", openRepo)) }
                actions.append(("Cancel", {}))
            }
        default:
            return
        }

        for (title, _) in actions { alert.addButton(withTitle: title) }
        let run: (NSApplication.ModalResponse) -> Void = { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if index >= 0 && index < actions.count {
                // Let the alert close before opening a sheet on the same window.
                DispatchQueue.main.async { actions[index].1() }
            }
        }
        if let parent = parent, parent.isVisible {
            alert.beginSheetModal(for: parent, completionHandler: run)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            run(alert.runModal())
        }
    }
}

// MARK: - Token editor

/// Small window to paste, test, save or remove the token.
private final class TokenEditor: NSObject {
    private static var active: TokenEditor?   // keep alive while shown

    private let reason: String?
    private let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 22))
    private let status = NSTextField(wrappingLabelWithString: "")

    init(reason: String?) {
        self.reason = reason
        super.init()
    }

    func present(parent: NSWindow?) {
        TokenEditor.active = self

        let alert = NSAlert()
        alert.messageText = "Hugging Face Token"
        var info = ""
        if let reason = reason { info += reason + "\n\n" }
        info += "Optional — public models download without one. A free token raises download limits and lets you use gated models.\n\nCreate a token with Read access, then paste it below. It's stored in your macOS Keychain."
        alert.informativeText = info

        let width: CGFloat = 360
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 124))

        field.frame = NSRect(x: 0, y: 98, width: width, height: 22)
        field.placeholderString = "hf_…"
        if let saved = KeychainStore.hfToken { field.stringValue = saved }
        accessory.addSubview(field)

        let getToken = NSButton(title: "Get a free token…", target: self, action: #selector(openTokensPage))
        getToken.bezelStyle = .rounded
        getToken.frame = NSRect(x: 0, y: 64, width: 150, height: 26)
        accessory.addSubview(getToken)

        let test = NSButton(title: "Test", target: self, action: #selector(testToken))
        test.bezelStyle = .rounded
        test.frame = NSRect(x: 156, y: 64, width: 80, height: 26)
        accessory.addSubview(test)

        if let cli = HFToken.cliToken, cli != KeychainStore.hfToken {
            let useCLI = NSButton(title: "Use CLI login", target: self, action: #selector(useCLIToken))
            useCLI.bezelStyle = .rounded
            useCLI.frame = NSRect(x: 242, y: 64, width: 118, height: 26)
            useCLI.toolTip = "Use the token from your Hugging Face CLI login (\(HFToken.cliTokenPath))."
            accessory.addSubview(useCLI)
        }

        status.frame = NSRect(x: 0, y: 0, width: width, height: 56)
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        accessory.addSubview(status)
        describeCurrent()

        alert.accessoryView = accessory
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let canRemove = KeychainStore.hfToken != nil
        if canRemove { alert.addButton(withTitle: "Remove Token") }
        alert.window.initialFirstResponder = field

        let finish: (NSApplication.ModalResponse) -> Void = { [self] response in
            switch response {
            case .alertFirstButtonReturn:
                let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty {
                    KeychainStore.setHFToken(token)
                    NotificationCenter.default.post(name: .hfTokenChanged, object: nil)
                }
            case .alertThirdButtonReturn where canRemove:
                KeychainStore.delete(KeychainStore.hfTokenAccount)
                NotificationCenter.default.post(name: .hfTokenChanged, object: nil)
            default:
                break
            }
            TokenEditor.active = nil
        }

        if let parent = parent, parent.isVisible {
            alert.beginSheetModal(for: parent, completionHandler: finish)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            finish(alert.runModal())
        }
    }

    private func describeCurrent() {
        switch HFToken.current?.source {
        case .keychain?: status.stringValue = "A token is saved in LlamaMate."
        case .cli?:      status.stringValue = "Using your Hugging Face CLI login. Save a token here to use a different one."
        case nil:        status.stringValue = "No token — public models still work."
        }
    }

    @objc private func openTokensPage() {
        if let url = URL(string: "https://huggingface.co/settings/tokens") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func useCLIToken() {
        guard let cli = HFToken.cliToken else { return }
        field.stringValue = cli
        testToken()
    }

    @objc private func testToken() {
        let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            status.stringValue = "Paste a token first."
            status.textColor = .systemOrange
            return
        }
        status.stringValue = "Checking…"
        status.textColor = .secondaryLabelColor
        HFToken.whoami(token) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let name):
                self.status.stringValue = "✓ Works — signed in as \(name)."
                self.status.textColor = .systemGreen
            case .failure(let error):
                self.status.stringValue = error.localizedDescription
                self.status.textColor = .systemRed
            }
        }
    }
}
