import Foundation

// MARK: - Curated shortlist

/// One entry of the curated model shortlist (catalog/models.json).
struct CuratedModel: Decodable {
    let id: String            // Hugging Face repo, e.g. "unsloth/Qwen3.5-9B-GGUF"
    let displayName: String
    let sizeGB: Double        // size of the ~4-bit file (verified in CI)
    let minRAM: Int           // recommended Mac memory in GB
    let description: String
    /// From the opt-in "community" list (fine-tunes / uncensored by third parties).
    var isCommunity = false

    enum CodingKeys: String, CodingKey {
        case id, sizeGB, minRAM, description
        case displayName = "name"
    }

    var sizeText: String { String(format: "~%.1f GB", sizeGB) }
    var ramText: String { "\(minRAM) GB+" }

    /// True when this Mac has less memory than the model needs.
    var exceedsThisMac: Bool {
        let macGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return Double(minRAM) > macGB + 0.5
    }
}

private struct CatalogFile: Decodable {
    let version: Int
    let models: [CuratedModel]
    /// Opt-in list. A separate key so app versions without the opt-in
    /// (v2.5.3) never show these entries.
    let community: [CuratedModel]?
}

private struct Catalog {
    var models: [CuratedModel]
    var community: [CuratedModel]
}

/// The shortlist shown in Models → Browse. It lives in the repository
/// (catalog/models.json) so it can be updated without an app release:
/// the app uses a cached download, else the copy bundled in the app, and
/// refreshes from GitHub in the background at most every few hours.
/// Every entry is checked against Hugging Face in CI before it's published.
final class ModelCatalog {
    static let shared = ModelCatalog()

    static let remoteURL = URL(string: "https://raw.githubusercontent.com/Ito-69/llama.cpp_install_on_macos/main/catalog/models.json")!
    private static let refreshInterval: TimeInterval = 6 * 3600

    private let cachePath = APP_SUPPORT_DIR + "/models.json"
    private var bundledPath: String? { Bundle.main.path(forResource: "models", ofType: "json") }
    private var refreshing = false

    private(set) var models: [CuratedModel] = []
    private(set) var community: [CuratedModel] = []

    private init() {
        let catalog = Self.load(path: cachePath) ?? bundledPath.flatMap { Self.load(path: $0) }
        models = catalog?.models ?? []
        community = catalog?.community ?? []
    }

    private static func decode(_ data: Data) -> Catalog? {
        guard let file = try? JSONDecoder().decode(CatalogFile.self, from: data),
              file.version == 1, !file.models.isEmpty else { return nil }
        let community = (file.community ?? []).map { m -> CuratedModel in
            var c = m
            c.isCommunity = true
            return c
        }
        return Catalog(models: file.models, community: community)
    }

    private static func load(path: String) -> Catalog? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return decode(data)
    }

    /// Downloads the latest catalog if the cached one is older than the refresh
    /// interval. `completion(true)` (main thread) when the list changed.
    func refreshIfStale(completion: @escaping (Bool) -> Void) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: cachePath)
        if let modified = attrs?[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < Self.refreshInterval {
            return
        }
        guard !refreshing else { return }
        refreshing = true

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        URLSession(configuration: cfg).dataTask(with: Self.remoteURL) { [weak self] data, response, _ in
            guard let self = self else { return }
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let fresh = ok ? data.flatMap(Self.decode) : nil
            DispatchQueue.main.async {
                self.refreshing = false
                guard let fresh = fresh, let data = data else { return }
                try? FileManager.default.createDirectory(atPath: APP_SUPPORT_DIR, withIntermediateDirectories: true)
                try? data.write(to: URL(fileURLWithPath: self.cachePath), options: .atomic)
                let all = fresh.models + fresh.community
                let old = self.models + self.community
                let changed = all.map(\.id) != old.map(\.id)
                    || all.map(\.description) != old.map(\.description)
                self.models = fresh.models
                self.community = fresh.community
                completion(changed)
            }
        }.resume()
    }
}
