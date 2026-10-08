import Testing

@testable import PounceCore

private let sampleItems: [HintItem] = [
    HintItem(text: "insert", key: "k0", category: .button),
    HintItem(text: "New Song", key: "k1", category: .button),
    HintItem(text: "Search field", key: "k2", category: .input),
    HintItem(text: "Help link", key: "k3", category: .link),
    HintItem(text: "Settings", key: "k4", category: .other),
]

private func session(
    _ items: [HintItem] = sampleItems, labelsOnly: Bool = false, autoClick: Bool = true,
    previous: [String: String] = [:]
) -> HintSession {
    HintSession(items: items, alphabet: "asdf", labelsOnly: labelsOnly, autoClick: autoClick, previousLabels: previous)
}

extension HintSession {
    fileprivate mutating func type(_ s: String) -> [HintEffect] {
        var last: [HintEffect] = []
        for c in s { last = handle(.char(c)) }
        return last
    }
}

@Suite struct HintSessionTests {
    @Test func initialState() {
        let s = session()
        #expect(s.visible == [0, 1, 2, 3, 4])
        #expect(s.focused == nil)
        #expect(s.labels.count == 5)
        #expect(Set(s.labels.values).count == 5)
        #expect(s.query.isEmpty && s.typed.isEmpty)
        #expect(s.filter == .all)
    }

    @Test func queryFiltersAndFocusesBest() {
        var s = session()
        #expect(s.type("ns") == [.update])
        #expect(s.query == "ns")
        #expect(s.visible.first == 1)  // New Song over insert
        #expect(s.visible.contains(0))
        #expect(!s.visible.contains(3))  // "Help link" has no n…s
        #expect(s.focused == 1)
        // Labels follow the visible set.
        #expect(Set(s.labels.keys) == Set(s.visible))
    }

    @Test func noMatchesEmptiesVisible() {
        var s = session()
        _ = s.type("zzz")
        #expect(s.visible.isEmpty)
        #expect(s.focused == nil)
        #expect(s.handle(.returnKey([])) == [.warn])
        #expect(s.handle(.tab(backward: false)) == [.warn])
    }

    @Test func starAndSemicolonIgnored() {
        var s = session()
        #expect(s.handle(.char("*")) == [])
        #expect(s.handle(.char(";")) == [])
        #expect(s.query.isEmpty)
    }

    @Test func uppercaseTypesLabelAutoClick() throws {
        var s = session()
        let label = try #require(s.label(for: 2))
        var effects: [HintEffect] = []
        for c in label.uppercased() { effects = s.handle(.char(c)) }
        #expect(effects == [.activate(item: 2, .click)])
        #expect(s.typed.isEmpty)
        #expect(s.query.isEmpty)
    }

    @Test func multiCharLabelPartialThenComplete() throws {
        let items = (0..<10).map { HintItem(text: "item \($0)", key: "k\($0)") }
        var s = session(items)
        let (idx, label) = try #require(s.labels.first { $0.value.count == 2 })
        let chars = Array(label.uppercased())
        #expect(s.handle(.char(chars[0])) == [.update])
        #expect(s.typed == String(label.prefix(1)))
        #expect(s.handle(.char(chars[1])) == [.activate(item: idx, .click)])
    }

    @Test func noAutoClickFocusesOnly() throws {
        var s = session(autoClick: false)
        let label = try #require(s.label(for: 3))
        #expect(s.type(label.uppercased()) == [.update])
        #expect(s.focused == 3)
        #expect(s.typed.isEmpty)
        #expect(s.handle(.returnKey([])) == [.activate(item: 3, .click)])
    }

    @Test func labelsOnlyMode() throws {
        var s = session(labelsOnly: true, autoClick: false)
        let label = try #require(s.label(for: 1))
        #expect(s.type(label) == [.update])  // lowercase types labels, no query
        #expect(s.query.isEmpty)
        #expect(s.focused == 1)
        #expect(s.handle(.space([])) == [.activate(item: 1, .click)])
        #expect(s.handle(.space(.shift)) == [.activate(item: 1, .rightClick)])

        var auto = session(labelsOnly: true)
        let l0 = try #require(auto.label(for: 0))
        #expect(auto.type(l0) == [.activate(item: 0, .click)])
    }

    @Test func spaceIgnoredInSearchMode() {
        var s = session()
        _ = s.type("ns")
        #expect(s.handle(.space([])) == [])
    }

    @Test func wrongLabelWarnsAndResets() throws {
        let items = (0..<10).map { HintItem(text: "item \($0)", key: "k\($0)") }
        var s = session(items)
        let two = try #require(s.labels.values.first { $0.count == 2 })
        _ = s.handle(.char(Character(two.prefix(1).uppercased())))
        #expect(!s.typed.isEmpty)
        #expect(s.handle(.char("Z")) == [.warn, .update])
        #expect(s.typed.isEmpty)
        var t = session()
        #expect(t.handle(.char("Q")) == [.warn, .update])
    }

    @Test func cycling() {
        var s = session()
        #expect(s.handle(.tab(backward: false)) == [.update])
        #expect(s.focused == 0)
        _ = s.handle(.tab(backward: false))
        #expect(s.focused == 1)
        _ = s.handle(.tab(backward: true))
        #expect(s.focused == 0)
        _ = s.handle(.tab(backward: true))
        #expect(s.focused == 4)  // wraps
        _ = s.handle(.control("n"))
        #expect(s.focused == 0)
        _ = s.handle(.control("p"))
        #expect(s.focused == 4)
        _ = s.handle(.arrow(.down, []))
        #expect(s.focused == 0)
        _ = s.handle(.arrow(.up, []))
        #expect(s.focused == 4)
        _ = s.handle(.control("j"))
        #expect(s.focused == 0)
        _ = s.handle(.control("k"))
        #expect(s.focused == 4)
        #expect(s.handle(.arrow(.left, [])) == [])
        #expect(s.handle(.arrow(.down, .shift)) == [])

        var b = session()
        _ = b.handle(.tab(backward: true))
        #expect(b.focused == 4)  // backward from nothing → last
    }

    @Test func cyclingWithinQueryResults() {
        var s = session()
        _ = s.type("ns")
        let v = s.visible
        #expect(s.focused == v[0])
        _ = s.handle(.tab(backward: false))
        #expect(s.focused == v[1 % v.count])
    }

    @Test(arguments: [
        (Modifiers(), HintAction.click),
        (Modifiers.shift, HintAction.rightClick),
        (Modifiers.command, HintAction.commandClick),
        (Modifiers.option, HintAction.optionClick),
        (Modifiers.control, HintAction.doubleClick),
    ])
    func returnModifiers(mods: Modifiers, action: HintAction) {
        var s = session()
        _ = s.type("ns")
        #expect(s.handle(.returnKey(mods)) == [.activate(item: 1, action)])
    }

    @Test func returnWithoutTargetWarns() {
        var s = session()
        #expect(s.handle(.returnKey([])) == [.warn])
    }

    @Test func singleVisibleIsImplicitTarget() {
        var s = session()
        _ = s.type("help")
        #expect(s.visible == [3])
        #expect(s.handle(.returnKey([])) == [.activate(item: 3, .click)])
    }

    @Test func singleItemGetsRealLabel() throws {
        var s = session([HintItem(text: "only", key: "o")])
        let l = try #require(s.label(for: 0))
        #expect(!l.isEmpty)
        #expect(s.type(l.uppercased()) == [.activate(item: 0, .click)])
    }

    @Test func escapeClearsTypedThenExits() throws {
        let items = (0..<10).map { HintItem(text: "item \($0)", key: "k\($0)") }
        var s = session(items)
        let two = try #require(s.labels.values.first { $0.count == 2 })
        _ = s.handle(.char(Character(two.prefix(1).uppercased())))
        #expect(s.handle(.escape) == [.update])
        #expect(s.typed.isEmpty)
        #expect(s.handle(.escape) == [.exit])
    }

    @Test func escapeCancelsDrag() {
        var s = session()
        _ = s.handle(.tab(backward: false))
        _ = s.handle(.control("d"))
        #expect(s.dragSource == 0)
        #expect(s.handle(.escape) == [.update])
        #expect(s.dragSource == nil)
        #expect(s.handle(.escape) == [.exit])
    }

    @Test func backspace() throws {
        var s = session()
        #expect(s.handle(.backspace) == [])
        _ = s.type("ns")
        #expect(s.handle(.backspace) == [.update])
        #expect(s.query == "n")
        _ = s.handle(.backspace)
        #expect(s.query.isEmpty)
        #expect(s.visible == [0, 1, 2, 3, 4])
        #expect(s.focused == nil)

        let items = (0..<10).map { HintItem(text: "item \($0)", key: "k\($0)") }
        var t = session(items)
        _ = t.type("it")
        let two = try #require(t.labels.values.first { $0.count == 2 })
        _ = t.handle(.char(Character(two.prefix(1).uppercased())))
        #expect(t.handle(.backspace) == [.update])
        #expect(t.typed.isEmpty)
        #expect(t.query == "it")  // typed cleared first, query untouched
    }

    @Test func controlUClears() {
        var s = session()
        _ = s.type("ns")
        #expect(s.handle(.control("u")) == [.update])
        #expect(s.query.isEmpty)
        #expect(s.visible.count == 5)
    }

    @Test func filters() {
        var s = session()
        #expect(s.handle(.control("i")) == [.update])
        #expect(s.filter == .inputs)
        #expect(s.visible == [2])
        _ = s.handle(.control("i"))
        #expect(s.filter == .all)
        #expect(s.visible.count == 5)
        _ = s.handle(.control("l"))
        #expect(s.visible == [3])
        _ = s.handle(.control("b"))
        #expect(s.filter == .buttons)
        #expect(s.visible == [0, 1])
        _ = s.handle(.control("a"))
        #expect(s.filter == .all)
        _ = s.handle(.control("a"))
        #expect(s.filter == .all)
        // Filter combines with query.
        _ = s.type("s")
        _ = s.handle(.control("b"))
        #expect(Set(s.visible) == [0, 1])
    }

    @Test func dragFlow() {
        var s = session()
        _ = s.handle(.tab(backward: false))  // focus 0
        #expect(s.handle(.control("d")) == [.update])
        #expect(s.dragSource == 0)
        _ = s.handle(.tab(backward: false))  // focus 1
        #expect(s.handle(.returnKey([])) == [.activate(item: 1, .drag(from: 0))])
        #expect(s.dragSource == nil)
        // Afterwards Return is a plain click again.
        #expect(s.handle(.returnKey([])) == [.activate(item: 1, .click)])
    }

    @Test func dragToggleAndNoTarget() {
        var s = session()
        #expect(s.handle(.control("d")) == [.warn])
        _ = s.handle(.tab(backward: false))
        _ = s.handle(.control("d"))
        _ = s.handle(.control("d"))
        #expect(s.dragSource == nil)
    }

    @Test func dragViaLabel() throws {
        var s = session()
        _ = s.handle(.tab(backward: false))
        _ = s.handle(.control("d"))
        let l = try #require(s.label(for: 3))
        #expect(s.type(l.uppercased()) == [.activate(item: 3, .drag(from: 0))])
    }

    @Test func windowOps() {
        var s = session()
        #expect(s.handle(.arrow(.left, .option)) == [.warn])
        _ = s.handle(.tab(backward: false))
        #expect(s.handle(.arrow(.left, .option)) == [.activate(item: 0, .window(.leftHalf))])
        #expect(s.handle(.arrow(.right, .option)) == [.activate(item: 0, .window(.rightHalf))])
        #expect(s.handle(.arrow(.up, .option)) == [.activate(item: 0, .window(.maximize))])
        #expect(s.handle(.arrow(.down, .option)) == [.activate(item: 0, .window(.nextScreen))])
        #expect(s.handle(.arrow(.down, [.option, .shift])) == [.activate(item: 0, .window(.nextScreen))])
    }

    @Test func otherControlActions() {
        var s = session()
        _ = s.handle(.tab(backward: false))
        #expect(s.handle(.control("y")) == [.activate(item: 0, .yank)])
        #expect(s.handle(.control("h")) == [.activate(item: 0, .hover)])
        #expect(s.handle(.control("f")) == [.activate(item: 0, .focus)])
        #expect(s.handle(.control("r")) == [.repeatLast])
        #expect(s.handle(.control("z")) == [])
    }

    @Test func extraClickTypes() {
        var s = session()
        _ = s.handle(.tab(backward: false))
        #expect(s.handle(.control("m")) == [.activate(item: 0, .middleClick)])
        #expect(s.handle(.control("o")) == [.activate(item: 0, .back)])
        #expect(s.handle(.control("t")) == [.activate(item: 0, .forward)])
    }

    @Test func inputsFilterFocusesFirstInput() {
        let items = [
            HintItem(text: "Go", key: "a", category: .button, frame: Rect(x: 0, y: 0, width: 10, height: 10)),
            HintItem(text: "Lower field", key: "b", category: .input, frame: Rect(x: 0, y: 300, width: 10, height: 10)),
            HintItem(text: "Upper field", key: "c", category: .input, frame: Rect(x: 0, y: 100, width: 10, height: 10)),
        ]
        var s = session(items)
        _ = s.handle(.control("i"))
        #expect(s.focused == 2)  // top-most input
        #expect(s.handle(.returnKey([])) == [.activate(item: 2, .click)])
        _ = s.handle(.control("i"))
        #expect(s.filter == .all && s.focused == nil)
    }

    @Test func clickAndType() {
        var s = session()
        _ = s.type("search")
        #expect(s.focused == 2)
        #expect(s.handle(.char("=")) == [.update])
        #expect(s.fill == "")
        _ = s.type("hi")
        _ = s.handle(.space([]))
        _ = s.type("A=b?")
        #expect(s.fill == "hi A=b?")
        #expect(s.query == "search")
        _ = s.handle(.backspace)
        #expect(s.handle(.returnKey([])) == [.activate(item: 2, .fill("hi A=b"))])
        // Esc leaves fill, keeps the query.
        _ = s.handle(.escape)
        #expect(s.fill == nil && s.query == "search")
        // Backspace past the start of the text leaves fill too.
        _ = s.handle(.char("="))
        #expect(s.handle(.backspace) == [.update])
        #expect(s.fill == nil)
        // "=" on a non-input is just part of the query.
        var t = session()
        _ = t.type("new")
        _ = t.handle(.char("="))
        #expect(t.fill == nil && t.query == "new=")
    }

    @Test func tutor() {
        var s = session()
        #expect(s.handle(.char("?")) == [.toggleTutor])
        #expect(s.query.isEmpty)
        var l = session(labelsOnly: true)
        #expect(l.handle(.char("?")) == [.toggleTutor])
    }

    @Test func assignedLabelsAndStability() {
        let s = session()
        let assigned = s.assignedLabels
        #expect(assigned.count == 5)
        for (i, item) in sampleItems.enumerated() { #expect(assigned[item.key] == s.label(for: i)) }

        // Reordered items keep their labels with previousLabels.
        let reordered = Array(sampleItems.reversed())
        let t = session(reordered, previous: assigned)
        for (i, item) in reordered.enumerated() { #expect(t.label(for: i) == assigned[item.key]) }
    }

    @Test func usageGetsShortLabel() {
        var items = (0..<12).map { HintItem(text: "item \($0)", key: "k\($0)") }
        items[11].usage = 99
        let s = session(items)
        #expect(s.label(for: 11)?.count == 1)
        #expect(s.label(for: 11) == Labels.generate(count: 12, alphabet: "asdf").first)
    }
}
