import Testing

@testable import PounceCore

@Suite struct KeyComboTests {
    @Test func parseChord() throws {
        let s = try #require(Shortcut.parse("cmd+shift+space"))
        #expect(s == .chord(KeyChord(keyCode: KeyCodes.space, modifiers: [.command, .shift])))
        #expect(s.description == "shift+cmd+space")
        #expect(s.display == "⇧⌘Space")
    }

    @Test func parseHyper() throws {
        let s = try #require(Shortcut.parse("hyper+f"))
        #expect(s == .chord(KeyChord(keyCode: 3, modifiers: .hyper)))
        #expect(s.description == "hyper+f")
        #expect(s.display == "✦F")
        // All four modifiers spelled out also become hyper.
        #expect(Shortcut.parse("ctrl+opt+shift+cmd+f") == s)
    }

    @Test func parseCtrlOpt() throws {
        let s = try #require(Shortcut.parse("ctrl+opt+g"))
        #expect(s == .chord(KeyChord(keyCode: 5, modifiers: [.control, .option])))
        #expect(s.description == "ctrl+opt+g")
        #expect(s.display == "⌃⌥G")
    }

    @Test func parseTaps() {
        #expect(Shortcut.parse("tap:rcmd") == .tap(.rcmd))
        #expect(Shortcut.parse("tap:rcmd")?.description == "tap:rcmd")
        #expect(Shortcut.parse("tap:rcmd")?.display == "Tap right ⌘")
        #expect(Shortcut.parse("doubletap:shift") == .doubleTap(.lshift))
        #expect(Shortcut.parse("doubletap:shift")?.display == "Double-tap ⇧")
        #expect(Shortcut.parse("TAP:RALT") == .tap(.ropt))
        #expect(Shortcut.parse("tap:fn") == .tap(.fn))
        #expect(Shortcut.parse("tap:bogus") == nil)
        #expect(Shortcut.parse("doubletap:") == nil)
    }

    @Test func noneAndEmpty() {
        #expect(Shortcut.parse("none") == nil)
        #expect(Shortcut.parse("off") == nil)
        #expect(Shortcut.parse("") == nil)
        #expect(Shortcut.parse("   ") == nil)
    }

    @Test(arguments: ["cmd+", "+", "foo+a", "cmd+shift", "cmd+notakey", "cmd++shift", "a+b"])
    func invalid(_ s: String) {
        #expect(Shortcut.parse(s) == nil)
    }

    @Test func whitespaceAndCaseTolerant() {
        #expect(Shortcut.parse("  CMD+Shift+Space ") == Shortcut.parse("cmd+shift+space"))
        #expect(Shortcut.parse("command+option+control+a") == Shortcut.parse("ctrl+opt+cmd+a"))
        #expect(Shortcut.parse("⌘+⇧+a") == Shortcut.parse("cmd+shift+a"))
    }

    @Test func plusKey() {
        let s = Shortcut.parse("cmd++")
        #expect(s != nil)
        #expect(Shortcut.parse("cmd+plus") == s)
    }

    @Test(arguments: [
        "cmd+shift+space", "hyper+f", "ctrl+opt+g", "tap:rcmd", "doubletap:shift", "cmd+return", "opt+f12",
        "ctrl+left", "shift+tab", "cmd+,", "ctrl+opt+.", "tap:lopt", "doubletap:rctrl", "cmd+escape", "f18",
    ])
    func roundtrip(_ s: String) throws {
        let parsed = try #require(Shortcut.parse(s))
        #expect(Shortcut.parse(parsed.description) == parsed)
        // description is canonical: re-describing is idempotent.
        #expect(Shortcut.parse(parsed.description)?.description == parsed.description)
    }

    @Test func allTableKeysRoundtrip() {
        for (name, code) in KeyCodes.table {
            #expect(KeyCodes.code(for: name) == code)
            #expect(KeyCodes.name(for: code) == name)
            #expect(KeyChord.parse("cmd+" + name) == KeyChord(keyCode: code, modifiers: .command))
        }
    }

    @Test func aliases() {
        #expect(KeyCodes.code(for: "enter") == KeyCodes.returnKey)
        #expect(KeyCodes.code(for: "ESC") == KeyCodes.escape)
        #expect(KeyCodes.code(for: "backspace") == KeyCodes.delete)
        #expect(KeyCodes.name(for: 999) == "key999")
    }

    @Test func modifierSymbols() {
        #expect(Modifiers([.command, .shift, .option, .control]).symbols == "✦")
        #expect(Modifiers([.command, .control]).symbols == "⌃⌘")
        #expect(Modifiers([.shift, .option]).symbols == "⌥⇧")
        #expect(Modifiers([]).symbols == "")
    }

    @Test func displayNames() {
        #expect(KeyChord(keyCode: KeyCodes.returnKey, modifiers: .command).display == "⌘↩")
        #expect(KeyChord(keyCode: KeyCodes.left, modifiers: .option).display == "⌥←")
        #expect(KeyChord(keyCode: KeyCodes.escape, modifiers: []).display == "⎋")
        #expect(KeyChord(keyCode: KeyCodes.tab, modifiers: .shift).display == "⇧⇥")
        #expect(KeyChord(keyCode: 122, modifiers: []).display == "F1")
    }

    @Test func modifierKeyCodes() {
        for k in ModifierKey.allCases { #expect(ModifierKey(keyCode: k.keyCode) == k) }
        #expect(ModifierKey(keyCode: 0) == nil)
    }
}
