import Foundation

// MARK: - Hugging Face API

struct HFModelSummary {
    let id: String
    let downloads: Int
    let lastModified: String
}

struct HFRepoFile {
    let path: String
    let size: Int64
    let quant: String
}

enum HFError: Error, LocalizedError {
    case noInternet
    case rateLimited
    case invalidResponse
    case http(Int)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .noInternet:        return "No internet connection."
        case .rateLimited:       return "Hugging Face rate limit reached. Add a token in About → HF Token… for higher limits."
        case .invalidResponse:   return "Unexpected response from Hugging Face."
        case .http(let code):    return "Hugging Face returned HTTP \(code)."
        case .parse(let msg):    return "Could not parse Hugging Face response: \(msg)"
        }
    }
}

final class HuggingFaceAPI {
    static let shared = HuggingFaceAPI()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func authorizedRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        if let token = UserDefaults.standard.string(forKey: "hf_token"), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    func searchModels(query: String, completion: @escaping (Result<[HFModelSummary], HFError>) -> Void) {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
        ]
        guard let url = components.url else {
            completion(.failure(.invalidResponse))
            return
        }

        let task = session.dataTask(with: authorizedRequest(url)) { data, response, error in
            if let err = error as NSError?, err.domain == NSURLErrorDomain {
                DispatchQueue.main.async { completion(.failure(.noInternet)) }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(.invalidResponse)) }
                return
            }
            if http.statusCode == 429 {
                DispatchQueue.main.async { completion(.failure(.rateLimited)) }
                return
            }
            guard (200...299).contains(http.statusCode), let data = data else {
                DispatchQueue.main.async { completion(.failure(.http(http.statusCode))) }
                return
            }
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                DispatchQueue.main.async { completion(.failure(.parse("not an array"))) }
                return
            }
            let models = arr.compactMap { d -> HFModelSummary? in
                guard let id = d["id"] as? String else { return nil }
                let downloads = (d["downloads"] as? Int) ?? 0
                let lastModified = (d["lastModified"] as? String) ?? ""
                return HFModelSummary(id: id, downloads: downloads, lastModified: lastModified)
            }
            DispatchQueue.main.async { completion(.success(models)) }
        }
        task.resume()
    }

    func listRepoFiles(repo: String, completion: @escaping (Result<[HFRepoFile], HFError>) -> Void) {
        let url = URL(string: "https://huggingface.co/api/models/\(repo)")!
        let task = session.dataTask(with: authorizedRequest(url)) { data, response, error in
            if let err = error as NSError?, err.domain == NSURLErrorDomain {
                DispatchQueue.main.async { completion(.failure(.noInternet)) }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(.invalidResponse)) }
                return
            }
            if http.statusCode == 429 {
                DispatchQueue.main.async { completion(.failure(.rateLimited)) }
                return
            }
            guard (200...299).contains(http.statusCode), let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                DispatchQueue.main.async { completion(.failure(.http(code))) }
                return
            }
            guard let siblings = json["siblings"] as? [[String: Any]] else {
                DispatchQueue.main.async { completion(.success([])) }
                return
            }
            let gguf = siblings.compactMap { s -> String? in
                guard let rfilename = s["rfilename"] as? String else { return nil }
                return rfilename.hasSuffix(".gguf") ? rfilename : nil
            }
            self.fetchSizes(repo: repo, files: gguf, completion: completion)
        }
        task.resume()
    }

    private func fetchSizes(repo: String, files: [String], completion: @escaping (Result<[HFRepoFile], HFError>) -> Void) {
        guard !files.isEmpty else {
            completion(.success([]))
            return
        }
        let group = DispatchGroup()
        var result: [HFRepoFile] = []
        let lock = NSLock()

        for file in files {
            group.enter()
            let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")!
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            if let token = UserDefaults.standard.string(forKey: "hf_token"), !token.isEmpty {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            session.dataTask(with: req) { _, response, _ in
                defer { group.leave() }
                guard let http = response as? HTTPURLResponse else { return }
                let size = Int64(http.expectedContentLength)
                let item = HFRepoFile(path: file, size: size, quant: Self.parseQuant(file))
                lock.lock()
                result.append(item)
                lock.unlock()
            }.resume()
        }

        group.notify(queue: .main) {
            let sorted = result.sorted { $0.size > $1.size }
            completion(.success(sorted))
        }
    }

    static func parseQuant(_ filename: String) -> String {
        let upper = filename.uppercased()
        let patterns = ["Q2_K", "Q3_K_S", "Q3_K_M", "Q3_K_L", "Q4_0", "Q4_1", "Q4_K_S", "Q4_K_M", "Q5_0", "Q5_1", "Q5_K_S", "Q5_K_M", "Q6_K", "Q8_0", "F16", "F32", "BF16"]
        for p in patterns where upper.contains(p) {
            return p
        }
        return "—"
    }
}