import Foundation
import Testing

@testable import PounceCore

extension Tag {
    @Tag static var perf: Self
}

/// Deterministic RNG so benchmark inputs are identical across runs.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum PerfFixture {
    static let words = [
        "save", "open", "close", "submit", "order", "cancel", "settings", "search", "help", "file", "edit", "view",
        "window", "new", "song", "insert", "delete", "copy", "paste", "format", "share", "export", "import", "print",
        "preferences", "account", "profile", "sign", "out", "reply", "forward", "archive", "inbox", "draft", "send",
        "attach", "bold", "italic", "underline", "zoom", "toolbar", "sidebar", "tab", "bookmark", "history", "reload",
        "back", "next", "previous", "play", "pause", "stop", "volume", "mute", "library", "playlist", "album", "artist",
    ]

    static func items(_ n: Int = 3000, seed: UInt64 = 42) -> [HintItem] {
        var rng = SplitMix(state: seed)
        let cats = HintCategory.allCases
        return (0..<n).map { i in
            let wc = Int.random(in: 1...5, using: &rng)
            var text = (0..<wc).map { _ in words.randomElement(using: &rng)!.capitalized }.joined(separator: " ")
            if Int.random(in: 0..<3, using: &rng) == 0 { text += " \(i)" }
            return HintItem(
                text: text, key: "k\(i)", usage: Int.random(in: 0..<10, using: &rng) == 0 ? Int.random(in: 1...20, using: &rng) : 0,
                category: cats.randomElement(using: &rng)!)
        }
    }
}

/// Runs `body` `runs` times and returns the median wall time in microseconds.
func medianMicros(runs: Int = 15, _ body: () -> Void) -> Double {
    var samples: [Double] = []
    body()  // warm-up
    for _ in 0..<runs {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000)
    }
    samples.sort()
    return samples[samples.count / 2]
}

private func report(_ name: String, _ us: Double) {
    print("PERF " + name.padding(toLength: 40, withPad: " ", startingAt: 0) + String(format: "%10.1f µs", us))
}

@Suite(.serialized, .tags(.perf)) struct PerfTests {
    let items = PerfFixture.items()
    let alphabet = "asdfghjkl"

    @Test func sessionInit() {
        let prev = Dictionary(
            uniqueKeysWithValues: items.prefix(1500).enumerated().map { ($1.key, Labels.generate(count: 1500, alphabet: alphabet)[$0]) })
        let us = medianMicros { _ = HintSession(items: items, alphabet: alphabet, previousLabels: prev) }
        report("HintSession.init 3000", us)
    }

    @Test func typingAndBackspace() {
        let base = HintSession(items: items, alphabet: alphabet)
        let query = "savord"
        var perKey: [Double] = []
        var perBack: [Double] = []
        for _ in 0..<9 {
            var s = base
            for c in query {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = s.handle(.char(c))
                perKey.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000)
            }
            for _ in query {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = s.handle(.backspace)
                perBack.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000)
            }
        }
        perKey.sort()
        perBack.sort()
        report("keystroke (6-char query, median)", perKey[perKey.count / 2])
        report("keystroke (6-char query, max)", perKey.last!)
        report("backspace (median)", perBack[perBack.count / 2])
        report("backspace (max)", perBack.last!)
        // Loose regression guard (debug builds, noisy CI): was ~10ms/keystroke before incremental matching.
        #expect(perKey[perKey.count / 2] < 5_000)
    }

    @Test func typeLabel() {
        let base = HintSession(items: items, alphabet: alphabet, autoClick: false)
        let label = base.labels.values.max { $0.count < $1.count }!.uppercased()
        var samples: [Double] = []
        for _ in 0..<15 {
            var s = base
            for c in label {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = s.handle(.char(c))
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000)
            }
        }
        samples.sort()
        report("label keystroke (median)", samples[samples.count / 2])
    }

    @Test func labelsAssign() {
        let cands = items.map { Labels.Candidate(key: $0.key, usage: $0.usage) }
        let gen = Labels.generate(count: 3000, alphabet: alphabet)
        let prev = Dictionary(uniqueKeysWithValues: cands.prefix(2000).enumerated().map { ($1.key, gen[($0 * 7) % 3000]) })
        report("Labels.generate 3000", medianMicros { _ = Labels.generate(count: 3000, alphabet: alphabet) })
        report("Labels.assign 3000 + previous", medianMicros { _ = Labels.assign(cands, alphabet: alphabet, previous: prev) })
    }

    @Test func fuzzyScore() {
        let texts = items.map(\.text)
        var hits = 0
        let us = medianMicros {
            hits = 0
            for t in texts where Fuzzy.score("savord", t) != nil { hits += 1 }
        }
        report("Fuzzy.score ×3000 (String API)", us)
        #expect(hits > 0)
    }

    @Test func usageStore() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var labels: [String: String] = [:]
        for i in 0..<(UsageStore.maxEntries + 500) { labels["k\(i)"] = "a" }
        report(
            "UsageStore.remember 5500 (prune)",
            medianMicros(runs: 7) {
                var s = UsageStore()
                s.remember(labels: labels, now: t0)
            })
        var s = UsageStore()
        s.remember(labels: Dictionary(uniqueKeysWithValues: (0..<3000).map { ("k\($0)", "a") }), now: t0)
        report(
            "UsageStore.recordUse ×1000",
            medianMicros {
                var c = s
                for i in 0..<1000 { c.recordUse("k\(i)", now: t0) }
            })
    }
}
