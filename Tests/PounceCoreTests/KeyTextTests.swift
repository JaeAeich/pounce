import Testing

@testable import PounceCore

@Suite struct KeyTextTests {
    func r(_ c: Character, _ a: Character? = nil, shift: Bool = false, caps: Bool = false, _ p: KeyText.Purpose = .search) -> Character {
        KeyText.resolve(actual: c, ascii: a, shift: shift, capsLock: caps, purpose: p)
    }

    @Test func capsLockDoesNotUppercase() {
        #expect(r("A", caps: true) == "a")
        #expect(r("A", shift: true, caps: true) == "A")
        #expect(r("a") == "a")
        #expect(r("A", shift: true) == "A")
        #expect(r("1", caps: true) == "1")
        #expect(r("Ф", caps: true, .literal) == "ф")
    }

    @Test func capsLockSearchDoesNotJumpLabels() {
        // Caps Lock on, typing "a" must search, not act as Shift+label.
        var s = HintSession(items: [HintItem(text: "apple", key: "1"), HintItem(text: "banana", key: "2")], alphabet: "asdf")
        _ = s.handle(.char(r("A", caps: true)))
        #expect(s.query == "a")
        #expect(s.typed.isEmpty)
    }

    @Test func capsLockScrollIsNotDash() {
        var s = ScrollSession(areaCount: 1)
        #expect(s.keyDown(.char(r("J", caps: true, .labels))) == [.start(.down, dash: false)])
    }

    @Test func nonLatinLabels() {
        // Russian layout: physical "f" key types "а"; US ASCII layout gives "f".
        #expect(r("а", "f", .labels) == "f")
        #expect(r("А", "F", shift: true, .labels) == "F")
        #expect(r("А", "f", caps: true, .labels) == "f")
        #expect(r("α", "a", .labels) == "a")
        #expect(r("ש", "a", .labels) == "a")
        // No ASCII translation available: keep the real character.
        #expect(r("а", nil, .labels) == "а")
    }

    @Test func nonLatinSearchKeepsRealCharsButShiftJumps() {
        #expect(r("а", "f") == "а")
        #expect(r("А", "F", shift: true) == "F")
        #expect(r("А", "F", shift: true, .literal) == "А")
    }

    @Test func latinLayoutsUntouched() {
        // Dvorak: physical "s" key types "o" — layout-aware, no translation.
        #expect(r("o", "s", .labels) == "o")
        #expect(r("é", "2", .labels) == "é")  // non-letter ASCII fallback is ignored
    }

    @Test func russianLabelsDriveHintSession() {
        var s = HintSession(
            items: (0..<3).map { HintItem(text: "item \($0)", key: "\($0)") }, alphabet: "asdf", labelsOnly: true, autoClick: false)
        let label = s.labels[0]!
        let typedOnRussian: [Character: Character] = ["a": "ф", "s": "ы", "d": "в", "f": "а"]
        for ch in label { _ = s.handle(.char(r(typedOnRussian[ch]!, ch, .labels))) }
        #expect(s.focused == 0)
    }
}
