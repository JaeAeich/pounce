import Foundation
import Testing

@testable import PounceCore

@Suite struct UsageStoreTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func recordUse() {
        var s = UsageStore()
        #expect(s.usage("a") == 0)
        s.recordUse("a", now: t0)
        s.recordUse("a", now: t0.addingTimeInterval(5))
        s.recordUse("b", now: t0)
        #expect(s.usage("a") == 2)
        #expect(s.usage("b") == 1)
        #expect(s.entries["a"]?.lastUsed == t0.addingTimeInterval(5))
        #expect(s.labels.isEmpty)
    }

    @Test func rememberLabels() {
        var s = UsageStore()
        s.recordUse("a", now: t0)
        s.remember(labels: ["a": "s", "b": "df"], now: t0)
        #expect(s.labels == ["a": "s", "b": "df"])
        #expect(s.usage("a") == 1)  // count preserved
        #expect(s.usage("b") == 0)
        s.remember(labels: ["a": "j"], now: t0)
        #expect(s.labels["a"] == "j")
        #expect(s.labels["b"] == "df")
    }

    @Test func codableRoundtrip() throws {
        var s = UsageStore()
        s.recordUse("x", now: t0)
        s.remember(labels: ["x": "a", "y": "sd"], now: t0.addingTimeInterval(1))
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(UsageStore.self, from: data)
        #expect(back == s)
        #expect(back.labels == ["x": "a", "y": "sd"])
        #expect(back.usage("x") == 1)
    }

    @Test func pruning() {
        var s = UsageStore()
        s.recordUse("hot", now: t0)
        s.recordUse("hot", now: t0)
        var labels: [String: String] = [:]
        for i in 0..<(UsageStore.maxEntries + 10) { labels["k\(i)"] = "a" }
        s.remember(labels: labels, now: t0)
        #expect(s.entries.count == UsageStore.maxEntries)
        #expect(s.usage("hot") == 2)  // most used survives
        #expect(s.labels["hot"] == nil)
    }

    @Test func pruningPrefersRecent() {
        var s = UsageStore()
        let n = UsageStore.maxEntries
        var old: [String: String] = [:]
        for i in 0..<n { old["old\(i)"] = "a" }
        s.remember(labels: old, now: t0)
        s.remember(labels: ["new": "s"], now: t0.addingTimeInterval(100))
        #expect(s.entries.count == n)
        #expect(s.labels["new"] == "s")
    }
}
