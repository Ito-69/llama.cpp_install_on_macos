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
    case unauthorized(Int)      // 401/403: login required, licence not accepted, or bad token
    case invalidResponse
    case http(Int)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .noInternet:        return "No internet connection."
        case .rateLimited:       return "Hugging Face is limiting requests — try again in a few minutes, or add a token (Hugging Face: Set Token… at the top of this window)."
        case .unauthorized:      return "This model needs a Hugging Face login or licence approval."
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
        if let token = HFToken.value {
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
            if http.statusCode == 401 || http.statusCode == 403 {
                let code = http.statusCode
                DispatchQueue.main.async { completion(.failure(.unauthorized(code))) }
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

    /// Lists the .gguf files in a repo with their real sizes using the tree
    /// API (one paginated call that already carries sizes), instead of a HEAD
    /// request per file. Follows the `Link: …; rel="next"` header.
    func listRepoFiles(repo: String, completion: @escaping (Result<[HFRepoFile], HFError>) -> Void) {
        var collected: [HFRepoFile] = []

        func fetchPage(_ url: URL) {
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
                if http.statusCode == 401 || http.statusCode == 403 {
                    let code = http.statusCode
                    DispatchQueue.main.async { completion(.failure(.unauthorized(code))) }
                    return
                }
                guard (200...299).contains(http.statusCode), let data = data,
                      let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    DispatchQueue.main.async { completion(.failure(.http(http.statusCode))) }
                    return
                }
                for entry in arr {
                    guard (entry["type"] as? String) == "file",
                          let path = entry["path"] as? String, path.hasSuffix(".gguf") else { continue }
                    var size = (entry["size"] as? NSNumber)?.int64Value ?? 0
                    if let lfs = entry["lfs"] as? [String: Any],
                       let lfsSize = (lfs["size"] as? NSNumber)?.int64Value {
                        size = lfsSize
                    }
                    collected.append(HFRepoFile(path: path, size: size, quant: Self.parseQuant(path)))
                }
                if let link = http.value(forHTTPHeaderField: "Link"),
                   let next = Self.parseNextLink(link),
                   let nextURL = URL(string: next, relativeTo: URL(string: "https://huggingface.co")) {
                    fetchPage(nextURL)
                } else {
                    let sorted = collected.sorted { $0.size > $1.size }
                    DispatchQueue.main.async { completion(.success(sorted)) }
                }
            }
            task.resume()
        }

        guard var comps = URLComponents(string: "https://huggingface.co/api/models/\(repo)/tree/main") else {
            completion(.failure(.invalidResponse)); return
        }
        comps.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        guard let url = comps.url else { completion(.failure(.invalidResponse)); return }
        fetchPage(url)
    }

    /// Extracts the `next` URL from an RFC 5988 Link header, if present.
    static func parseNextLink(_ header: String) -> String? {
        for part in header.split(separator: ",") {
            let segs = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard segs.count >= 2,
                  segs.dropFirst().contains(where: { $0.replacingOccurrences(of: " ", with: "") == "rel=\"next\"" }) else { continue }
            var u = segs[0]
            if u.hasPrefix("<") && u.hasSuffix(">") { u = String(u.dropFirst().dropLast()) }
            return u
        }
        return nil
    }

    static func parseQuant(_ filename: String) -> String {
        let upper = filename.uppercased()
        // Longest / most specific patterns first so e.g. IQ4_XS wins over Q4
        // and BF16 over F16.
        let patterns = [
            "IQ1_S", "IQ1_M", "IQ2_XXS", "IQ2_XS", "IQ2_S", "IQ2_M",
            "IQ3_XXS", "IQ3_XS", "IQ3_S", "IQ3_M", "IQ4_XS", "IQ4_NL",
            "Q2_K_L", "Q3_K_XL", "Q4_K_L", "Q5_K_L", "Q6_K_L",
            "Q3_K_S", "Q3_K_M", "Q3_K_L", "Q4_K_S", "Q4_K_M",
            "Q5_K_S", "Q5_K_M", "Q2_K", "Q6_K", "Q8_0",
            "Q4_0", "Q4_1", "Q5_0", "Q5_1",
            "MXFP4", "BF16", "F16", "F32",
        ]
        for p in patterns where upper.contains(p) {
            return p
        }
        return "—"
    }
}