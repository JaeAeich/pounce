/// Prefix-free label generation and stable, usage-aware assignment.
public enum Labels {
    /// `count` prefix-free labels over `alphabet`, shortest first.
    /// Uses as many 1-char labels as possible, expanding only what's needed.
    public static func generate(count: Int, alphabet: String) -> [String] {
        guard count > 0 else { return [] }
        let table = Table(alphabet: alphabet, capacity: count)
        return table.labels(count: count)
    }

    public static func uniqueChars(_ alphabet: String) -> [Character] {
        var seen = Set<Character>()
        return alphabet.lowercased().filter { !$0.isWhitespace && seen.insert($0).inserted }.map { $0 }
    }

    public struct Candidate: Sendable, Hashable {
        public var key: String
        public var usage: Int
        public init(key: String, usage: Int = 0) {
            self.key = key
            self.usage = usage
        }
    }

    /// Assigns labels to candidates (returned in candidate order).
    /// 1. A candidate keeps its previous label if still in the label set (muscle memory).
    /// 2. Remaining candidates get remaining labels, most-used first → shortest labels.
    public static func assign(
        _ candidates: [Candidate], alphabet: String, previous: [String: String] = [:]
    ) -> [String] {
        let table = Table(alphabet: alphabet, capacity: candidates.count)
        return table.assign(
            count: candidates.count,
            previous: { previous[candidates[$0].key].flatMap(table.position(of:)) },
            usage: { candidates[$0].usage })
    }

    /// Precomputed label universe for one alphabet.
    ///
    /// Labels for `count` are a contiguous window of the breadth-first enumeration of the
    /// k-ary label tree (k = alphabet size): skip the first `e` labels (the ones expanded into
    /// children), take the next `count`. So every label maps to an integer BFS position and
    /// assignment is pure integer work — no per-keystroke string hashing or generation.
    public struct Table: Sendable {
        public let chars: [Character]
        private var bfs: [String] = []
        private var index: [Character: Int] = [:]
        /// ASCII byte → digit (or -1); used when the whole alphabet is ASCII.
        private var asciiIndex: [Int8]?

        public init(alphabet: String, capacity: Int = 0) {
            chars = Labels.uniqueChars(alphabet)
            for (i, c) in chars.enumerated() { index[c] = i }
            if chars.count < 127, chars.allSatisfy({ $0.isASCII && $0.utf8.count == 1 }) {
                var t = [Int8](repeating: -1, count: 128)
                for (i, c) in chars.enumerated() { t[Int(c.asciiValue!)] = Int8(i) }
                asciiIndex = t
            }
            reserve(capacity)
        }

        /// Ensures labels for up to `count` candidates are available.
        public mutating func reserve(_ count: Int) {
            let k = chars.count
            guard k >= 2, count > 0 else { return }
            let need = Self.skip(count, k) + count
            if bfs.isEmpty { bfs = chars.map { String($0) } }
            guard bfs.count < need else { return }
            bfs.reserveCapacity(need + k)
            var parent = (bfs.count - k) / k  // first label whose children aren't generated yet
            while bfs.count < need {
                let p = bfs[parent]
                for c in chars {
                    var s = p
                    s.append(c)
                    bfs.append(s)
                }
                parent += 1
            }
        }

        /// Number of BFS labels expanded (and thus skipped) to fit `count` leaves.
        @inline(__always) static func skip(_ count: Int, _ k: Int) -> Int {
            count <= k ? 0 : (count - k + k - 2) / (k - 1)
        }

        /// BFS position of a label, nil if it uses characters outside the alphabet.
        public func position(of label: String) -> Int? {
            let k = chars.count
            guard k >= 2, !label.isEmpty else { return nil }
            var levelStart = 0
            var levelSize = 1
            var value = 0
            if let t = asciiIndex {
                for b in label.utf8 {
                    guard b < 0x80, t[Int(b)] >= 0 else { return nil }
                    levelStart += levelSize
                    levelSize *= k
                    value = value * k + Int(t[Int(b)])
                    if levelStart > Int.max / (2 * k) { return nil }
                }
                return levelStart - 1 + value
            }
            for ch in label {
                guard let d = index[ch] else { return nil }
                levelStart += levelSize
                levelSize *= k
                value = value * k + d
                if levelStart > Int.max / (2 * k) { return nil }  // absurdly long
            }
            return levelStart - 1 + value
        }

        public enum Match: Sendable, Equatable { case none, prefix, exact }

        /// How `typed` relates to the `count`-label set: a whole label, a strict prefix of one, or neither.
        /// O(label length), no scanning.
        public func match(_ typed: String, count n: Int) -> Match {
            let k = chars.count
            guard n > 0 else { return .none }
            guard k >= 2 else {
                let ls = labels(count: n)
                return ls.contains(typed) ? .exact : ls.contains { $0.hasPrefix(typed) } ? .prefix : .none
            }
            guard let p = position(of: typed) else { return .none }
            let e = Self.skip(n, k), end = e + n
            if p >= e { return p < end ? .exact : .none }
            // Internal node: walk down its descendant range until it reaches the window.
            var lo = p, hi = p
            while hi < e {
                lo = k + lo * k
                hi = k + hi * k + k - 1
            }
            return max(lo, e) < end ? .prefix : .none
        }

        /// Prefix-free labels for `count` candidates, shortest first.
        public func labels(count: Int) -> [String] {
            guard count > 0 else { return [] }
            let k = chars.count
            if k < 2 {
                return k == 1 ? (1...count).map { String(repeating: chars[0], count: $0) } : []  // degenerate
            }
            var t = self
            t.reserve(count)
            let e = Self.skip(count, k)
            return Array(t.bfs[e..<(e + count)])
        }

        /// Assigns labels to `count` candidates (indices 0..<count, in rank order).
        /// `previous(i)` is the BFS position of candidate i's remembered label.
        public func assign(count n: Int, previous: (Int) -> Int?, usage: (Int) -> Int) -> [String] {
            let k = chars.count
            guard n > 0 else { return [] }
            guard k >= 2 else { return labels(count: n) }
            var t = self
            t.reserve(n)
            let e = Self.skip(n, k)
            var slot = [Int](repeating: -1, count: n)
            var taken = [Bool](repeating: false, count: n)
            var hasUsage = false
            for i in 0..<n {
                if let p = previous(i), p >= e, p < e + n, !taken[p - e] {
                    slot[i] = p - e
                    taken[p - e] = true
                } else if usage(i) > 0 {
                    hasUsage = true
                }
            }
            var free = 0
            @inline(__always) func give(_ i: Int) {
                while taken[free] { free += 1 }
                slot[i] = free
                free += 1
            }
            if hasUsage {
                // Only the (few) used candidates need sorting; the rest keep rank order.
                var used: [(u: Int, i: Int)] = []
                for i in 0..<n where slot[i] < 0 {
                    let u = usage(i)
                    if u > 0 { used.append((u, i)) }
                }
                used.sort { $0.u != $1.u ? $0.u > $1.u : $0.i < $1.i }
                for (_, i) in used { give(i) }
            }
            for i in 0..<n where slot[i] < 0 { give(i) }
            return t.bfs.withUnsafeBufferPointer { b in slot.map { b[e + $0] } }
        }
    }
}
