import Foundation

/// `[general] preset = "…"`: a baseline that mimics another tool. Keys set explicitly in
/// config.toml override the preset; the saver only writes values that differ from it.
///
/// - homerow: Pounce's own defaults (⌘⇧Space click, ⌘⇧J scroll, fuzzy search + labels).
/// - shortcat: ⌘⇧Space search-first; nothing is clicked until you press Return (no auto-click).
///   Shortcat's ⌃⏎ is right-click; in Pounce ⇧⏎ right-clicks and ⌃⏎ double-clicks
///   (actions are not remappable yet).
/// - vimium: labels only (no search), Vimium's `linkHintCharacters` default alphabet and colours.
/// - mouseless: modifier taps instead of chords — tap right ⌘ for click mode, right ⌥ for grid.
/// - scoot: ⌘⇧J element hints, ⌘⇧K grid; scroll moves to ⌃⌥J.
public enum Preset: String, Sendable, CaseIterable {
    case homerow, shortcat, vimium, mouseless, scoot

    public var title: String {
        switch self {
        case .homerow: "Homerow"
        case .shortcat: "Shortcat"
        case .vimium: "Vimium"
        case .mouseless: "Mouseless"
        case .scoot: "Scoot"
        }
    }

    public var blurb: String {
        switch self {
        case .homerow: "Pounce defaults: search or type a label, ⌘⇧Space"
        case .shortcat: "Search first, Return clicks, ⌘⇧Space"
        case .vimium: "Labels only, Vimium alphabet and yellow hints"
        case .mouseless: "Tap right ⌘ for hints, right ⌥ for the grid"
        case .scoot: "⌘⇧J hints, ⌘⇧K grid"
        }
    }

    /// The full config this preset starts from.
    public var baseline: Config {
        var c = Config()
        c.general.preset = self
        switch self {
        case .homerow:
            break
        case .shortcat:
            c.shortcuts.hint = "cmd+shift+space"
            c.hints.autoClick = false
            c.hints.labelsOnly = false
        case .vimium:
            c.hints.labelsOnly = true
            c.hints.alphabet = "sadfjklewcmpgh"
            c.hints.theme = .vimium
        case .mouseless:
            c.shortcuts.hint = "tap:rcmd"
            c.shortcuts.grid = "tap:ropt"
        case .scoot:
            c.shortcuts.hint = "cmd+shift+j"
            c.shortcuts.grid = "cmd+shift+k"
            c.shortcuts.scroll = "ctrl+opt+j"
        }
        return c
    }
}

// MARK: - Overrides (values that differ from the preset baseline)

extension Config {
    /// Every key `toTOML()` writes, in file order, with its value (and its source line, for comments).
    public func flattened() -> [(path: [String], value: TOMLValue, line: String)] {
        guard let doc = try? TOMLDocument(toTOML()) else { return [] }
        return doc.entries.map { ($0.path, $0.value, doc.lines[$0.line]) }
    }

    /// Keys whose value differs from this config's preset baseline (`preset` itself included
    /// unless it's the default).
    public func overrides() -> [(path: [String], value: TOMLValue, line: String)] {
        let base = Dictionary(general.preset.baseline.flattened().map { ($0.path, $0.value) }, uniquingKeysWith: { a, _ in a })
        return flattened().filter { e in
            if e.path == Config.presetPath { return general.preset != .homerow }
            return !TOML.equivalent(base[e.path], e.value)
        }
    }

    public static let presetPath = ["general", "preset"]

    static let overridesHeader = """
        # Pounce configuration: only settings that differ from the defaults are listed.
        # Delete a line to get its default back. Full reference: pounce config show
        # Shortcuts: "cmd+shift+space", "hyper+f", "tap:rcmd", "doubletap:shift", or "none".
        """

    /// A minimal config file: header comment + only the non-default keys.
    public func overridesTOML() -> String {
        var out = Config.overridesHeader + "\n"
        var table: [String]?
        for e in overrides() {
            let t = Array(e.path.dropLast())
            if t != table {
                out += "\n[\(t.map(TOML.key).joined(separator: "."))]\n"
                table = t
            }
            // Reuse toTOML's line so its explanatory comment comes along.
            out += e.line.trimmingCharacters(in: .whitespaces) + "\n"
        }
        return out
    }

    /// Switches preset, keeping the keys that were overridden relative to the old preset.
    public func withPreset(_ p: Preset) -> Config {
        var doc = (try? TOMLDocument(overridesTOML())) ?? (try! TOMLDocument(""))
        if p == .homerow { doc.remove(Config.presetPath) } else { doc.set(Config.presetPath, .string(p.rawValue)) }
        return (try? Config.parse(doc.text).0) ?? p.baseline
    }

    /// New text for the config file after an edit from `previous` to `self`. With existing text,
    /// only keys that changed are touched (set in place, inserted, or removed when back at the
    /// preset value), so comments and ordering survive. Without, writes `overridesTOML()`.
    /// Throws if `existing` doesn't parse: never overwrite a file the user is mid-way editing.
    public func savedText(previous: Config, existing: String?) throws -> String {
        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return overridesTOML() }
        var doc = try TOMLDocument(existing)
        let presetChanged = previous.general.preset != general.preset
        let new = flattened(), old = previous.flattened()
        let newMap = Dictionary(new.map { ($0.path, $0.value) }, uniquingKeysWith: { a, _ in a })
        let oldMap = Dictionary(old.map { ($0.path, $0.value) }, uniquingKeysWith: { a, _ in a })
        let base = Dictionary(general.preset.baseline.flattened().map { ($0.path, $0.value) }, uniquingKeysWith: { a, _ in a })
        var paths = new.map(\.path)
        for o in old where newMap[o.path] == nil { paths.append(o.path) }
        for p in paths {
            let now = newMap[p]
            guard presetChanged || !TOML.equivalent(now, oldMap[p]) else { continue }
            let desired: TOMLValue?
            if p == Config.presetPath {
                desired = general.preset == .homerow ? nil : now
            } else {
                desired = now.flatMap { TOML.equivalent($0, base[p]) ? nil : $0 }
            }
            let current = doc.value(p)
            if let d = desired {
                if !TOML.equivalent(current, d) { doc.set(p, d) }
            } else if current != nil {
                doc.remove(p)
            }
        }
        return doc.text
    }
}
