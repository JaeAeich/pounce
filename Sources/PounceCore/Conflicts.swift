import Foundation

/// Well-known third-party / app shortcuts a global chord would shadow. Advisory only (for UI warnings):
/// default shortcuts are not changed because of these.
public enum Conflicts {
    /// (chord, who commonly uses it). Only widely known defaults.
    static let known: [(String, String)] = [
        ("cmd+space", "Spotlight"),
        ("cmd+opt+space", "Finder search window"),
        ("ctrl+space", "Input source switching (macOS)"),
        ("ctrl+opt+space", "Input source switching (macOS)"),
        ("cmd+shift+space", "VS Code / Cursor parameter hints"),
        ("cmd+shift+space", "1Password Quick Access"),
        ("cmd+shift+space", "Input source switching (some setups)"),
        ("cmd+shift+j", "Chrome Downloads"),
        ("cmd+shift+j", "Firefox Browser Console"),
        ("cmd+opt+j", "Chrome JavaScript console"),
        ("cmd+opt+k", "Firefox Web Console"),
        ("cmd+opt+i", "Browser developer tools"),
        ("opt+space", "ChatGPT desktop launcher"),
        ("opt+space", "Raycast"),
        ("cmd+ctrl+space", "Emoji & Symbols (macOS)"),
        ("cmd+shift+3", "Screenshot (macOS)"),
        ("cmd+shift+4", "Screenshot (macOS)"),
        ("cmd+shift+5", "Screenshot (macOS)"),
        ("cmd+shift+/", "Help menu search (macOS)"),
        ("cmd+ctrl+q", "Lock Screen (macOS)"),
        ("cmd+opt+d", "Show / hide Dock (macOS)"),
        ("cmd+opt+esc", "Force Quit (macOS)"),
        ("ctrl+opt+return", "Rectangle / Magnet: maximize"),
        ("ctrl+opt+left", "Rectangle / Magnet: left half"),
        ("ctrl+opt+right", "Rectangle / Magnet: right half"),
        ("ctrl+opt+up", "Rectangle / Magnet: top half"),
        ("ctrl+opt+down", "Rectangle / Magnet: bottom half"),
        ("ctrl+opt+c", "Rectangle: center"),
        ("ctrl+opt+d", "Rectangle: first third"),
        ("ctrl+opt+e", "Rectangle: first two thirds"),
        ("ctrl+opt+f", "Rectangle: center third"),
        ("ctrl+opt+g", "Rectangle: last third"),
        ("ctrl+opt+t", "Rectangle: last two thirds"),
        ("ctrl+opt+u", "Rectangle / Magnet: top left"),
        ("ctrl+opt+i", "Rectangle / Magnet: top right"),
        ("ctrl+opt+j", "Rectangle / Magnet: bottom left"),
        ("ctrl+opt+k", "Rectangle / Magnet: bottom right"),
        ("ctrl+opt+delete", "Rectangle: restore"),
    ]

    private static let table: [KeyChord: [String]] = {
        var t: [KeyChord: [String]] = [:]
        for (raw, who) in known {
            guard let c = KeyChord.parse(raw) else { continue }
            if t[c, default: []].contains(who) == false { t[c, default: []].append(who) }
        }
        return t
    }()

    /// Apps / features that commonly use `chord`. Empty if none known.
    public static func `for`(_ chord: KeyChord) -> [String] { table[chord] ?? [] }

    /// Same for any shortcut; modifier taps never conflict with this table.
    public static func `for`(_ s: Shortcut) -> [String] {
        if case .chord(let c) = s { return Self.for(c) }
        return []
    }
}

/// macOS system shortcuts from System Settings › Keyboard › Shortcuts
/// (`com.apple.symbolichotkeys` → `AppleSymbolicHotKeys`).
public enum SystemHotkeys {
    public struct Entry: Sendable, Equatable {
        public var id: Int
        public var name: String
        public var chord: KeyChord
    }

    /// Defaults for well-known ids: applied when the plist has no explicit `value` for that id
    /// (entries are only written once the user has touched them). (name, chord).
    static let defaults: [Int: (String, String)] = [
        27: ("Move focus to next window", "cmd+`"),
        28: ("Save screenshot", "cmd+shift+3"),
        29: ("Copy screenshot", "ctrl+cmd+shift+3"),
        30: ("Save screenshot of selected area", "cmd+shift+4"),
        31: ("Copy screenshot of selected area", "ctrl+cmd+shift+4"),
        32: ("Mission Control", "ctrl+up"),
        33: ("Application windows", "ctrl+down"),
        52: ("Turn Dock hiding on/off", "cmd+opt+d"),
        60: ("Select the previous input source", "ctrl+space"),
        61: ("Select next source in Input menu", "ctrl+opt+space"),
        64: ("Show Spotlight search", "cmd+space"),
        65: ("Show Finder search window", "cmd+opt+space"),
        79: ("Move left a space", "ctrl+left"),
        81: ("Move right a space", "ctrl+right"),
        98: ("Show Help menu", "cmd+shift+/"),
        184: ("Screenshot and recording options", "cmd+shift+5"),
    ]

    static let names: [Int: String] = [
        7: "Move focus to the menu bar", 8: "Move focus to the Dock", 9: "Move focus to active or next window",
        10: "Move focus to window toolbar", 11: "Move focus to floating window", 12: "Turn keyboard access on/off",
        13: "Change the way Tab moves focus", 57: "Move focus to status menus", 59: "Turn VoiceOver on/off",
        36: "Show Desktop", 70: "Look up in Dictionary", 162: "Accessibility Controls", 163: "Notification Center",
        175: "Turn Do Not Disturb on/off", 222: "Turn Stage Manager on/off",
    ]

    /// Parses an `AppleSymbolicHotKeys` dictionary into enabled chords. Pure (testable).
    /// Value parameters are [ascii, virtual keycode, modifier flags]; keycode 65535 = unassigned.
    public static func parse(_ dict: [String: Any]) -> [Entry] {
        var out: [Entry] = []
        var seen: Set<Int> = []
        for (k, raw) in dict {
            guard let id = Int(k), let e = raw as? [String: Any] else { continue }
            seen.insert(id)
            guard (e["enabled"] as? NSNumber)?.boolValue ?? (e["enabled"] as? Bool) ?? false else { continue }
            let name = defaults[id]?.0 ?? names[id] ?? "macOS shortcut #\(id)"
            if let v = e["value"] as? [String: Any], let p = v["parameters"] as? [Any], p.count >= 3 {
                guard let code = (p[1] as? NSNumber)?.intValue, let flags = (p[2] as? NSNumber)?.intValue,
                    code != 65535, (0..<0x100).contains(code)
                else { continue }
                out.append(Entry(id: id, name: name, chord: KeyChord(keyCode: UInt16(code), modifiers: modifiers(flags))))
            } else if let d = defaults[id], let c = KeyChord.parse(d.1) {
                out.append(Entry(id: id, name: name, chord: c))
            }
        }
        // Ids the user never touched keep their (enabled) defaults.
        for (id, d) in defaults where !seen.contains(id) {
            if let c = KeyChord.parse(d.1) { out.append(Entry(id: id, name: d.0, chord: c)) }
        }
        return out.sorted { $0.id < $1.id }
    }

    /// NSEvent-style modifier flags (as stored by macOS) → Modifiers.
    static func modifiers(_ f: Int) -> Modifiers {
        var m: Modifiers = []
        if f & (1 << 17) != 0 { m.insert(.shift) }
        if f & (1 << 18) != 0 { m.insert(.control) }
        if f & (1 << 19) != 0 { m.insert(.option) }
        if f & (1 << 20) != 0 { m.insert(.command) }
        return m
    }

    /// Enabled system shortcuts for the current user, read fresh each call.
    public static func current() -> [Entry] {
        let dict =
            UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
            ?? CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
            ?? [:]
        return parse(dict)
    }

    /// Names of enabled system shortcuts that use `chord`.
    public static func conflicts(_ chord: KeyChord, in entries: [Entry]? = nil) -> [String] {
        (entries ?? current()).filter { $0.chord == chord }.map(\.name)
    }

    public static func conflicts(_ s: Shortcut, in entries: [Entry]? = nil) -> [String] {
        if case .chord(let c) = s { return conflicts(c, in: entries) }
        return []
    }
}
