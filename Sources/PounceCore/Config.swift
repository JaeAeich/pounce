import Foundation

public enum Theme: String, Sendable, CaseIterable { case dark, light, vimium, system }
public enum ScanMode: String, Sendable, CaseIterable { case fast, exhaustive }
public enum ClickMethod: String, Sendable, CaseIterable { case mouse, accessibility }
public enum HintSource: String, Sendable, CaseIterable { case window, menubar, extras, dock }
/// What click mode labels: the focused window, every visible window on its screen, or on all screens.
public enum HintScopeKind: String, Sendable, CaseIterable { case window, screen, all }
/// What click mode does after a click: close, re-open (chain), or scroll the clicked area.
public enum AfterClick: String, Sendable, CaseIterable { case exit, stay, scroll }

/// User configuration. Every field has a default; the TOML file only needs overrides.
public struct Config: Sendable, Equatable {
    public struct Shortcuts: Sendable, Equatable {
        public var hint = "cmd+shift+space"
        public var scroll = "cmd+shift+j"
        public var grid = "ctrl+opt+g"
        public var windows = "ctrl+opt+w"
        public var menu = "ctrl+opt+m"
        public var text = "ctrl+opt+t"
        public var mouse = "ctrl+opt+c"
        /// Repeat the last click without opening a mode.
        public var `repeat` = "none"
        public init() {}
    }

    public struct Hints: Sendable, Equatable {
        public var alphabet = "asdfghjkl"
        /// Vimium style: no search, labels typed without Shift, Space clicks.
        public var labelsOnly = false
        /// Click immediately once a label is fully typed.
        public var autoClick = true
        /// After a click: exit, stay (re-open click mode), or scroll the area under the click.
        /// Never chains after clicking a text input.
        public var afterClick: AfterClick = .exit
        /// Legacy alias of `afterClick == .stay` (`click_chain` in older configs).
        public var clickChain: Bool {
            get { afterClick == .stay }
            set { afterClick = newValue ? .stay : .exit }
        }
        public var sources: [HintSource] = [.window, .menubar, .extras]
        public var scan: ScanMode = .fast
        public var scope: HintScopeKind = .window
        public var click: ClickMethod = .mouse
        public var restoreCursor = false
        public var theme: Theme = .system
        public var size = 12.0
        public var showHUD = true
        public init() {}
    }

    public struct Scroll: Sendable, Equatable {
        /// Pixels per second while holding a scroll key.
        public var speed = 900.0
        /// Pixels per second while holding Shift (dash).
        public var dashSpeed = 3600.0
        /// Left, down, up, right.
        public var keys = "hjkl"
        public init() {}
    }

    public struct Grid: Sendable, Equatable {
        /// 9 keys mapping to a 3×3 grid, row-major.
        public var keys = "uiojklm,."
        public var style: GridStyle = .recursive
        /// Two-key style: row / column letters.
        public var labels = GridSession.defaultLabelKeys
        public init() {}
    }

    public struct Mouse: Sendable, Equatable {
        /// Left, down, up, right. Empty = same as `[scroll] keys`.
        public var keys = ""
        /// Top pointer speeds in pt/s (normal, ⇧ fast, ⌥ precise).
        public var speed = 1400.0
        public var fastSpeed = 4200.0
        public var slowSpeed = 260.0
        /// Seconds of ease-in to reach top speed.
        public var acceleration = 0.35
        public init() {}

        public func resolvedKeys(scroll: Scroll) -> String { keys.count == 4 ? keys : scroll.keys }
        public var tuning: MouseSession.Tuning {
            MouseSession.Tuning(speed: speed, fastSpeed: fastSpeed, slowSpeed: slowSpeed, ramp: acceleration)
        }
    }

    public struct General: Sendable, Equatable {
        public var sounds = true
        public var hyperKey = false
        /// With hyperKey on: tapping Caps Lock alone sends Escape.
        public var capsLockEscape = true
        public var ignoredApps: [String] = []
        /// Pre-scan the frontmost app in the background so hints appear instantly.
        public var prewarm = true
        /// Baseline values mimicking another tool; explicit keys override it. See `Preset`.
        public var preset: Preset = .homerow
        public init() {}
    }

    public struct AppOverride: Sendable, Equatable {
        public var ignore: Bool?
        public var scan: ScanMode?
        public var labelsOnly: Bool?
        public init(ignore: Bool? = nil, scan: ScanMode? = nil, labelsOnly: Bool? = nil) {
            self.ignore = ignore
            self.scan = scan
            self.labelsOnly = labelsOnly
        }
    }

    public var shortcuts = Shortcuts()
    public var hints = Hints()
    public var scroll = Scroll()
    public var grid = Grid()
    public var mouse = Mouse()
    public var general = General()
    /// Keyed by bundle identifier.
    public var apps: [String: AppOverride] = [:]

    public init() {}

    public func isIgnored(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return apps[id]?.ignore ?? general.ignoredApps.contains(id)
    }

    public func scanMode(for bundleID: String?) -> ScanMode {
        bundleID.flatMap { apps[$0]?.scan } ?? hints.scan
    }

    public func labelsOnly(for bundleID: String?) -> Bool {
        bundleID.flatMap { apps[$0]?.labelsOnly } ?? hints.labelsOnly
    }
}

// MARK: - TOML mapping

extension Config {
    /// Parses config text. Unknown keys and bad values produce warnings and keep the default.
    /// Syntax errors throw.
    public static func parse(_ text: String) throws -> (Config, warnings: [String]) {
        let root = try TOML.parse(text)
        var r = Reader(root: root)
        // The preset is the baseline every other key overrides, so it's read first.
        var preset = Preset.homerow
        if let g = root["general"]?.table, g["preset"] != nil {
            var pr = Reader(root: g, prefix: "general.")
            pr.enumValue("preset", &preset)
            r.warnings += pr.warnings
        }
        var c = preset.baseline

        r.section("shortcuts") { r in
            r.shortcut("hint", &c.shortcuts.hint)
            r.shortcut("scroll", &c.shortcuts.scroll)
            r.shortcut("grid", &c.shortcuts.grid)
            r.shortcut("windows", &c.shortcuts.windows)
            r.shortcut("menu", &c.shortcuts.menu)
            r.shortcut("text", &c.shortcuts.text)
            r.shortcut("mouse", &c.shortcuts.mouse)
            r.shortcut("repeat", &c.shortcuts.repeat)
        }
        r.section("hints") { r in
            r.string("alphabet", &c.hints.alphabet) { Labels.uniqueChars($0).count >= 2 ? nil : "needs at least 2 distinct characters" }
            r.bool("labels_only", &c.hints.labelsOnly)
            r.bool("auto_click", &c.hints.autoClick)
            r.bool("click_chain", &c.hints.clickChain)
            r.enumValue("after_click", &c.hints.afterClick)
            r.enumList("sources", &c.hints.sources)
            r.enumValue("scan", &c.hints.scan)
            r.enumValue("scope", &c.hints.scope)
            r.enumValue("click", &c.hints.click)
            r.bool("restore_cursor", &c.hints.restoreCursor)
            r.enumValue("theme", &c.hints.theme)
            r.double("size", &c.hints.size, range: 8...32)
            r.bool("show_hud", &c.hints.showHUD)
        }
        r.section("scroll") { r in
            r.double("speed", &c.scroll.speed, range: 50...20000)
            r.double("dash_speed", &c.scroll.dashSpeed, range: 50...40000)
            r.string("keys", &c.scroll.keys) { Array($0).count == 4 ? nil : "needs exactly 4 keys (left, down, up, right)" }
        }
        r.section("grid") { r in
            r.string("keys", &c.grid.keys) { Labels.uniqueChars($0).count == 9 ? nil : "needs exactly 9 distinct keys" }
            r.enumValue("style", &c.grid.style)
            r.string("labels", &c.grid.labels) { Labels.uniqueChars($0).count >= 4 ? nil : "needs at least 4 distinct characters" }
        }
        r.section("mouse") { r in
            r.string("keys", &c.mouse.keys) {
                $0.isEmpty || Set($0.lowercased()).count == 4 && $0.count == 4
                    ? nil : "needs exactly 4 distinct keys (left, down, up, right) or empty"
            }
            r.double("speed", &c.mouse.speed, range: 20...20000)
            r.double("fast_speed", &c.mouse.fastSpeed, range: 20...40000)
            r.double("slow_speed", &c.mouse.slowSpeed, range: 5...20000)
            r.double("acceleration", &c.mouse.acceleration, range: 0...3)
        }
        r.section("general") { r in
            r.bool("sounds", &c.general.sounds)
            r.bool("hyper_key", &c.general.hyperKey)
            r.bool("caps_lock_escape", &c.general.capsLockEscape)
            r.strings("ignored_apps", &c.general.ignoredApps)
            r.bool("prewarm", &c.general.prewarm)
            r.consumed.insert("preset")  // read above
        }
        if let apps = root["apps"] {
            if let t = apps.table {
                for (id, v) in t.sorted(by: { $0.key < $1.key }) {
                    guard let at = v.table else {
                        r.warn("apps.\(id): expected a table")
                        continue
                    }
                    var o = AppOverride()
                    var ar = Reader(root: at, prefix: "apps.\(id).")
                    ar.optBool("ignore", &o.ignore)
                    ar.optEnum("scan", &o.scan)
                    ar.optBool("labels_only", &o.labelsOnly)
                    ar.finish()
                    r.warnings += ar.warnings
                    c.apps[id] = o
                }
            } else {
                r.warn("apps: expected a table")
            }
        }
        r.consumed.insert("apps")
        r.finish()
        return (c, r.warnings)
    }

    public func toTOML() -> String {
        func q(_ s: String) -> String { TOML.quote(s) }
        func list(_ a: [String]) -> String { "[" + a.map(q).joined(separator: ", ") + "]" }
        var out = """
            # Pounce configuration. Delete any line to get its default.
            # Shortcuts: "cmd+shift+space", "hyper+f", "tap:rcmd", "doubletap:shift", or "none".

            [shortcuts]
            hint = \(q(shortcuts.hint))
            scroll = \(q(shortcuts.scroll))
            grid = \(q(shortcuts.grid))
            windows = \(q(shortcuts.windows))
            menu = \(q(shortcuts.menu))
            text = \(q(shortcuts.text))
            mouse = \(q(shortcuts.mouse))
            repeat = \(q(shortcuts.repeat))  # repeat the last click

            [hints]
            alphabet = \(q(hints.alphabet))
            labels_only = \(hints.labelsOnly)  # Vimium style: no search, type labels directly
            auto_click = \(hints.autoClick)  # click as soon as a label is complete
            after_click = \(q(hints.afterClick.rawValue))  # exit | stay | scroll (scroll the clicked area)
            sources = \(list(hints.sources.map(\.rawValue)))  # window, menubar, extras, dock
            scan = \(q(hints.scan.rawValue))  # fast | exhaustive
            scope = \(q(hints.scope.rawValue))  # window | screen | all (visible windows of every app)
            click = \(q(hints.click.rawValue))  # mouse | accessibility
            restore_cursor = \(hints.restoreCursor)
            theme = \(q(hints.theme.rawValue))  # system | dark | light | vimium
            size = \(TOML.format(hints.size))
            show_hud = \(hints.showHUD)

            [scroll]
            speed = \(TOML.format(scroll.speed))  # px/s
            dash_speed = \(TOML.format(scroll.dashSpeed))  # px/s with Shift
            keys = \(q(scroll.keys))  # left, down, up, right

            [grid]
            keys = \(q(grid.keys))  # 3x3, row-major
            style = \(q(grid.style.rawValue))  # recursive | twokey (two letters pick a cell, then 3x3)
            labels = \(q(grid.labels))  # twokey: row / column letters

            [mouse]
            keys = \(q(mouse.keys))  # left, down, up, right; empty = same as [scroll] keys
            speed = \(TOML.format(mouse.speed))  # pt/s
            fast_speed = \(TOML.format(mouse.fastSpeed))  # pt/s with Shift
            slow_speed = \(TOML.format(mouse.slowSpeed))  # pt/s with Option
            acceleration = \(TOML.format(mouse.acceleration))  # seconds to top speed

            [general]
            preset = \(q(general.preset.rawValue))  # homerow | shortcat | vimium | mouseless | scoot
            sounds = \(general.sounds)
            hyper_key = \(general.hyperKey)  # Caps Lock becomes ⌃⌥⇧⌘
            caps_lock_escape = \(general.capsLockEscape)  # tap Caps Lock alone for Escape
            ignored_apps = \(list(general.ignoredApps))
            prewarm = \(general.prewarm)  # pre-scan the front app so hints show instantly

            """
        for (id, o) in apps.sorted(by: { $0.key < $1.key }) {
            out += "\n[apps.\(TOML.key(id))]\n"
            if let v = o.ignore { out += "ignore = \(v)\n" }
            if let v = o.scan { out += "scan = \(q(v.rawValue))\n" }
            if let v = o.labelsOnly { out += "labels_only = \(v)\n" }
        }
        return out
    }
}

private struct Reader {
    var root: [String: TOMLValue]
    var prefix = ""
    var warnings: [String] = []
    var consumed = Set<String>()

    mutating func warn(_ m: String) { warnings.append(m) }

    mutating func section(_ name: String, _ body: (inout Reader) -> Void) {
        consumed.insert(name)
        guard let v = root[name] else { return }
        guard let t = v.table else {
            warn("\(name): expected a table")
            return
        }
        var sub = Reader(root: t, prefix: prefix + name + ".")
        body(&sub)
        sub.finish()
        warnings += sub.warnings
    }

    mutating func finish() {
        for k in root.keys.sorted() where !consumed.contains(k) { warn("unknown key '\(prefix)\(k)'") }
    }

    private mutating func take(_ k: String) -> TOMLValue? {
        consumed.insert(k)
        return root[k]
    }

    mutating func string(_ k: String, _ out: inout String, validate: (String) -> String? = { _ in nil }) {
        guard let v = take(k) else { return }
        guard let s = v.string else {
            warn("\(prefix)\(k): expected a string")
            return
        }
        if let err = validate(s) {
            warn("\(prefix)\(k): \(err)")
            return
        }
        out = s
    }

    mutating func shortcut(_ k: String, _ out: inout String) {
        string(k, &out) { s in
            let t = s.trimmingCharacters(in: .whitespaces).lowercased()
            return t.isEmpty || t == "none" || t == "off" || Shortcut.parse(s) != nil ? nil : "can't parse shortcut '\(s)'"
        }
    }

    mutating func bool(_ k: String, _ out: inout Bool) {
        guard let v = take(k) else { return }
        guard let b = v.bool else {
            warn("\(prefix)\(k): expected true or false")
            return
        }
        out = b
    }

    mutating func optBool(_ k: String, _ out: inout Bool?) {
        var b = false
        guard root[k] != nil else {
            consumed.insert(k)
            return
        }
        let before = warnings.count
        bool(k, &b)
        if warnings.count == before { out = b }
    }

    mutating func double(_ k: String, _ out: inout Double, range: ClosedRange<Double>) {
        guard let v = take(k) else { return }
        guard let d = v.double else {
            warn("\(prefix)\(k): expected a number")
            return
        }
        guard range.contains(d) else {
            warn("\(prefix)\(k): must be between \(range.lowerBound) and \(range.upperBound)")
            return
        }
        out = d
    }

    mutating func strings(_ k: String, _ out: inout [String]) {
        guard let v = take(k) else { return }
        guard let s = v.strings else {
            warn("\(prefix)\(k): expected a list of strings")
            return
        }
        out = s
    }

    mutating func enumValue<E: RawRepresentable & CaseIterable>(_ k: String, _ out: inout E) where E.RawValue == String {
        guard let v = take(k) else { return }
        guard let s = v.string, let e = E(rawValue: s.lowercased()) else {
            warn("\(prefix)\(k): expected one of \(E.allCases.map(\.rawValue).joined(separator: ", "))")
            return
        }
        out = e
    }

    mutating func optEnum<E: RawRepresentable & CaseIterable>(_ k: String, _ out: inout E?) where E.RawValue == String {
        guard root[k] != nil, let first = E.allCases.first else {
            consumed.insert(k)
            return
        }
        var e = first
        let before = warnings.count
        enumValue(k, &e)
        if warnings.count == before { out = e }
    }

    mutating func enumList<E: RawRepresentable & CaseIterable>(_ k: String, _ out: inout [E]) where E.RawValue == String {
        guard let v = take(k) else { return }
        guard let s = v.strings else {
            warn("\(prefix)\(k): expected a list of strings")
            return
        }
        var result: [E] = []
        for item in s {
            if let e = E(rawValue: item.lowercased()) { result.append(e) } else { warn("\(prefix)\(k): unknown '\(item)'") }
        }
        out = result
    }
}
