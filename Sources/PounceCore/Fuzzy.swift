/// Fuzzy subsequence matching. Spaces and case are ignored in the query.
/// Scores favour contiguous runs, word starts, prefix matches and whole-word hits.
///
/// Hot path: candidates are pre-encoded once into a flat `Corpus` (one `UInt32` per
/// Character, with word-start/word-end/whitespace flags packed in), and each candidate
/// carries a 64-bit "character bag" mask so most non-matches are rejected with one AND.
public enum Fuzzy {
    public static func normalize(_ s: String) -> String {
        String(s.lowercased().filter { !$0.isWhitespace })
    }

    /// Returns nil when `query` is not a subsequence of `candidate`.
    /// Empty query matches everything with score 0.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let q = Query(query)
        if q.isEmpty { return 0 }
        return Corpus([candidate]).score(q, 0)
    }

    // MARK: - Encoding

    // Unit layout: bits 0..27 char id, 28 word end, 29 whitespace, 30 word start.
    @usableFromInline static let idMask: UInt32 = 0x0FFF_FFFF
    @usableFromInline static let wordEndBit: UInt32 = 1 << 28
    @usableFromInline static let spaceBit: UInt32 = 1 << 29
    @usableFromInline static let wordStartBit: UInt32 = 1 << 30

    /// Stable id for an already-lowercased Character (scalar value when single-scalar).
    static func id(_ ch: Character) -> UInt32 {
        let scalars = ch.unicodeScalars
        if scalars.count == 1 { return scalars.first!.value }
        var h = Hasher()
        h.combine(ch)
        return 0x11_0000 + UInt32(truncatingIfNeeded: h.finalize()) & 0xF_FFFF
    }

    @inline(__always) static func maskBit(_ id: UInt32) -> UInt64 {
        switch id {
        case 0x61...0x7A: 1 << UInt64(id - 0x61)  // a-z → 0..25
        case 0x30...0x39: 1 << UInt64(id - 0x30 + 26)  // 0-9 → 26..35
        case 0..<0x80: 1 << UInt64(36 + id % 20)  // other ASCII → 36..55
        default: 1 << UInt64(56 + id % 8)  // non-ASCII → 56..63
        }
    }

    @inline(__always) static func isASCIIAlnum(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39)
    }

    @inline(__always) static func isASCIISpace(_ b: UInt8) -> Bool {
        b == 0x20 || (b >= 0x09 && b <= 0x0D)
    }

    /// A normalized (lowercased, whitespace-free) query, pre-encoded.
    public struct Query: Sendable, Equatable {
        public let ids: [UInt32]
        public let mask: UInt64
        public var isEmpty: Bool { ids.isEmpty }
        public var count: Int { ids.count }

        public init(_ s: String) {
            var ids: [UInt32] = []
            ids.reserveCapacity(s.utf8.count)
            var mask: UInt64 = 0
            if s.utf8.allSatisfy({ $0 < 0x80 }) {
                for var b in s.utf8 {
                    if b >= 0x41 && b <= 0x5A { b += 0x20 }
                    if Fuzzy.isASCIISpace(b) { continue }
                    ids.append(UInt32(b))
                    mask |= Fuzzy.maskBit(UInt32(b))
                }
            } else {
                for ch in s.lowercased() where !ch.isWhitespace {
                    let id = Fuzzy.id(ch)
                    ids.append(id)
                    mask |= Fuzzy.maskBit(id)
                }
            }
            self.ids = ids
            self.mask = mask
        }

        /// True when `other` is this query with characters appended (so its matches ⊆ ours).
        public func isPrefix(of other: Query) -> Bool {
            other.ids.count >= ids.count && other.ids.starts(with: ids)
        }
    }

    /// Pre-encoded candidate texts. Build once per hint session; score per keystroke.
    public struct Corpus: Sendable {
        @usableFromInline var units: [UInt32] = []
        @usableFromInline var starts: [Int32] = [0]
        @usableFromInline var masks: [UInt64] = []
        /// Number of non-whitespace Characters (for exact-match detection).
        @usableFromInline var normCounts: [Int32] = []

        public var count: Int { masks.count }

        public init<S: Sequence>(_ texts: S) where S.Element == String {
            self.init(Array(texts))
        }

        public init(_ texts: [String]) {
            let n = texts.count
            var total = 0
            for t in texts { total += t.utf8.count }  // ≥ Character count, so a safe bound
            var starts = [Int32](repeating: 0, count: n + 1)
            var masks = [UInt64](repeating: 0, count: n)
            var norms = [Int32](repeating: 0, count: n)
            units = [UInt32](unsafeUninitializedCapacity: max(total, 1)) { buf, initialized in
                var pos = 0
                for i in 0..<n {
                    let r = Corpus.encode(texts[i], into: buf.baseAddress! + pos)
                    pos += r.count
                    starts[i + 1] = Int32(pos)
                    masks[i] = r.mask
                    norms[i] = r.norm
                }
                initialized = pos
            }
            self.starts = starts
            self.masks = masks
            self.normCounts = norms
        }

        public mutating func append(_ text: String) {
            let cap = text.utf8.count
            let tmp = [UInt32](unsafeUninitializedCapacity: max(cap, 1)) { buf, initialized in
                let r = Corpus.encode(text, into: buf.baseAddress!)
                masks.append(r.mask)
                normCounts.append(r.norm)
                initialized = r.count
            }
            units.append(contentsOf: tmp)
            starts.append(Int32(units.count))
        }

        /// Writes one unit per Character of `text` (at most `text.utf8.count`) to `out`.
        static func encode(_ text: String, into out: UnsafeMutablePointer<UInt32>) -> (count: Int, mask: UInt64, norm: Int32) {
            var mask: UInt64 = 0
            var norm: Int32 = 0
            var text = text
            let asciiCount: Int? = text.withUTF8 { src in
                var any: UInt8 = 0
                for b in src { any |= b }
                guard any < 0x80 else { return nil }
                var i = 0
                var prevAlnum = false
                for var b in src {
                    if b &- 0x41 < 26 { b |= 0x20 }
                    let alnum = Fuzzy.isASCIIAlnum(b)
                    if prevAlnum && !alnum { out[i - 1] |= Fuzzy.wordEndBit }
                    var u = UInt32(b)
                    if i == 0 || (alnum && !prevAlnum) { u |= Fuzzy.wordStartBit }
                    if Fuzzy.isASCIISpace(b) { u |= Fuzzy.spaceBit } else { norm += 1 }
                    out[i] = u
                    mask |= Fuzzy.maskBit(UInt32(b))
                    prevAlnum = alnum
                    i += 1
                }
                if prevAlnum { out[i - 1] |= Fuzzy.wordEndBit }
                return i
            }
            if let c = asciiCount { return (c, mask, norm) }
            var prevAlnum = false
            var i = 0
            for ch in text.lowercased() {
                let alnum = ch.isLetter || ch.isNumber
                let id = Fuzzy.id(ch)
                if prevAlnum && !alnum { out[i - 1] |= Fuzzy.wordEndBit }
                var u = id
                if i == 0 || (alnum && !prevAlnum) { u |= Fuzzy.wordStartBit }
                if ch.isWhitespace { u |= Fuzzy.spaceBit } else { norm += 1 }
                out[i] = u
                mask |= Fuzzy.maskBit(id)
                prevAlnum = alnum
                i += 1
                if i == text.utf8.count { break }  // lowercasing can expand; never overrun the bound
            }
            if prevAlnum && i > 0 { out[i - 1] |= Fuzzy.wordEndBit }
            return (i, mask, norm)
        }

        /// Cheap pre-filter: false means `q` certainly doesn't match candidate `i`.
        @inline(__always) public func mayMatch(_ q: Query, _ i: Int) -> Bool {
            q.mask & ~masks[i] == 0
        }

        /// Score of `q` against candidate `i`, or nil when it is not a subsequence.
        public func score(_ q: Query, _ i: Int) -> Int? {
            let m = q.ids.count
            if m == 0 { return 0 }
            guard q.mask & ~masks[i] == 0 else { return nil }
            let lo = Int(starts[i]), hi = Int(starts[i + 1])
            let n = hi - lo
            if n < m { return nil }
            return units.withUnsafeBufferPointer { ub in
                q.ids.withUnsafeBufferPointer { qb in
                    Fuzzy.bestScore(ub.baseAddress! + lo, n, qb.baseAddress!, m, exact: Int(normCounts[i]) == m)
                }
            }
        }
    }

    /// Greedy leftmost alignment tried from the first occurrence of the first query character
    /// and from up to `maxStarts` word starts where it occurs; best score wins.
    @usableFromInline static func bestScore(
        _ c: UnsafePointer<UInt32>, _ n: Int, _ q: UnsafePointer<UInt32>, _ m: Int, exact: Bool
    ) -> Int? {
        let q0 = q[0]
        var best: Int?
        var starts = 0
        var s = 0
        let maxStarts = 6
        while s <= n - m {
            let u = c[s]
            if u & idMask == q0 && (starts == 0 || u & wordStartBit != 0) {
                guard let sc = greedy(c, n, q, m, from: s) else { break }  // later starts can't match either
                if best == nil || sc > best! { best = sc }
                starts += 1
                if starts > maxStarts { break }
            }
            s += 1
        }
        guard var score = best else { return nil }
        // Exact (space-insensitive) match beats everything.
        if exact { score += 50 }
        // Shorter candidates rank higher for the same match quality.
        score -= min(n / 8, 10)
        return score
    }

    @inline(__always) static func greedy(
        _ c: UnsafePointer<UInt32>, _ n: Int, _ q: UnsafePointer<UInt32>, _ m: Int, from s: Int
    ) -> Int? {
        var score = 0
        var qi = 0
        var prev = -2
        var compact = true  // matched chars are adjacent, ignoring whitespace
        var ci = s
        while ci < n && qi < m {
            let u = c[ci]
            if u & idMask == q[qi] {
                var sc = 1
                if ci == prev + 1 {
                    sc += 5  // contiguous
                } else if qi > 0 && compact {
                    var k = prev + 1
                    while k < ci && c[k] & spaceBit != 0 { k += 1 }
                    if k != ci { compact = false }
                }
                if u & wordStartBit != 0 { sc += 8 }  // word start
                score += sc
                prev = ci
                qi += 1
            } else if n - ci <= m - qi {
                return nil
            }
            ci += 1
        }
        guard qi == m else { return nil }
        if s == 0 { score += 10 }  // prefix
        // Whole word(s) typed exactly: "save" in "Save As", "order" in "Submit Order".
        if compact && c[s] & wordStartBit != 0 && c[prev] & wordEndBit != 0 {
            score += s == 0 ? 30 : 20
        }
        return score
    }
}
