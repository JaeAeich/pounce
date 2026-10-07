import Foundation

/// Keyboard modifiers, independent of AppKit/CoreGraphics flag layouts.
public struct Modifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let command = Modifiers(rawValue: 1 << 0)
    public static let shift = Modifiers(rawValue: 1 << 1)
    public static let option = Modifiers(rawValue: 1 << 2)
    public static let control = Modifiers(rawValue: 1 << 3)
    public static let hyper: Modifiers = [.command, .shift, .option, .control]

    /// Display order follows macOS menus: ⌃⌥⇧⌘.
    public var symbols: String {
        if self == .hyper { return "✦" }
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// A physical modifier key, for modifier-only triggers ("tap:rcmd").
public enum ModifierKey: String, Sendable, CaseIterable {
    case lcmd, rcmd, lshift, rshift, lopt, ropt, lctrl, rctrl, fn

    public var keyCode: UInt16 {
        switch self {
        case .lcmd: 55
        case .rcmd: 54
        case .lshift: 56
        case .rshift: 60
        case .lopt: 58
        case .ropt: 61
        case .lctrl: 59
        case .rctrl: 62
        case .fn: 63
        }
    }

    public init?(keyCode: UInt16) {
        guard let k = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = k
    }

    static let aliases: [String: ModifierKey] = [
        "cmd": .lcmd, "command": .lcmd, "lcommand": .lcmd, "rcommand": .rcmd,
        "shift": .lshift, "opt": .lopt, "option": .lopt, "alt": .lopt, "lalt": .lopt, "ralt": .ropt,
        "ropt": .ropt, "roption": .ropt, "loption": .lopt,
        "ctrl": .lctrl, "control": .lctrl, "rcontrol": .rctrl, "lcontrol": .lctrl,
    ]

    var symbol: String {
        switch self {
        case .lcmd: "⌘"
        case .rcmd: "right ⌘"
        case .lshift: "⇧"
        case .rshift: "right ⇧"
        case .lopt: "⌥"
        case .ropt: "right ⌥"
        case .lctrl: "⌃"
        case .rctrl: "right ⌃"
        case .fn: "fn"
        }
    }
}

/// A global trigger: a normal chord, or tapping / double-tapping a lone modifier.
public enum Shortcut: Sendable, Hashable, CustomStringConvertible {
    case chord(KeyChord)
    case tap(ModifierKey)
    case doubleTap(ModifierKey)

    /// Parses "cmd+shift+space", "hyper+f", "tap:rcmd", "doubletap:shift". "" / "none" → nil.
    public static func parse(_ raw: String) -> Shortcut? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty || s == "none" || s == "off" { return nil }
        if let rest = s.stripPrefix("doubletap:") { return ModifierKey.parse(rest).map { .doubleTap($0) } }
        if let rest = s.stripPrefix("tap:") { return ModifierKey.parse(rest).map { .tap($0) } }
        return KeyChord.parse(s).map { .chord($0) }
    }

    public var description: String {
        switch self {
        case .chord(let c): c.description
        case .tap(let m): "tap:\(m.rawValue)"
        case .doubleTap(let m): "doubletap:\(m.rawValue)"
        }
    }

    /// Human display, e.g. "⌘⇧Space", "Tap right ⌘", "Double-tap ⇧".
    public var display: String {
        switch self {
        case .chord(let c): c.display
        case .tap(let m): "Tap \(m.symbol)"
        case .doubleTap(let m): "Double-tap \(m.symbol)"
        }
    }
}

extension ModifierKey {
    static func parse(_ s: String) -> ModifierKey? { ModifierKey(rawValue: s) ?? aliases[s] }
}

public struct KeyChord: Sendable, Hashable, CustomStringConvertible {
    public var keyCode: UInt16
    public var modifiers: Modifiers
    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static func parse(_ s: String) -> KeyChord? {
        // Split on "+" but allow the key itself to be "+" (e.g. "cmd++").
        var parts = s.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if s.hasSuffix("++") {
            parts.removeLast(2)
            parts.append("+")
        }
        guard let keyName = parts.popLast(), !keyName.isEmpty, let code = KeyCodes.code(for: keyName) else { return nil }
        var mods: Modifiers = []
        for p in parts {
            switch p {
            case "cmd", "command", "⌘": mods.insert(.command)
            case "shift", "⇧": mods.insert(.shift)
            case "opt", "option", "alt", "⌥": mods.insert(.option)
            case "ctrl", "control", "⌃": mods.insert(.control)
            case "hyper", "✦": mods.formUnion(.hyper)
            default: return nil
            }
        }
        return KeyChord(keyCode: code, modifiers: mods)
    }

    public var description: String {
        var parts: [String] = []
        if modifiers == .hyper {
            parts.append("hyper")
        } else {
            if modifiers.contains(.control) { parts.append("ctrl") }
            if modifiers.contains(.option) { parts.append("opt") }
            if modifiers.contains(.shift) { parts.append("shift") }
            if modifiers.contains(.command) { parts.append("cmd") }
        }
        parts.append(KeyCodes.name(for: keyCode))
        return parts.joined(separator: "+")
    }

    public var display: String { modifiers.symbols + KeyCodes.displayName(for: keyCode) }
}

/// macOS virtual key codes (ANSI positions; kVK_* values).
public enum KeyCodes {
    public static let returnKey: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let delete: UInt16 = 51
    public static let escape: UInt16 = 53
    public static let keypadEnter: UInt16 = 76
    public static let f18: UInt16 = 79
    public static let left: UInt16 = 123
    public static let right: UInt16 = 124
    public static let down: UInt16 = 125
    public static let up: UInt16 = 126

    static let table: [(String, UInt16)] = [
        ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
        ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19),
        ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28),
        ("0", 29), ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("return", 36),
        ("l", 37), ("j", 38), ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44), ("n", 45),
        ("m", 46), (".", 47), ("tab", 48), ("space", 49), ("`", 50), ("delete", 51), ("escape", 53),
        ("f17", 64), ("f19", 80), ("f20", 90), ("f5", 96), ("f6", 97), ("f7", 98), ("f3", 99), ("f8", 100),
        ("f9", 101), ("f11", 103), ("f13", 105), ("f16", 106), ("f14", 107), ("f10", 109), ("f12", 111),
        ("f15", 113), ("home", 115), ("pageup", 116), ("forwarddelete", 117), ("f4", 118), ("end", 119),
        ("f2", 120), ("pagedown", 121), ("f1", 122), ("left", 123), ("right", 124), ("down", 125),
        ("up", 126), ("f18", 79),
    ]
    static let aliases: [String: UInt16] = [
        "enter": 36, "esc": 53, "backspace": 51, "spacebar": 49, "pgup": 116, "pgdn": 121,
        "plus": 24, "+": 24, "minus": 27, "comma": 43, "period": 47, "slash": 44, "semicolon": 41,
    ]

    public static func code(for name: String) -> UInt16? {
        let n = name.lowercased()
        return table.first(where: { $0.0 == n })?.1 ?? aliases[n]
    }

    public static func name(for code: UInt16) -> String {
        table.first(where: { $0.1 == code })?.0 ?? "key\(code)"
    }

    public static func displayName(for code: UInt16) -> String {
        switch code {
        case space: "Space"
        case returnKey: "↩"
        case tab: "⇥"
        case delete: "⌫"
        case escape: "⎋"
        case left: "←"
        case right: "→"
        case up: "↑"
        case down: "↓"
        default: name(for: code).uppercased()
        }
    }
}

extension String {
    func stripPrefix(_ p: String) -> String? { hasPrefix(p) ? String(dropFirst(p.count)) : nil }
}
