import Testing

@testable import PounceCore

@Suite struct KeyTableTests {
    let ms: UInt64 = 1_000_000

    @Test func chordLookup() {
        let t = ShortcutTable<String>([
            (Shortcut.parse("cmd+shift+space")!, "hint"),
            (Shortcut.parse("hyper+f")!, "grid"),
            (Shortcut.parse("cmd+shift+space")!, "dup"),
            (Shortcut.parse("tap:rcmd")!, "tap"),
        ])
        #expect(t.chord(keyCode: KeyCodes.space, modifiers: [.command, .shift]) == "hint")
        #expect(t.chord(keyCode: KeyCodes.space, modifiers: [.command]) == nil)
        #expect(t.chord(keyCode: 3, modifiers: .hyper) == "grid")
        #expect(t.tap(.rcmd) == "tap")
        #expect(t.tap(.lcmd) == nil)
        #expect(t.hasModifierTriggers)
        #expect(!ShortcutTable<Int>().hasModifierTriggers)
    }

    @Test func singleTap() {
        var tr = ModifierTapTracker()
        #expect(tr.modifier(.rcmd, pressed: true, alone: true, at: 0, hasTap: { _ in true }) == nil)
        #expect(tr.modifier(.rcmd, pressed: false, alone: true, at: 100 * ms, hasTap: { _ in true }) == .tap(.rcmd))
    }

    @Test func slowOrDirtyTapIgnored() {
        var tr = ModifierTapTracker()
        _ = tr.modifier(.rcmd, pressed: true, alone: true, at: 0, hasTap: { _ in true })
        #expect(tr.modifier(.rcmd, pressed: false, alone: true, at: 400 * ms, hasTap: { _ in true }) == nil)
        _ = tr.modifier(.rcmd, pressed: true, alone: true, at: 1000 * ms, hasTap: { _ in true })
        tr.keyDown()  // ⌘C
        #expect(tr.modifier(.rcmd, pressed: false, alone: true, at: 1050 * ms, hasTap: { _ in true }) == nil)
        _ = tr.modifier(.rcmd, pressed: true, alone: false, at: 2000 * ms, hasTap: { _ in true })
        #expect(tr.modifier(.rcmd, pressed: false, alone: false, at: 2050 * ms, hasTap: { _ in true }) == nil)
    }

    @Test func doubleTap() {
        var tr = ModifierTapTracker()
        let no: (ModifierKey) -> Bool = { _ in false }
        _ = tr.modifier(.lshift, pressed: true, alone: true, at: 0, hasTap: no)
        #expect(tr.modifier(.lshift, pressed: false, alone: true, at: 50 * ms, hasTap: no) == nil)
        _ = tr.modifier(.lshift, pressed: true, alone: true, at: 150 * ms, hasTap: no)
        #expect(tr.modifier(.lshift, pressed: false, alone: true, at: 200 * ms, hasTap: no) == .doubleTap(.lshift))
        // A third tap starts over.
        _ = tr.modifier(.lshift, pressed: true, alone: true, at: 250 * ms, hasTap: no)
        #expect(tr.modifier(.lshift, pressed: false, alone: true, at: 300 * ms, hasTap: no) == nil)
    }

    @Test func doubleTapTooSlowOrDifferentKey() {
        var tr = ModifierTapTracker()
        let no: (ModifierKey) -> Bool = { _ in false }
        _ = tr.modifier(.lshift, pressed: true, alone: true, at: 0, hasTap: no)
        _ = tr.modifier(.lshift, pressed: false, alone: true, at: 50 * ms, hasTap: no)
        _ = tr.modifier(.lshift, pressed: true, alone: true, at: 500 * ms, hasTap: no)
        #expect(tr.modifier(.lshift, pressed: false, alone: true, at: 550 * ms, hasTap: no) == nil)
        _ = tr.modifier(.rshift, pressed: true, alone: true, at: 600 * ms, hasTap: no)
        #expect(tr.modifier(.rshift, pressed: false, alone: true, at: 650 * ms, hasTap: no) == nil)
    }
}
