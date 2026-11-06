import Foundation

/// The handful of GGUF metadata fields needed to estimate KV-cache size.
struct GGUFMetadata {
    var architecture: String?
    var blockCount: Int?
    var headCountKV: Int?
    var keyLength: Int?
    var embeddingLength: Int?
    var headCount: Int?
    var contextLength: Int?

    /// Per-head key dimension: explicit key_length, else embedding/head_count.
    var effectiveKeyLength: Int? {
        if let k = keyLength, k > 0 { return k }
        if let e = embeddingLength, let h = headCount, h > 0 { return e / h }
        return nil
    }

    var isComplete: Bool {
        blockCount != nil && headCountKV != nil && effectiveKeyLength != nil
    }
}

/// Minimal, bounds-checked GGUF header reader. Reads at most `maxBytes` and
/// skips every value type (including string and nested arrays such as the
/// hundreds-of-thousands-long tokenizer.ggml.tokens) without materializing them.
enum GGUFInfo {
    // GGUF value type ids
    private enum T { static let u8=0, i8=1, u16=2, i16=3, u32=4, i32=5, f32=6, bool=7, string=8, array=9, u64=10, i64=11, f64=12 }

    static func read(path: String, maxBytes: Int = 16 * 1024 * 1024) -> GGUFMetadata? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), data.count >= 24 else { return nil }

        var c = Cursor(data)
        guard c.take(4).elementsEqual(Array("GGUF".utf8)) else { return nil }
        guard let version = c.u32() else { return nil }
        let wide = version >= 2   // v2+ uses 64-bit lengths/counts
        guard c.len(wide) != nil, let kvCount = c.len(wide) else { return nil }

        var arch: String?
        var numeric: [String: Int] = [:]

        var i = 0
        while i < kvCount {
            i += 1
            guard let key = c.ggufString(wide) else { break }
            guard let vtype = c.u32() else { break }
            switch Int(vtype) {
            case T.string:
                guard let s = c.ggufString(wide) else { break }
                if key == "general.architecture" { arch = s }
            case T.u8, T.i8, T.u16, T.i16, T.u32, T.i32, T.u64, T.i64:
                if let v = c.scalarInt(Int(vtype)) { numeric[key] = v }
            case T.f32: _ = c.skip(4)
            case T.f64: _ = c.skip(8)
            case T.bool: _ = c.skip(1)
            case T.array: if !c.skipArray(wide) { i = kvCount } // stop on bad array
            default: i = kvCount // unknown type: stop, use what we have
            }
            if c.failed { break }
        }

        var meta = GGUFMetadata()
        meta.architecture = arch
        if let a = arch {
            meta.blockCount = numeric["\(a).block_count"]
            meta.headCountKV = numeric["\(a).attention.head_count_kv"]
            meta.keyLength = numeric["\(a).attention.key_length"]
            meta.embeddingLength = numeric["\(a).embedding_length"]
            meta.headCount = numeric["\(a).attention.head_count"]
            meta.contextLength = numeric["\(a).context_length"]
        }
        return meta
    }

    /// Cursor over an in-memory byte buffer, little-endian, bounds-checked.
    private struct Cursor {
        let d: [UInt8]
        var i = 0
        var failed = false
        init(_ data: Data) { d = [UInt8](data) }

        mutating func need(_ n: Int) -> Bool {
            if failed || i + n > d.count { failed = true; return false }
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
            if wide { return u64().map { Int($0) } }
            return u32().map { Int($0) }
        }
        mutating func ggufString(_ wide: Bool) -> String? {
            guard let n = len(wide), n >= 0, need(n) else { failed = true; return nil }
            defer { i += n }
            return String(decoding: d[i..<i+n], as: UTF8.self)
        }
        /// Read a scalar integer of the given GGUF type as Int.
        mutating func scalarInt(_ t: Int) -> Int? {
            switch t {
            case T.u8, T.i8, T.bool: guard need(1) else { return nil }; defer { i += 1 }; return Int(d[i])
            case T.u16, T.i16: guard need(2) else { return nil }; defer { i += 2 }; return Int(d[i]) | Int(d[i+1])<<8
            case T.u32, T.i32: return u32().map { Int(Int32(bitPattern: $0)) }
            case T.u64, T.i64: return u64().map { Int(bitPattern: UInt($0)) }
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
        /// Skip an array value (elemType, count, then the elements).
        mutating func skipArray(_ wide: Bool) -> Bool {
            guard let et = u32(), let count = len(wide), count >= 0 else { return false }
            let t = Int(et)
            if let sz = scalarSize(t) {
                return skip(sz * count)           // fixed-size elements in one jump
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
