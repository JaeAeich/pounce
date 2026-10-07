import Foundation

/// Remembers per-element labels and click counts across activations
/// so labels stay stable (muscle memory) and frequent targets get short labels.
public struct UsageStore: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var label: String?
        public var count: Int
        public var lastUsed: Date
    }

    public private(set) var entries: [String: Entry] = [:]
    public static let maxEntries = 5000

    public init() {}

    public func usage(_ key: String) -> Int { entries[key]?.count ?? 0 }

    public var labels: [String: String] { entries.compactMapValues(\.label) }

    public mutating func remember(labels: [String: String], now: Date = Date()) {
        for (k, l) in labels {
            entries[k, default: Entry(label: nil, count: 0, lastUsed: now)].label = l
        }
        prune()
    }

    public mutating func recordUse(_ key: String, now: Date = Date()) {
        withEntry(key, now: now) {
            $0.count += 1
            $0.lastUsed = now
        }
    }

    private mutating func withEntry(_ key: String, now: Date, _ body: (inout Entry) -> Void) {
        body(&entries[key, default: Entry(label: nil, count: 0, lastUsed: now)])
    }

    /// 0…1 recency score: 1 when used just now, halving every `halfLife` seconds; 0 if never used.
    public func recency(_ key: String, now: Date = Date(), halfLife: TimeInterval = 3 * 86_400) -> Double {
        guard let e = entries[key], e.count > 0 else { return 0 }
        let age = max(0, now.timeIntervalSince(e.lastUsed))
        return exp2(-age / halfLife)
    }

    private mutating func prune() {
        let excess = entries.count - Self.maxEntries
        guard excess > 0 else { return }
        // Sort plain (count, lastUsed, slot) tuples instead of (String, Entry) pairs,
        // then drop only the losers in place.
        var keys: [String] = []
        keys.reserveCapacity(entries.count)
        var rank: [(count: Int, t: Double, slot: Int)] = []
        rank.reserveCapacity(entries.count)
        for (k, e) in entries {
            rank.append((e.count, e.lastUsed.timeIntervalSinceReferenceDate, keys.count))
            keys.append(k)
        }
        rank.sort { $0.count != $1.count ? $0.count < $1.count : $0.t < $1.t }
        for r in rank.prefix(excess) { entries.removeValue(forKey: keys[r.slot]) }
    }
}
