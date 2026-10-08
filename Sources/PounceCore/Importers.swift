import Foundation

/// Reads another tool's settings and maps what it can onto Pounce config keys.
/// Pure parsing: callers fetch the raw text (`defaults export …`, a JSON/YAML file) themselves.
/// Key names of closed-source apps aren't documented, so the plist/YAML importers use tolerant
/// heuristics on key names (shortcut/hotkey, alphabet/characters, ignore/exclude, speed, theme…).
public enum ImportSource: String, Sendable, CaseIterable {
    case homerow, shortcat, vimium, mouseless

    /// `defaults` domain for apps that keep settings in user defaults.
    public var defaultsDomain: String? {
        switch self {
        case .homerow: "com.superultra.Homerow"
        case .shortcat: "com.sproutcube.Shortcat"
        default: nil
        }
    }
}

public struct ImportResult: Sendable {
    public struct Change: Sendable, Equatable {
        public var key: String
        public var from: String
        public var to: String
        public var source: String
    }
    /// The current config with the imported values applied.
    public var config: Config
    public var changes: [Change]
    /// Settings found but not mapped (or rejected by validation), human readable.
    public var unmapped: [String]
}

public enum Importers {
    /// One setting to apply: Pounce key path, value, and the source key it came from.
    public struct Assignment: Sendable, Equatable {
        public var path: [String]
        public var value: TOMLValue
        public var source: String
    }

    // MARK: Entry points

    public static func run(_ source: ImportSource, text: String, onto current: Config) throws -> ImportResult {
        let (assignments, unmapped): ([Assignment], [String])
        switch source {
        case .homerow, .shortcat:
            (assignments, unmapped) = heuristics(try plistPairs(text), preset: source == .homerow ? .homerow : .shortcat)
        case .vimium:
            (assignments, unmapped) = try vimium(text)
        case .mouseless:
            (assignments, unmapped) = heuristics(yamlPairs(text), preset: .mouseless)
        }
        return apply(assignments, unmapped: unmapped, onto: current)
    }

    /// Applies assignments through the normal parser, so validation is identical to config.toml.
    public static func apply(_ assignments: [Assignment], unmapped: [String] = [], onto current: Config) -> ImportResult {
        var notes = unmapped
        // A preset assignment is applied first, keeping the user's current overrides.
        var base = current
        if let p = assignments.first(where: { $0.path == Config.presetPath }), let name = p.value.string,
            let preset = Preset(rawValue: name)
        {
            base = current.withPreset(preset)
        }
        guard var doc = try? TOMLDocument(base.toTOML()) else { return ImportResult(config: current, changes: [], unmapped: notes) }
        var applied: [Assignment] = []
        for a in assignments where a.path != Config.presetPath {
            var trial = doc
            trial.set(a.path, a.value)
            guard let (_, w) = try? Config.parse(trial.text) else {
                notes.append("\(a.source): couldn't apply")
                continue
            }
            let key = a.path.joined(separator: ".")
            if let bad = w.first(where: { $0.hasPrefix(key) }) {
                notes.append("\(a.source) → \(bad)")
                continue
            }
            doc = trial
            applied.append(a)
        }
        let config = (try? Config.parse(doc.text).0) ?? current
        let old = Dictionary(current.flattened().map { ($0.path, $0.value) }, uniquingKeysWith: { a, _ in a })
        var changes: [ImportResult.Change] = []
        for e in config.flattened() where !TOML.equivalent(old[e.path], e.value) {
            let src =
                applied.last(where: { $0.path == e.path })?.source
                ?? assignments.first(where: { $0.path == Config.presetPath })?.source ?? "preset"
            changes.append(
                .init(
                    key: e.path.joined(separator: "."), from: old[e.path].map(TOML.serialize) ?? "–", to: TOML.serialize(e.value),
                    source: src))
        }
        return ImportResult(config: config, changes: changes, unmapped: notes)
    }

    // MARK: Vimium / Vimium C (options JSON export)

    public static func vimium(_ text: String) throws -> ([Assignment], [String]) {
        guard let data = text.data(using: .utf8), let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.badFormat("expected a JSON object (Vimium › Options › Backup and Restore)")
        }
        // Vimium C nests settings in some exports.
        let opts = (obj["settings"] as? [String: Any]) ?? obj
        var out: [Assignment] = [Assignment(path: Config.presetPath, value: .string("vimium"), source: "vimium")]
        var notes: [String] = []
        if let s = opts["linkHintCharacters"] as? String {
            out.append(.init(path: ["hints", "alphabet"], value: .string(s.lowercased()), source: "linkHintCharacters"))
        }
        if let f = bool(opts["filterLinkHints"]) {
            out.append(.init(path: ["hints", "labels_only"], value: .bool(!f), source: "filterLinkHints"))
            if f, let n = opts["linkHintNumbers"] as? String {
                out.append(.init(path: ["hints", "alphabet"], value: .string(n), source: "linkHintNumbers"))
            }
        }
        if let ex = opts["exclusionRules"] as? [Any], !ex.isEmpty {
            notes.append("exclusionRules: \(ex.count) URL rule(s) — Pounce excludes apps, not sites")
        }
        let mapped: Set = ["linkHintCharacters", "filterLinkHints", "linkHintNumbers", "exclusionRules", "settings"]
        for k in opts.keys.sorted() where !mapped.contains(k) { notes.append("\(k): not applicable") }
        return (out, notes)
    }

    // MARK: Plist (defaults export)

    public enum ImportError: Error, CustomStringConvertible {
        case badFormat(String)
        public var description: String { if case .badFormat(let m) = self { m } else { "" } }
    }

    /// Flattens a property list (XML or binary-as-text not supported) to dotted key → value pairs.
    public static func plistPairs(_ text: String) throws -> [(String, Any)] {
        guard let data = text.data(using: .utf8),
            let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dict = obj as? [String: Any]
        else { throw ImportError.badFormat("expected a property list (defaults export <domain> -)") }
        var out: [(String, Any)] = []
        func walk(_ prefix: String, _ v: Any) {
            if let d = v as? [String: Any], !looksLikeShortcut(d) {
                for k in d.keys.sorted() { walk(prefix.isEmpty ? k : prefix + "." + k, d[k]!) }
            } else {
                out.append((prefix, v))
            }
        }
        walk("", dict)
        if out.isEmpty { throw ImportError.badFormat("no settings found (is the app installed and set up?)") }
        return out
    }

    // MARK: Minimal YAML (key: value, nesting by indentation, "- item" lists)

    public static func yamlPairs(_ text: String) -> [(String, Any)] {
        var out: [(String, Any)] = []
        var stack: [(indent: Int, key: String)] = []
        var listKey: String?
        var list: [String] = []
        func flushList() {
            if let k = listKey { out.append((k, list)) }
            listKey = nil
            list = []
        }
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            let stripped = stripYAMLComment(line)
            let trimmed = stripped.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "---" { continue }
            let indent = stripped.prefix { $0 == " " }.count
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                let item = unquote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                if listKey == nil, !stack.isEmpty { listKey = path(stack.map(\.key)) }
                list.append(item)
                continue
            }
            flushList()
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = unquote(String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces))
            let rest = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            if rest.isEmpty {
                stack.append((indent, key))  // a nested map or a "- item" list follows
                continue
            }
            let full = path(stack.map(\.key) + [key])
            out.append((full, yamlScalar(rest)))
        }
        flushList()
        return out
    }

    private static func path(_ parts: [String]) -> String { parts.joined(separator: ".") }

    private static func stripYAMLComment(_ s: String) -> String {
        var inQuote: Character?
        for (i, c) in s.enumerated() {
            if let q = inQuote {
                if c == q { inQuote = nil }
            } else if c == "\"" || c == "'" {
                inQuote = c
            } else if c == "#" {
                if i == 0 || s[s.index(s.startIndex, offsetBy: i - 1)] == " " { return String(s.prefix(i)) }
            }
        }
        return s
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, let f = s.first, f == "\"" || f == "'", s.last == f { return String(s.dropFirst().dropLast()) }
        return s
    }

    private static func yamlScalar(_ s: String) -> Any {
        if s.hasPrefix("[") && s.hasSuffix("]") {
            return s.dropFirst().dropLast().split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter {
                !$0.isEmpty
            }
        }
        let u = unquote(s)
        if u != s { return u }
        switch s.lowercased() {
        case "true", "yes", "on": return true
        case "false", "no", "off": return false
        default: break
        }
        if let i = Int(s) { return i }
        if let d = Double(s) { return d }
        return s
    }

    // MARK: Heuristic mapping

    /// Maps key/value pairs from an app whose key names we don't know for sure.
    public static func heuristics(_ pairs: [(String, Any)], preset: Preset) -> ([Assignment], [String]) {
        var out: [Assignment] = []
        var notes: [String] = []
        if preset != .homerow { out.append(.init(path: Config.presetPath, value: .string(preset.rawValue), source: "preset")) }
        var system = 0
        var taken = Set<[String]>()
        func add(_ path: [String], _ v: TOMLValue, _ src: String) {
            if taken.contains(path) {
                notes.append("\(src): \(path.joined(separator: ".")) already set from another key")
                return
            }
            taken.insert(path)
            out.append(.init(path: path, value: v, source: src))
        }
        // Prefer "search" shortcuts over "non-search" ones for the single click-mode shortcut.
        let ordered = pairs.sorted { a, b in
            let an = a.0.lowercased().contains("non"), bn = b.0.lowercased().contains("non")
            return an != bn ? !an : a.0 < b.0
        }
        for (key, value) in ordered {
            let k = key.lowercased()
            let leaf = k.split(separator: ".").last.map(String.init) ?? k
            if isSystemKey(key) {
                system += 1
                continue
            }
            if k.contains("shortcut") || k.contains("hotkey") || k.contains("keybind") || k.contains("activation") {
                guard let s = shortcutString(value) else {
                    notes.append("\(key): couldn't read shortcut \(describe(value))")
                    continue
                }
                let mode =
                    k.contains("scroll")
                    ? "scroll"
                    : k.contains("grid") || k.contains("mouse")
                        ? "grid"
                        : k.contains("window")
                            ? "windows"
                            : k.contains("menu")
                                ? "menu"
                                : k.contains("ocr") || k.contains("text")
                                    ? "text"
                                    : "hint"
                add(["shortcuts", mode], .string(s), key)
            } else if leaf.contains("alphabet") || leaf.contains("characters") || leaf.contains("chars") || leaf.contains("hintkeys")
                || leaf.contains("label-keys")
            {
                guard let s = value as? String else {
                    notes.append("\(key): expected text")
                    continue
                }
                add(["hints", "alphabet"], .string(s.lowercased()), key)
            } else if k.contains("ignore") || k.contains("exclu") || k.contains("blacklist") || k.contains("disabled-app")
                || k.contains("disabledapp")
            {
                let items =
                    (value as? [Any])?.compactMap { $0 as? String } ?? (value as? String).map {
                        $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    } ?? []
                let ids = items.compactMap(bundleID)
                if ids.count < items.count { notes.append("\(key): \(items.count - ids.count) entr(ies) not resolvable to a bundle id") }
                if !ids.isEmpty {
                    add(["general", "ignored_apps"], .array(ids.map(TOMLValue.string)), key)
                } else if items.isEmpty {
                    notes.append("\(key): \(describe(value))")
                }
            } else if k.contains("speed") {
                guard let d = number(value) else {
                    notes.append("\(key): \(describe(value))")
                    continue
                }
                if k.contains("dash") || k.contains("fast") {
                    add(["scroll", "dash_speed"], .double(d), key)
                } else if (50...20000).contains(d) {
                    add(["scroll", "speed"], .double(d), key)
                } else {
                    notes.append("\(key) = \(describe(value)): unknown units, set [scroll] speed (px/s) yourself")
                }
            } else if k.contains("theme") || k.contains("appearance") {
                let s = (value as? String ?? "").lowercased()
                let t =
                    s.contains("dark")
                    ? "dark"
                    : s.contains("light")
                        ? "light"
                        : s.contains("vim") || s.contains("yellow") ? "vimium" : s.contains("system") || s.contains("auto") ? "system" : nil
                if let t {
                    add(["hints", "theme"], .string(t), key)
                } else {
                    notes.append("\(key) = \(describe(value)): no matching theme")
                }
            } else if (k.contains("font") || k.contains("size")) && !k.contains("window"), let d = number(value), (8...32).contains(d) {
                add(["hints", "size"], .double(d), key)
            } else if k.contains("auto") && k.contains("click"), let b = bool(value) {
                add(["hints", "auto_click"], .bool(b), key)
            } else if k.contains("sound"), let b = bool(value) {
                add(["general", "sounds"], .bool(b), key)
            } else {
                notes.append("\(key) = \(describe(value))")
            }
        }
        if system > 0 { notes.append("(\(system) window/updater/system keys skipped)") }
        return (out, notes)
    }

    static func isSystemKey(_ k: String) -> Bool {
        ["NS", "SU", "Apple", "com.apple", "WebKit", "MSAppCenter", "Sentry", "_", "TelemetryDeck", "sparkle"].contains { k.hasPrefix($0) }
            || k.contains("WindowFrame") || k.contains("Window Frame") || k.lowercased().contains("lastcheck")
            || k.lowercased().contains("onboard")
            || k.lowercased().contains("license") || k.lowercased().contains("launchcount") || k.lowercased().contains("install")
    }

    // MARK: Value helpers

    static func bool(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String {
            return ["true", "yes", "1"].contains(s.lowercased()) ? true : ["false", "no", "0"].contains(s.lowercased()) ? false : nil
        }
        return nil
    }

    static func number(_ v: Any) -> Double? {
        if v is Bool { return nil }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func describe(_ v: Any) -> String {
        let s: String
        if let x = v as? String { s = "\"\(x)\"" } else if let d = v as? Data { s = "<\(d.count) bytes>" } else { s = "\(v)" }
        return s.count > 60 ? String(s.prefix(57)) + "…" : s
    }

    /// Bundle ids pass through; .app paths resolve via their Info.plist.
    static func bundleID(_ s: String) -> String? {
        if s.hasPrefix("/") || s.hasPrefix("~") || s.hasPrefix("file://") {
            let url = s.hasPrefix("file://") ? URL(string: s) : URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
            return url.flatMap { Bundle(url: $0)?.bundleIdentifier }
        }
        return s.contains(".") && !s.contains(" ") ? s : nil
    }

    static func looksLikeShortcut(_ d: [String: Any]) -> Bool {
        let ks = Set(d.keys.map { $0.lowercased() })
        return ks.contains("keycode") || ks.contains("carbonkeycode") || ks.contains("modifierflags") || ks.contains("carbonmodifiers")
    }

    /// Reads the common shortcut encodings into Pounce syntax ("cmd+shift+space"):
    /// sindresorhus/KeyboardShortcuts JSON (`{"carbonKeyCode":49,"carbonModifiers":768}`),
    /// MASShortcut dicts (`keyCode` + NSEvent `modifierFlags`), symbols ("⌘⇧Space") or plain text.
    public static func shortcutString(_ v: Any) -> String? {
        if let d = v as? [String: Any] { return shortcut(fromDict: d) }
        if let data = v as? Data {
            if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return shortcut(fromDict: o) }
            if let o = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                return shortcut(fromDict: o)
            }
            return nil
        }
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("{"), let data = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return shortcut(fromDict: o)
        }
        if let p = Shortcut.parse(s) { return p.description }
        // Symbol form: ⌃⌥⇧⌘ then key.
        var parts: [String] = []
        var rest = Substring(s)
        while let c = rest.first, "⌃⌥⇧⌘".contains(c) {
            parts.append(["⌃": "ctrl", "⌥": "opt", "⇧": "shift", "⌘": "cmd"][c]!)
            rest = rest.dropFirst()
        }
        let key = rest.trimmingCharacters(in: .whitespaces).lowercased()
        let named = ["␣": "space", "↩": "return", "⏎": "return", "⇥": "tab", "⎋": "escape", "⌫": "delete"][key] ?? key
        let cand = (parts + [named]).joined(separator: "+")
        return Shortcut.parse(cand)?.description
    }

    static func shortcut(fromDict d: [String: Any]) -> String? {
        func int(_ names: [String]) -> Int? {
            for (k, v) in d where names.contains(k.lowercased()) { if let n = v as? NSNumber { return n.intValue } }
            return nil
        }
        var mods: Modifiers = []
        let code: Int
        if let c = int(["carbonkeycode"]) {
            code = c
            let m = int(["carbonmodifiers"]) ?? 0
            if m & 256 != 0 { mods.insert(.command) }
            if m & 512 != 0 { mods.insert(.shift) }
            if m & 2048 != 0 { mods.insert(.option) }
            if m & 4096 != 0 { mods.insert(.control) }
        } else if let c = int(["keycode"]) {
            code = c
            let m = int(["modifierflags", "modifiers"]) ?? 0
            if m & (1 << 20) != 0 { mods.insert(.command) }
            if m & (1 << 17) != 0 { mods.insert(.shift) }
            if m & (1 << 19) != 0 { mods.insert(.option) }
            if m & (1 << 18) != 0 { mods.insert(.control) }
        } else {
            return nil
        }
        guard code >= 0, code < 256 else { return nil }
        let chord = KeyChord(keyCode: UInt16(code), modifiers: mods)
        return KeyChord.parse(chord.description) != nil ? chord.description : nil
    }
}
