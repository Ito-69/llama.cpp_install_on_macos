import Foundation

/// The GGUF metadata fields needed to estimate KV-cache size and to detect
/// optional model features (MTP heads).
struct GGUFMetadata {
    var architecture: String?
    var blockCount: Int?
    var headCountKV: Int?
    /// Per-layer KV head counts, when the model stores them as an array
    /// (hybrid models use 0 for layers without attention).
    var headCountKVPerLayer: [Int]?
    /// Per-layer flags (non-zero = recurrent, i.e. no KV cache), if present.
    var recurrentLayers: [Int]?
    var fullAttentionInterval: Int?
    var keyLength: Int?
    var embeddingLength: Int?
    var headCount: Int?
    var contextLength: Int?
    var slidingWindow: Int?
    /// `<arch>.nextn_predict_layers`: number of MTP (multi-token prediction) layers.
    var nextnPredictLayers: Int?
    /// Whether tensors named `*.nextn.*` were found in the tensor index.
    /// nil = the index could not be read within the header window.
    var hasNextnTensors: Bool?

    /// Hybrid architectures that mark full-attention layers by an interval,
    /// with llama.cpp's default interval when the key is absent.
    static let defaultFullAttentionInterval: [String: Int] = [
        "qwen3next": 4, "qwen35": 4, "qwen35moe": 4, "qwen4exp": 4, "minimax-01": 8,
    ]

    /// Per-head key dimension: explicit key_length, else embedding/head_count.
    var effectiveKeyLength: Int? {
        if let k = keyLength, k > 0 { return k }
        if let e = embeddingLength, let h = headCount, h > 0 { return e / h }
        return nil
    }

    /// True when the model ships MTP heads that llama.cpp can use for
    /// speculative decoding (`--spec-type draft-mtp`).
    var supportsMTP: Bool {
        (nextnPredictLayers ?? 0) > 0 && hasNextnTensors == true
    }

    /// Sum of KV heads over all layers that actually keep a KV cache. Hybrid
    /// models (Gated DeltaNet / Mamba layers) only cache their attention layers.
    var totalKVHeads: Int? {
        guard let n = blockCount, n > 0 else { return nil }
        if let perLayer = headCountKVPerLayer, !perLayer.isEmpty {
            return perLayer.prefix(n).reduce(0) { $0 + max(0, $1) }
        }
        guard let nKV = headCountKV, nKV > 0 else { return nil }
        if let recr = recurrentLayers, !recr.isEmpty {
            let attentionLayers = (0..<n).filter { $0 >= recr.count || recr[$0] == 0 }.count
            return nKV * attentionLayers
        }
        let interval = fullAttentionInterval
            ?? architecture.flatMap { Self.defaultFullAttentionInterval[$0] }
        if let iv = interval, iv > 0 {
            // Mirrors llama.cpp: layer i < n_layer is recurrent unless (i+1) % interval == 0;
            // trailing MTP (nextn) layers are attention layers.
            let nextn = max(0, nextnPredictLayers ?? 0)
            let main = max(0, n - nextn)
            let attentionLayers = (0..<main).filter { ($0 + 1) % iv == 0 }.count + nextn
            return nKV * attentionLayers
        }
        return nKV * n
    }

    var isComplete: Bool {
        totalKVHeads != nil && effectiveKeyLength != nil
    }

    /// Sliding-window attention keeps a smaller cache on some layers, so the
    /// full-context estimate is an upper bound.
    var isApproximate: Bool { (slidingWindow ?? 0) > 0 }
}

/// Minimal, bounds-checked GGUF header reader. Reads at most `maxBytes` and
/// skips every value type (including string and nested arrays such as the
/// hundreds-of-thousands-long tokenizer.ggml.tokens) without materializing them.
enum GGUFInfo {
    // GGUF value type ids
    private enum T { static let u8=0, i8=1, u16=2, i16=3, u32=4, i32=5, f32=6, bool=7, string=8, array=9, u64=10, i64=11, f64=12 }

    // Cache keyed by path+mtime so repeated Settings updates don't re-read 16 MB.
    private static var cache: [String: (mtime: TimeInterval, meta: GGUFMetadata)] = [:]
    private static let cacheLock = NSLock()

    static func read(path: String, maxBytes: Int = 16 * 1024 * 1024) -> GGUFMetadata? {
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
        cacheLock.lock()
        if let hit = cache[path], hit.mtime == mtime { cacheLock.unlock(); return hit.meta }
        cacheLock.unlock()

        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), data.count >= 24 else { return nil }

        var c = Cursor(data)
        guard c.take(4).elementsEqual(Array("GGUF".utf8)) else { return nil }
        guard let version = c.u32() else { return nil }
        let wide = version >= 2   // v2+ uses 64-bit lengths/counts
        guard let tensorCount = c.len(wide), let kvCount = c.len(wide) else { return nil }

        var arch: String?
        var numeric: [String: Int] = [:]
        var intArrays: [String: [Int]] = [:]

        var i = 0
        var kvComplete = true
        while i < kvCount {
            i += 1
            guard let key = c.ggufString(wide) else { kvComplete = false; break }
            guard let vtype = c.u32() else { kvComplete = false; break }
            switch Int(vtype) {
            case T.string:
                guard let s = c.ggufString(wide) else { break }
                if key == "general.architecture" { arch = s }
            case T.u8, T.i8, T.u16, T.i16, T.u32, T.i32, T.u64, T.i64, T.bool:
                if let v = c.scalarInt(Int(vtype)) { numeric[key] = v }
            case T.f32: _ = c.skip(4)
            case T.f64: _ = c.skip(8)
            case T.array:
                // Keep the small per-layer integer arrays we need; skip the rest.
                if key.hasSuffix(".attention.head_count_kv") || key.hasSuffix(".attention.recurrent_layers") {
                    if let arr = c.intArray(wide, maxCount: 4096) {
                        intArrays[key] = arr
                    } else if c.failed {
                        i = kvCount
                    }
                } else if !c.skipArray(wide) {
                    i = kvCount // stop on bad array
                }
            default: i = kvCount // unknown type: stop, use what we have
            }
            if c.failed { kvComplete = false; break }
        }

        var meta = GGUFMetadata()
        meta.architecture = arch
        if let a = arch {
            meta.blockCount = numeric["\(a).block_count"]
            meta.headCountKV = numeric["\(a).attention.head_count_kv"]
            meta.headCountKVPerLayer = intArrays["\(a).attention.head_count_kv"]
            meta.recurrentLayers = intArrays["\(a).attention.recurrent_layers"]
            meta.fullAttentionInterval = numeric["\(a).full_attention_interval"]
            meta.keyLength = numeric["\(a).attention.key_length"]
            meta.embeddingLength = numeric["\(a).embedding_length"]
            meta.headCount = numeric["\(a).attention.head_count"]
            meta.contextLength = numeric["\(a).context_length"]
            meta.slidingWindow = numeric["\(a).attention.sliding_window"]
            meta.nextnPredictLayers = numeric["\(a).nextn_predict_layers"]
        }

        // Tensor index follows the KV section: name, n_dims, dims[], type, offset.
        // Only needed to confirm MTP heads are really present in this file.
        if kvComplete, (meta.nextnPredictLayers ?? 0) > 0 {
            var found = false
            var complete = true
            for _ in 0..<max(0, tensorCount) {
                guard let name = c.ggufString(wide),
                      let nDims = c.u32(),
                      c.skip(Int(nDims) * 8),   // dims (u64 each)
                      c.skip(4),                // ggml type
                      c.skip(8)                 // data offset
                else { complete = false; break }
                if name.contains(".nextn.") { found = true; break }
            }
            meta.hasNextnTensors = found ? true : (complete ? false : nil)
        }

        cacheLock.lock()
        cache[path] = (mtime, meta)
        cacheLock.unlock()
        return meta
    }

    /// Cursor over an in-memory byte buffer, little-endian, bounds-checked.
    private struct Cursor {
        let d: [UInt8]
        var i = 0
        var failed = false
        init(_ data: Data) { d = [UInt8](data) }

        mutating func need(_ n: Int) -> Bool {
            if failed || n < 0 || i + n > d.count { failed = true; return false }
            return true
        }
        mutating func take(_ n: Int) -> [UInt8] {
            guard need(n) else { return [] }
            defer { i += n }
            return Array(d[i..<i+n])
        }
        @discardableResult mutating func skip(_ n: Int) -> Bool {
            guard need(n) else { return false }
            i += n; return true
        }
        mutating func u32() -> UInt32? {
            guard need(4) else { return nil }
            defer { i += 4 }
            return UInt32(d[i]) | UInt32(d[i+1])<<8 | UInt32(d[i+2])<<16 | UInt32(d[i+3])<<24
        }
        mutating func u64() -> UInt64? {
            guard need(8) else { return nil }
            var v: UInt64 = 0
            for k in 0..<8 { v |= UInt64(d[i+k]) << (8*k) }
            i += 8; return v
        }
        /// A length/count: 64-bit in GGUF v2+, else 32-bit.
        mutating func len(_ wide: Bool) -> Int? {
            if wide {
                guard let v = u64(), v <= UInt64(Int.max) else { return nil }
                return Int(v)
            }
            return u32().map { Int($0) }
        }
        mutating func ggufString(_ wide: Bool) -> String? {
            guard let n = len(wide), n >= 0, need(n) else { failed = true; return nil }
            defer { i += n }
            return String(decoding: d[i..<i+n], as: UTF8.self)
        }
        /// Read a scalar integer (or bool) of the given GGUF type as Int.
        mutating func scalarInt(_ t: Int) -> Int? {
            switch t {
            case T.u8, T.bool: guard need(1) else { return nil }; defer { i += 1 }; return Int(d[i])
            case T.i8: guard need(1) else { return nil }; defer { i += 1 }; return Int(Int8(bitPattern: d[i]))
            case T.u16: guard need(2) else { return nil }; defer { i += 2 }; return Int(d[i]) | Int(d[i+1])<<8
            case T.i16: guard need(2) else { return nil }; defer { i += 2 }; return Int(Int16(bitPattern: UInt16(d[i]) | UInt16(d[i+1])<<8))
            case T.u32: return u32().map { Int($0) }
            case T.i32: return u32().map { Int(Int32(bitPattern: $0)) }
            case T.u64: return u64().map { $0 > UInt64(Int.max) ? Int.max : Int($0) }
            case T.i64: return u64().map { Int(Int64(bitPattern: $0)) }
            default: return nil
            }
        }
        /// Fixed byte size of a scalar GGUF type, or nil for variable types.
        func scalarSize(_ t: Int) -> Int? {
            switch t {
            case T.u8, T.i8, T.bool: return 1
            case T.u16, T.i16: return 2
            case T.u32, T.i32, T.f32: return 4
            case T.u64, T.i64, T.f64: return 8
            default: return nil
            }
        }
        /// Reads an array of integer/bool elements. Returns nil (after skipping
        /// it) when the elements aren't integers or there are more than maxCount.
        mutating func intArray(_ wide: Bool, maxCount: Int) -> [Int]? {
            guard let et = u32(), let count = len(wide), count >= 0 else { failed = true; return nil }
            let t = Int(et)
            let isInt = [T.u8, T.i8, T.u16, T.i16, T.u32, T.i32, T.u64, T.i64, T.bool].contains(t)
            guard isInt, count <= maxCount else {
                // Not what we want: skip it like any other array.
                if let sz = scalarSize(t) { skip(sz * count); return nil }
                if t == T.string {
                    for _ in 0..<count { if ggufString(wide) == nil { return nil } }
                    return nil
                }
                failed = true
                return nil
            }
            var out: [Int] = []
            out.reserveCapacity(count)
            for _ in 0..<count {
                guard let v = scalarInt(t) else { return nil }
                out.append(v)
            }
            return out
        }
        /// Skip an array value (elemType, count, then the elements).
        mutating func skipArray(_ wide: Bool) -> Bool {
            guard let et = u32(), let count = len(wide), count >= 0 else { return false }
            let t = Int(et)
            if let sz = scalarSize(t) {
                let (bytes, overflow) = sz.multipliedReportingOverflow(by: count)
                return !overflow && skip(bytes)   // fixed-size elements in one jump
            }
            if t == T.string {
                for _ in 0..<count { if ggufString(wide) == nil { return false } }
                return !failed
            }
            if t == T.array {                     // nested arrays
                for _ in 0..<count { if !skipArray(wide) { return false } }
                return !failed
            }
            return false
        }
    }
}
