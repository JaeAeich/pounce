import AppKit
import PounceCore
import os

enum ModeKind: String, CaseIterable, Identifiable {
    case hint, scroll, grid, windows, menu, text, mouse
    /// Not a mode: replays the last click (`AppController.repeatLast()`).
    case repeatLast = "repeat"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .hint: "Click"
        case .scroll: "Scroll"
        case .grid: "Grid"
        case .windows: "Windows"
        case .menu: "Menu Search"
        case .text: "Text"
        case .mouse: "Mouse"
        case .repeatLast: "Repeat Last Click"
        }
    }

    var symbol: String {
        switch self {
        case .hint: "cursorarrow.click.2"
        case .scroll: "arrow.up.and.down"
        case .grid: "square.grid.3x3"
        case .windows: "macwindow.on.rectangle"
        case .menu: "filemenu.and.selection"
        case .text: "text.viewfinder"
        case .mouse: "computermouse"
        case .repeatLast: "arrow.counterclockwise"
        }
    }

    var blurb: String {
        switch self {
        case .hint: "Label every button and link, type to click."
        case .scroll: "Scroll with h j k l, pick areas with Tab."
        case .grid: "Narrow a 3×3 grid to click anywhere."
        case .windows: "Jump to any visible window."
        case .menu: "Fuzzy-search the app's menu bar."
        case .text: "Click any word on screen (uses OCR)."
        case .mouse: "Steer the pointer with h j k l, click with Space."
        case .repeatLast: "Click the last target again without opening a mode."
        }
    }

    func shortcut(in c: Config.Shortcuts) -> String {
        switch self {
        case .hint: c.hint
        case .scroll: c.scroll
        case .grid: c.grid
        case .windows: c.windows
        case .menu: c.menu
        case .text: c.text
        case .mouse: c.mouse
        case .repeatLast: c.repeat
        }
    }

    static func keyPath(_ m: ModeKind) -> WritableKeyPath<Config.Shortcuts, String> {
        switch m {
        case .hint: \.hint
        case .scroll: \.scroll
        case .grid: \.grid
        case .windows: \.windows
        case .menu: \.menu
        case .text: \.text
        case .mouse: \.mouse
        case .repeatLast: \.repeat
        }
    }
}

/// Matches global shortcuts, including lone-modifier taps and double-taps, and implements the Hyper key.
/// Thread-safe: the event tap evaluates it on its own thread (`route`), config updates arrive from main.
final class HotkeyMatcher: @unchecked Sendable {
    private struct State {
        var table = ShortcutTable<ModeKind>()
        var taps = ModifierTapTracker()
        var hyperEnabled = false
        var capsLockEscape = true
        var hyperDown = false
        var hyperUsed = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    // Hyper key (Caps Lock → F18 via hidutil, then F18 held = ⌃⌥⇧⌘).
    var hyperEnabled: Bool {
        get { state.withLockUnchecked { $0.hyperEnabled } }
        set { state.withLockUnchecked { $0.hyperEnabled = newValue } }
    }
    var capsLockEscape: Bool {
        get { state.withLockUnchecked { $0.capsLockEscape } }
        set { state.withLockUnchecked { $0.capsLockEscape = newValue } }
    }

    func update(_ shortcuts: Config.Shortcuts) {
        let t = ShortcutTable(ModeKind.allCases.compactMap { m in Shortcut.parse(m.shortcut(in: shortcuts)).map { ($0, m) } })
        state.withLockUnchecked { $0.table = t }
    }

    /// Hyper + shortcut matching in one pass, done once per event (on the tap thread).
    /// Mutates the event's flags when Hyper is held. Allocation-free.
    func route(_ e: KeyEvent) -> KeyEvent.Routed {
        var postEscape = false
        let r: KeyEvent.Routed = state.withLockUnchecked { s in
            let h = Self.hyper(&s, e, postEscape: &postEscape)
            if h.swallow { return KeyEvent.Routed(hyperSwallow: true, modifiers: h.modifiers, match: nil) }
            return KeyEvent.Routed(hyperSwallow: false, modifiers: h.modifiers, match: Self.match(&s, e, modifiers: h.modifiers))
        }
        if postEscape { EventTap.postKey(KeyCodes.escape) }
        return r
    }

    /// Applies Hyper to an event. Returns true if the event must be swallowed (the F18 itself).
    func applyHyper(_ e: KeyEvent) -> (swallow: Bool, modifiers: Modifiers) {
        if let r = e.routed { return (r.hyperSwallow, r.modifiers) }
        var postEscape = false
        let h = state.withLockUnchecked { Self.hyper(&$0, e, postEscape: &postEscape) }
        if postEscape { EventTap.postKey(KeyCodes.escape) }
        return h
    }

    /// Returns the mode to toggle for this event, if it is a bound shortcut.
    func match(_ e: KeyEvent, modifiers: Modifiers) -> ModeKind? {
        if let r = e.routed { return r.match }
        return state.withLockUnchecked { Self.match(&$0, e, modifiers: modifiers) }
    }

    private static func hyper(_ s: inout State, _ e: KeyEvent, postEscape: inout Bool) -> (swallow: Bool, modifiers: Modifiers) {
        guard s.hyperEnabled else { return (false, e.modifiers) }
        if e.keyCode == KeyCodes.f18 && e.kind != .flags {
            if e.kind == .down, !e.isRepeat {
                s.hyperDown = true
                s.hyperUsed = false
            } else if e.kind == .up {
                s.hyperDown = false
                if !s.hyperUsed && s.capsLockEscape { postEscape = true }
            }
            return (true, e.modifiers)
        }
        guard s.hyperDown, e.kind != .flags else { return (false, e.modifiers) }
        s.hyperUsed = true
        e.cgEvent.flags.insert([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        return (false, e.modifiers.union(.hyper))
    }

    private static func match(_ s: inout State, _ e: KeyEvent, modifiers: Modifiers) -> ModeKind? {
        switch e.kind {
        case .down:
            s.taps.keyDown()
            guard !e.isRepeat else { return nil }
            return s.table.chord(keyCode: e.keyCode, modifiers: modifiers)
        case .up:
            return nil
        case .flags:
            guard let key = ModifierKey(keyCode: e.keyCode) else { return nil }
            let pressed = isPressed(key, e.cgEvent.flags)
            // Only a lone modifier counts; anything else held makes it a chord.
            let alone = modifiers.subtracting(modifierFor(key)).isEmpty
            let table = s.table
            guard let hit = s.taps.modifier(key, pressed: pressed, alone: alone, at: EventTap.now(), hasTap: { table.tap($0) != nil })
            else { return nil }
            switch hit {
            case .tap(let k): return table.tap(k)
            case .doubleTap(let k): return table.doubleTap(k)
            case .chord: return nil
            }
        }
    }

    private static func modifierFor(_ k: ModifierKey) -> Modifiers {
        switch k {
        case .lcmd, .rcmd: .command
        case .lshift, .rshift: .shift
        case .lopt, .ropt: .option
        case .lctrl, .rctrl: .control
        case .fn: []
        }
    }

    private static func isPressed(_ k: ModifierKey, _ f: CGEventFlags) -> Bool {
        switch k {
        case .lcmd, .rcmd: f.contains(.maskCommand)
        case .lshift, .rshift: f.contains(.maskShift)
        case .lopt, .ropt: f.contains(.maskAlternate)
        case .lctrl, .rctrl: f.contains(.maskControl)
        case .fn: f.contains(.maskSecondaryFn)
        }
    }
}

/// Remaps Caps Lock → F18 with hidutil (per-session, no root, reverts on logout).
enum HyperKeyRemap {
    private static let caps: UInt64 = 0x7_0000_0039
    private static let f18: UInt64 = 0x7_0000_006D

    static func setEnabled(_ on: Bool) {
        var maps = current().filter { $0["HIDKeyboardModifierMappingSrc"] != caps }
        if on { maps.append(["HIDKeyboardModifierMappingSrc": caps, "HIDKeyboardModifierMappingDst": f18]) }
        let body = maps.map {
            "{\"HIDKeyboardModifierMappingSrc\":\($0["HIDKeyboardModifierMappingSrc"]!),\"HIDKeyboardModifierMappingDst\":\($0["HIDKeyboardModifierMappingDst"]!)}"
        }
        run(["property", "--set", "{\"UserKeyMapping\":[\(body.joined(separator: ","))]}"])
    }

    private static func current() -> [[String: UInt64]] {
        let out = run(["property", "--get", "UserKeyMapping"])
        // Old-style plist: ( { HIDKeyboardModifierMappingDst = 1; HIDKeyboardModifierMappingSrc = 2; } ).
        var result: [[String: UInt64]] = []
        var dict: [String: UInt64] = [:]
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("{") { dict = [:] }
            let kv = t.split(separator: "=").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ;")) }
            if kv.count == 2, let n = UInt64(kv[1]) { dict[kv[0]] = n }
            if t.hasPrefix("}"), dict["HIDKeyboardModifierMappingSrc"] != nil, dict["HIDKeyboardModifierMappingDst"] != nil {
                result.append(dict)
            }
        }
        return result
    }

    @discardableResult
    private static func run(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
