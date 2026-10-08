import Foundation
import Testing

@testable import PounceCore

private func focusedText(_ items: [HintItem], _ query: String) -> String? {
    var s = HintSession(items: items, alphabet: "asdfghjkl")
    for c in query { _ = s.handle(.char(c)) }
    return s.focused.map { items[$0].text }
}

@Suite struct FuzzyRankingTests {
    @Test func wholeWordBeatsPartialWord() throws {
        let word = try #require(Fuzzy.score("order", "Submit Order"))
        let inside = try #require(Fuzzy.score("order", "Reorder list"))
        let prefixOnly = try #require(Fuzzy.score("order", "Orders"))
        #expect(word > inside)
        #expect(word > prefixOnly)
    }

    @Test func laterWordStartAlignmentIsFound() throws {
        // Greedy-from-first-'s' would scatter across "Settings"; the "Save" word start is better.
        let s = try #require(Fuzzy.score("save", "Settings Save"))
        let scattered = try #require(Fuzzy.score("save", "Settings slave"))
        #expect(s > scattered)
    }

    @Test func leadingWordsExact() throws {
        let lead = try #require(Fuzzy.score("submitorder", "Submit Order now"))
        let scattered = try #require(Fuzzy.score("submitorder", "Submit Borders"))
        #expect(lead > scattered)
    }

    @Test func nonASCII() throws {
        #expect(Fuzzy.score("café", "Le Café") != nil)
        #expect(Fuzzy.score("ÉCOLE", "école primaire") != nil)
        #expect(Fuzzy.score("über", "Uber") == nil)
        let exact = try #require(Fuzzy.score("café", "Café"))
        let partial = try #require(Fuzzy.score("café", "Café au lait"))
        #expect(exact > partial)
    }

    @Test func corpusMatchesStringAPI() {
        let items = PerfFixture.items(400, seed: 7)
        let corpus = Fuzzy.Corpus(items.map(\.text))
        for q in ["s", "sa", "save", "or d", "zz", "pl1", "Submit"] {
            let fq = Fuzzy.Query(q)
            for (i, it) in items.enumerated() {
                #expect(corpus.score(fq, i) == Fuzzy.score(q, it.text), "\(q) / \(it.text)")
                if !corpus.mayMatch(fq, i) { #expect(Fuzzy.score(q, it.text) == nil) }
            }
        }
    }
}

@Suite struct HintRankingTests {
    @Test func exactButtonBeatsStaticText() {
        let items = [
            HintItem(text: "Save your settings", key: "t", category: .other),
            HintItem(text: "Save", key: "b", category: .button),
        ]
        #expect(focusedText(items, "save") == "Save")
        // Same text: actionable category wins.
        let same = [HintItem(text: "Save", key: "t", category: .other), HintItem(text: "Save", key: "b", category: .button)]
        var s = HintSession(items: same, alphabet: "asdf")
        for c in "save" { _ = s.handle(.char(c)) }
        #expect(s.focused == 1)
    }

    @Test func exactWordFocuses() {
        let items = [
            HintItem(text: "Reorder list", key: "a", category: .button),
            HintItem(text: "Orders", key: "b", category: .button),
            HintItem(text: "Submit Order", key: "c", category: .button),
        ]
        #expect(focusedText(items, "order") == "Submit Order")
    }

    @Test func usageAndRecencyBreakTies() {
        var items = (0..<3).map { HintItem(text: "Open", key: "k\($0)", category: .button) }
        items[2].usage = 5
        var s = HintSession(items: items, alphabet: "asdf")
        for c in "open" { _ = s.handle(.char(c)) }
        #expect(s.focused == 2)

        var r = (0..<3).map { HintItem(text: "Open", key: "k\($0)", category: .button) }
        r[1].recency = 1
        var t = HintSession(items: r, alphabet: "asdf")
        for c in "op" { _ = t.handle(.char(c)) }
        #expect(t.focused == 1)
    }

    @Test func usageDoesNotOverrideExactMatch() {
        var items = [HintItem(text: "Save As", key: "a", category: .button), HintItem(text: "Save", key: "b", category: .button)]
        items[0].usage = 1000
        items[0].recency = 1
        #expect(focusedText(items, "save") == "Save")
    }

    @Test func tiesOrderedByScreenPosition() {
        let items = [
            HintItem(text: "Edit", key: "a", frame: Rect(x: 10, y: 300, width: 10, height: 10)),
            HintItem(text: "Edit", key: "b", frame: Rect(x: 200, y: 20, width: 10, height: 10)),
            HintItem(text: "Edit", key: "c", frame: Rect(x: 50, y: 21, width: 10, height: 10)),
            HintItem(text: "Edit", key: "d"),
        ]
        var s = HintSession(items: items, alphabet: "asdf")
        for c in "edit" { _ = s.handle(.char(c)) }
        #expect(s.visible == [2, 1, 0, 3])  // same row (y 20/21) left-to-right, then lower, then frameless
        // Empty query keeps item order.
        _ = s.handle(.control("u"))
        #expect(s.visible == [0, 1, 2, 3])
    }

    @Test func customRanking() {
        var r = HintRanking()
        r.button = 0
        r.other = 20
        let items = [HintItem(text: "Save", key: "b", category: .button), HintItem(text: "Save", key: "t", category: .other)]
        var s = HintSession(items: items, alphabet: "asdf", ranking: r)
        for c in "save" { _ = s.handle(.char(c)) }
        #expect(s.focused == 1)
    }
}

/// Incremental filtering must equal a from-scratch reference for every keystroke.
@Suite struct IncrementalFilterTests {
    private func reference(_ items: [HintItem], _ query: String, _ filter: RoleFilter) -> [Int] {
        let cand = items.indices.filter { filter.accepts(items[$0].category) }
        if Fuzzy.normalize(query).isEmpty { return cand }
        let scored = cand.compactMap { i in
            Fuzzy.score(query, items[i].text).map { (i, $0 + HintRanking.default.boost(items[i])) }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.map(\.0)
    }

    @Test func typingBackspaceAndFiltersMatchReference() {
        let items = PerfFixture.items(500, seed: 3)
        var s = HintSession(items: items, alphabet: "asdfghjkl")
        var rng = SplitMix(state: 99)
        let keys: [KeyInput] =
            Array("saveordpl 1").map { .char($0) } + [
                .backspace, .backspace, .backspace, .control("b"), .control("i"), .control("a"), .control("u"),
            ]
        for step in 0..<400 {
            let k = keys.randomElement(using: &rng)!
            _ = s.handle(k)
            let ref = reference(items, s.query, s.filter)
            #expect(s.visible == ref, "step \(step) query “\(s.query)” filter \(s.filter)")
            #expect(Set(s.labels.keys) == Set(s.visible))
            #expect(Set(s.labels.values).count == s.visible.count)
            if s.visible != ref { return }
        }
    }

    @Test func backspaceRestoresLabels() {
        let items = PerfFixture.items(300, seed: 5)
        var s = HintSession(items: items, alphabet: "asdfghjkl")
        _ = s.handle(.char("s"))
        let after1 = s.labels
        _ = s.handle(.char("a"))
        _ = s.handle(.backspace)
        #expect(s.labels == after1)
    }
}

@Suite struct LabelTableTests {
    @Test(arguments: ["asdf", "ab", "asdfghjkl"])
    func matchAgreesWithBruteForce(alphabet: String) {
        let t = Labels.Table(alphabet: alphabet, capacity: 300)
        let chars = Labels.uniqueChars(alphabet)
        var probes = chars.map { String($0) }
        for a in chars {
            for b in chars {
                probes.append("\(a)\(b)")
                for c in chars.prefix(3) { probes.append("\(a)\(b)\(c)") }
            }
        }
        probes.append("z")
        for n in [1, 2, 3, 5, 9, 10, 17, 40, 81, 82, 300] {
            let ls = Labels.generate(count: n, alphabet: alphabet)
            for p in probes {
                let want: Labels.Table.Match = ls.contains(p) ? .exact : ls.contains { $0.hasPrefix(p) } ? .prefix : .none
                #expect(t.match(p, count: n) == want, "n=\(n) p=\(p)")
            }
        }
    }

    @Test func positionsRoundTrip() {
        let t = Labels.Table(alphabet: "asdf", capacity: 500)
        let all = Labels.generate(count: 500, alphabet: "asdf")
        let ps = all.compactMap(t.position(of:))
        #expect(ps.count == all.count)
        #expect(Set(ps).count == ps.count)
        #expect(t.position(of: "") == nil && t.position(of: "x") == nil)
    }
}

@Suite struct UsageRecencyTests {
    @Test func recencyDecays() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var s = UsageStore()
        #expect(s.recency("a", now: t0) == 0)
        s.recordUse("a", now: t0)
        #expect(s.recency("a", now: t0) == 1)
        #expect(abs(s.recency("a", now: t0.addingTimeInterval(3600), halfLife: 3600) - 0.5) < 1e-9)
        s.remember(labels: ["b": "s"], now: t0)
        #expect(s.recency("b", now: t0) == 0)  // labelled but never used
    }
}
