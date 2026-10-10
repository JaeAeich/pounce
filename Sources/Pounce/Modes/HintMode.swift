import AppKit
import PounceCore

@MainActor
protocol Mode: AnyObject {
    var kind: ModeKind { get }
    /// Returns true to swallow the key.
    func keyDown(_ e: KeyEvent, input: KeyInput?) -> Bool
    func keyUp(_ e: KeyEvent, input: KeyInput?)
    func stop()
}

/// Something a hint can point at.
struct Target {
    enum Payload {
        case element(ScannedElement)
        case window(WindowInfo)
        case menu(MenuEntry)
        case text(TextBox)
    }
    var item: HintItem
    var frame: Rect?
    var payload: Payload
    /// All-windows scope: the (possibly background) window the element belongs to,
    /// brought forward before clicking.
    var owner: WindowInfo? = nil

    var center: CGPoint? { frame?.center }
}

/// Drives HintSession for click, windows, menu-search and text modes.
@MainActor
final class HintMode: Mode {
    enum Presentation { case badges, windows, palette }

    let kind: ModeKind
    private unowned let app: AppController
    private let presentation: Presentation
    private var targets: [Target] = []
    private var session: HintSession?
    private var pending: [(KeyEvent, KeyInput?)] = []
    private var tutor = false
    private var loadingSince = Date()
    private var alive = true
    /// Windows mode: letters type labels until `/` or a non-label key starts a search.
    private var searching = false
    /// Inputs applied to the session, replayed when a rescan replaces the targets.
    private var inputs: [KeyInput] = []
    /// Full-set labels the user has seen (no query/filter), kept stable across rescans.
    private var seenLabels: [String: String] = [:]
    /// False while showing cached targets that a rescan hasn't confirmed yet.
    private(set) var verified = false
    private let openedAt = DispatchTime.now().uptimeNanoseconds
    /// Mode start → first labels in the overlay model / → rescan reconciled, in ms.
    private(set) var firstLabelsMs: Double?
    private(set) var reconciledMs: Double?
    /// Labels shown, by target key (self-test / diagnostics).
    var labelsByKey: [String: String] { session?.assignedLabels ?? [:] }
    var sessionQuery: String { session?.query ?? "" }
    var focusedIsInput: Bool { session?.focused.map { targets[$0].item.category == .input } ?? false }

    init(kind: ModeKind, app: AppController, presentation: Presentation) {
        self.kind = kind
        self.app = app
        self.presentation = presentation
        app.overlay.model.hud = HUDState(mode: kind, query: "", detail: "Scanning…", keys: [])
    }

    private var elapsedMs: Double { Double(DispatchTime.now().uptimeNanoseconds - openedAt) / 1e6 }

    /// Called with scanned targets. `verified: false` marks a cached scan shown before the
    /// rescan; a later call reconciles in place, keeping labels, query and focus.
    var hasSession: Bool { session != nil }

    func load(_ targets: [Target], verified: Bool = true) {
        log.debug("load \(targets.count) targets verified \(verified)")
        guard alive else { return }
        if session != nil {
            if verified { reconcile(targets) }
            return
        }
        if !verified && targets.isEmpty { return }
        self.verified = verified
        let cfg = app.store.config
        let bundle = app.frontApp?.bundleIdentifier
        self.targets = targets.map { t in
            var t = t
            t.item.usage = app.usage.store.usage(t.item.key)
            t.item.recency = app.usage.store.recency(t.item.key)
            if t.item.frame == nil { t.item.frame = t.frame }
            return t
        }
        session = HintSession(
            items: self.targets.map(\.item), alphabet: cfg.hints.alphabet,
            labelsOnly: presentation == .palette ? false : cfg.labelsOnly(for: bundle),
            autoClick: cfg.hints.autoClick, previousLabels: app.usage.store.labels)
        if targets.isEmpty {
            app.overlay.model.flash(emptyMessage)
            Sound.playWarn()
            app.stopMode()
            return
        }
        seenLabels = session?.assignedLabels ?? [:]
        if presentation == .palette { _ = session?.handle(.tab(backward: false)) }
        render()
        firstLabelsMs = elapsedMs
        if verified { reconciledMs = firstLabelsMs }
        let queued = pending
        pending = []
        for (e, i) in queued { _ = keyDown(e, input: i) }
    }

    /// Swaps in rescanned targets without disturbing what the user has typed.
    private func reconcile(_ fresh: [Target]) {
        guard let old = session else { return }
        verified = true
        defer { reconciledMs = elapsedMs }
        let fresh = fresh.map { t in
            var t = t
            t.item.usage = app.usage.store.usage(t.item.key)
            t.item.recency = app.usage.store.recency(t.item.key)
            if t.item.frame == nil { t.item.frame = t.frame }
            return t
        }
        if fresh.isEmpty {
            app.overlay.model.flash(emptyMessage)
            Sound.playWarn()
            app.stopMode()
            return
        }
        // Same elements: just take the fresh frames / element refs.
        if fresh.map(\.item) == targets.map(\.item) {
            let moved = zip(fresh, targets).contains { $0.frame != $1.frame }
            targets = fresh
            if moved { render() }
            return
        }
        let focusedKey = old.focused.map { targets[$0].item.key }
        let cfg = app.store.config
        if old.query.isEmpty && old.filter == .all { seenLabels.merge(old.assignedLabels) { _, now in now } }
        let previous = app.usage.store.labels.merging(seenLabels) { _, seen in seen }
        var s = HintSession(
            items: fresh.map(\.item), alphabet: old.alphabet, labelsOnly: old.labelsOnly,
            autoClick: cfg.hints.autoClick, previousLabels: previous)
        if presentation == .palette { _ = s.handle(.tab(backward: false)) }
        for i in inputs { _ = s.handle(i) }
        if let k = focusedKey, s.visible.contains(where: { fresh[$0].item.key == k }) {
            for _ in s.visible where s.focused.map({ fresh[$0].item.key }) != k { _ = s.handle(.tab(backward: false)) }
        }
        targets = fresh
        session = s
        render()
    }

    private var emptyMessage: String {
        switch kind {
        case .windows: "No windows found"
        case .menu: "This app has no searchable menus"
        case .text: "No text found on screen"
        default: "Nothing clickable here"
        }
    }

    func keyDown(_ e: KeyEvent, input: KeyInput?) -> Bool {
        guard var s = session else {
            // Still scanning: Esc cancels now and ⌘-chords go straight to the system; other keys wait.
            if input == .escape {
                app.stopMode()
                return true
            }
            if e.modifiers.contains(.command) {
                app.stopMode()
                return false
            }
            pending.append((e, input))
            return true
        }
        guard var input else { return true }
        // Labels-only: every letter is a label key, so non-Latin layouts type labels by physical key.
        if s.labelsOnly, case .char = input, let li = e.input(for: .labels) { input = li }
        if presentation == .windows, !s.labelsOnly, let i = windowsInput(input, s) {
            guard let i2 = i else { return true }
            input = i2
        }
        // In the palette every character is part of the query.
        if presentation == .palette, case .char(let c) = input { input = .char(Character(c.lowercased())) }
        let effects = s.handle(input)
        session = s
        inputs.append(input)
        for fx in effects { run(fx) }
        return true
    }

    /// Windows mode keys: nil = not handled here, .some(nil) = swallowed, .some(x) = feed x.
    private func windowsInput(_ input: KeyInput, _ s: HintSession) -> KeyInput?? {
        switch input {
        case .char("?"): return nil  // tutor
        case .char(let c) where !searching:
            if c == "/" {
                searching = true
                render()
                return .some(nil)
            }
            let next = s.typed + c.lowercased()
            if s.visible.contains(where: { s.labels[$0]?.hasPrefix(next) == true }) { return .char(Character(c.uppercased())) }
            searching = true  // not a label: start searching with it
            return .char(Character(c.lowercased()))
        case .char(let c): return .char(Character(c.lowercased()))
        case .backspace where searching && s.query.isEmpty:
            searching = false
            render()
            return .some(nil)
        case .escape where searching:
            searching = false
            if !s.query.isEmpty { return .control("u") }
            render()
            return .some(nil)
        default: return nil
        }
    }

    func keyUp(_ e: KeyEvent, input: KeyInput?) {}

    func stop() {
        alive = false
        if let s = session { app.usage.remember(s.assignedLabels) }
    }

    private func run(_ fx: HintEffect) {
        switch fx {
        case .update:
            if presentation == .palette, session?.focused == nil, session?.visible.isEmpty == false {
                _ = session?.handle(.tab(backward: false))
            }
            render()
        case .exit: app.stopMode()
        case .warn: Sound.playWarn()
        case .toggleTutor:
            tutor.toggle()
            render()
        case .repeatLast:
            guard let last = app.lastAction, let i = targets.firstIndex(where: { $0.item.key == last.key }) else {
                app.overlay.model.flash("Nothing to repeat here")
                Sound.playWarn()
                return
            }
            activate(i, last.action)
        case .activate(let i, let action): activate(i, action)
        }
    }

    private func activate(_ i: Int, _ action: HintAction) {
        let t = targets[i]
        let cfg = app.store.config
        app.usage.recordUse(t.item.key)
        if case .yank = action {
            let text = copyText(t)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            app.stopMode()
            app.overlay.model.flash("Copied “\(text.prefix(40))”")
            return
        }
        app.lastAction = (t.item.key, action)
        if let s = session { app.usage.remember(s.assignedLabels) }
        app.stopMode(keepToast: true)
        Sound.playClick()
        if let p = t.center, kind != .windows, kind != .menu { app.overlay.pulse(at: p) }

        switch t.payload {
        case .element(let el):
            // Frames may come from a cached scan: re-read the element before clicking.
            guard let f = t.frame, let p = Self.liveCenter(f, el.element, trustCached: verified) else {
                app.overlay.model.flash("That element moved – try again")
                Sound.playWarn()
                return
            }
            if case .drag(let from) = action,
                let a = targets[from].frame.flatMap({ fr -> CGPoint? in
                    if case .element(let src) = targets[from].payload { return Self.liveCenter(fr, src.element, trustCached: verified) }
                    return fr.center
                })
            {
                Mouse.drag(from: a, to: p)
                app.lastActivation = .init(action: action, point: p, element: el.element, frame: f, dragFrom: a)
                return
            }
            if let w = t.owner, !w.app.isActive {
                // Another app's window (all-windows scope): bring it forward first so the click
                // isn't swallowed as an activation click.
                WindowScanner.focus(w)
                let method = cfg.hints.click, restore = cfg.hints.restoreCursor
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    Clicker.perform(action, at: p, element: el.element, method: method, restoreCursor: restore)
                }
                app.noteClick(at: p)
                return
            }
            Clicker.perform(action, at: p, element: el.element, method: cfg.hints.click, restoreCursor: cfg.hints.restoreCursor)
            app.noteClick(at: p)
            app.lastActivation = .init(action: action, point: p, element: el.element, frame: f)
            // Text inputs never chain: you want to type into them.
            if kind == .hint, !el.isTextInput, action == .click {
                switch cfg.hints.afterClick {
                case .exit: break
                case .stay: app.chain(kind)
                case .scroll: app.chain(.scroll, at: p)
                }
            }
        case .window(let w):
            if case .window(let op) = action { WindowScanner.apply(op, to: w) } else { WindowScanner.focus(w) }
        case .menu(let m):
            if !m.element.perform("AXPress") { Sound.playWarn() }
        case .text:
            guard let p = t.center else { return }
            if case .drag(let from) = action, let a = targets[from].center {
                Mouse.drag(from: a, to: p)
                return
            }
            Clicker.perform(action, at: p, element: nil, method: .mouse, restoreCursor: cfg.hints.restoreCursor)
            app.noteClick(at: p)
            app.lastActivation = .init(action: action, point: p)
        }
    }

    /// Where to click `el` now: the cached point if it's still inside the element, else the
    /// center of its current on-screen frame. nil if it's gone and the cache can't be trusted.
    static func liveCenter(_ cached: Rect, _ el: AXUIElement, trustCached: Bool) -> CGPoint? {
        el.setTimeout(0.25)
        let v = el.values(["AXPosition", "AXSize"])
        guard let now = AX.frame(position: v[0], size: v[1]), now.width >= 1, now.height >= 1 else {
            return trustCached ? cached.center : nil
        }
        let c = cached.center
        if now.contains(x: c.x, y: c.y) { return c }
        let vis = now.intersection(Screens.union)
        return vis.isEmpty ? nil : vis.center
    }

    static func linkURL(_ el: AXUIElement) -> String? {
        el.setTimeout(0.25)
        guard let v = el.value("AXURL") else { return nil }
        if CFGetTypeID(v) == CFURLGetTypeID() { return (v as! URL).absoluteString }
        return v as? String
    }

    private func copyText(_ t: Target) -> String {
        switch t.payload {
        case .element(let e):
            // Links: the URL (Vimium yf), falling back to their text.
            if e.category == .link, let url = Self.linkURL(e.element) { url } else { e.copyText ?? t.item.text }
        case .window(let w): w.title
        case .menu(let m): m.title
        case .text(let b): b.text
        }
    }

    // MARK: Rendering

    private func render() {
        guard let s = session else { return }
        let model = app.overlay.model
        let typed = s.typed
        switch presentation {
        case .windows where windowList(s):
            model.scene = .palette(
                query: s.query, rows: windowRows(s), total: s.visible.count,
                placeholder: searching ? "Search windows…" : "Type a label, or / to search windows")
        case .badges, .windows:
            var badges: [HintBadge] = []
            for i in s.visible {
                guard let label = s.labels[i], let f = targets[i].frame else { continue }
                if !typed.isEmpty && !label.hasPrefix(typed) { continue }
                var b = HintBadge(id: i, label: label, typed: typed.count, frame: f, focused: s.focused == i, dragSource: s.dragSource == i)
                if case .window(let w) = targets[i].payload {
                    b.title = w.title
                    b.icon = w.app.icon
                }
                badges.append(b)
            }
            let focusedFrame = presentation == .badges ? s.focused.flatMap { targets[$0].frame } : nil
            model.scene = .hints(badges: badges, focusedFrame: focusedFrame, tutor: tutorInfo(s), large: presentation == .windows)
        case .palette:
            let rows = s.visible.prefix(10).map { i -> PaletteRow in
                var path = ""
                var title = targets[i].item.text
                var shortcut: String?
                if case .menu(let m) = targets[i].payload {
                    title = m.title
                    path = m.path.dropLast().joined(separator: " › ")
                    shortcut = m.shortcut
                }
                return PaletteRow(id: i, label: "", typed: 0, title: title, path: path, shortcut: shortcut, focused: s.focused == i)
            }
            model.scene = .palette(
                query: s.query, rows: Array(rows), total: s.visible.count,
                placeholder: "Search \(app.frontApp?.localizedName ?? "app") menus…")
        }
        if app.store.config.hints.showHUD || presentation == .palette {
            model.hud = hud(s)
        } else {
            model.hud = nil
        }
    }

    private func hud(_ s: HintSession) -> HUDState {
        var detail = s.visible.isEmpty ? "No matches" : "\(s.visible.count) \(s.visible.count == 1 ? "match" : "matches")"
        if s.filter != .all { detail = "\(s.filter.rawValue.capitalized) · " + detail }
        if s.dragSource != nil { detail = "Drag: pick a drop target · ⏎" }
        if let f = s.fill {
            detail = "Type into field: “\(f)” · ⏎"
        } else if !s.labelsOnly, presentation == .badges, let f = s.focused, targets[f].item.category == .input {
            detail += " · = to type into it"
        }
        let keys: [String] =
            switch presentation {
            case .palette: ["↑↓ select", "⏎ run", "esc"]
            case .windows:
                searching || s.labelsOnly
                    ? ["↑↓ select", "⏎ focus", "⌥←→ halves", "⌥↑ max", "⌥↓ next screen", "esc"]
                    : ["type label", "/ search", "⌥←→ halves", "⌥↑ max", "⌥↓ next screen", "esc"]
            case .badges:
                s.labelsOnly
                    ? ["type label", "␣ click", "⇥ next", "? tutor", "esc"]
                    : ["type to search", "⇧+label jump", "⏎ click", "⇧⏎ right", "⌃Y copy", "? tutor", "esc"]
            }
        return HUDState(mode: kind, query: s.query, detail: detail, keys: keys)
    }

    /// Windows mode shows a Spotlight-style list instead of big badges when there are hidden
    /// windows (other workspaces / Spaces, minimized), when on-screen badges would overlap
    /// (stacked maximized windows), or while searching.
    private func windowList(_ s: HintSession) -> Bool {
        if searching || !s.query.isEmpty { return true }
        var frames: [Rect] = []
        for t in targets {
            guard case .window(let w) = t.payload else { continue }
            guard w.isVisible, let f = t.frame else { return true }
            frames.append(f)
        }
        return WindowVisibility.badgesCollide(frames, size: (300, 90))
    }

    private func windowRows(_ s: HintSession) -> [PaletteRow] {
        let typed = s.typed
        let shown = s.visible.filter { typed.isEmpty || s.labels[$0]?.hasPrefix(typed) == true }
        let maxRows = 12
        let at = s.focused.flatMap { shown.firstIndex(of: $0) } ?? 0
        let first = max(0, min(at - maxRows + 1, shown.count - maxRows))
        return shown.dropFirst(first).prefix(maxRows).map { i in
            guard case .window(let w) = targets[i].payload else {
                return PaletteRow(id: i, label: "", typed: 0, title: targets[i].item.text, path: "", shortcut: nil, focused: s.focused == i)
            }
            let app = w.app.localizedName ?? ""
            var r = PaletteRow(
                id: i, label: s.labels[i] ?? "", typed: typed.count, title: w.title,
                path: [app == w.title ? nil : app, w.stateText].compactMap { $0 }.joined(separator: " · "),
                shortcut: nil, focused: s.focused == i)
            r.icon = w.app.icon
            return r
        }
    }

    private func tutorInfo(_ s: HintSession) -> TutorInfo? {
        guard tutor, presentation == .badges, let f = s.focused ?? s.visible.first, let frame = targets[f].frame else { return nil }
        var rows: [(String, String)] = []
        if case .element(let e) = targets[f].payload {
            rows.append(
                (
                    "role",
                    [e.role.replacingOccurrences(of: "AX", with: ""), e.subrole?.replacingOccurrences(of: "AX", with: "")].compactMap { $0 }
                        .joined(separator: " / ")
                ))
            for (k, v) in [
                ("title", e.title), ("description", e.desc), ("value", e.value), ("placeholder", e.placeholder), ("help", e.help),
                ("identifier", e.identifier),
            ] {
                if let v, !v.isEmpty { rows.append((k, String(v.prefix(80)))) }
            }
        } else {
            rows.append(("text", targets[f].item.text))
        }
        rows.append(("label", s.labels[f]?.uppercased() ?? "–"))
        return TutorInfo(frame: frame, rows: rows)
    }
}

// MARK: - Target builders

enum Targets {
    static func elements(_ els: [ScannedElement], bundleID: String?, windowOrigin origin: Point) -> [Target] {
        els.map { e in
            let k =
                e.source == .window
                ? e.key(bundleID: bundleID, windowOrigin: origin) : e.key(bundleID: e.source.rawValue, windowOrigin: Point(x: 0, y: 0))
            return Target(item: HintItem(text: e.searchText, key: k, category: e.category), frame: e.frame, payload: .element(e))
        }
    }

    static func windows(_ ws: [WindowInfo]) -> [Target] {
        ws.map { w in
            // Hidden windows have no badge (frame nil): they're only in the list.
            Target(
                item: HintItem(
                    text: "\(w.app.localizedName ?? "") \(w.title)", key: "win|\(w.app.bundleIdentifier ?? "")|\(w.title)", category: .other
                ),
                frame: w.isVisible ? w.visibleFrame : nil, payload: .window(w))
        }
    }

    static func menus(_ ms: [MenuEntry], bundleID: String?) -> [Target] {
        ms.map { m in
            Target(
                item: HintItem(
                    text: m.path.reversed().joined(separator: " "), key: "menu|\(bundleID ?? "")|\(m.path.joined(separator: "/"))",
                    category: .button),
                frame: nil, payload: .menu(m))
        }
    }

    static func text(_ boxes: [TextBox]) -> [Target] {
        boxes.map { b in
            Target(
                item: HintItem(text: b.text, key: "text|\(b.text)|\(Int(b.frame.x / 40)),\(Int(b.frame.y / 40))", category: .other),
                frame: b.frame, payload: .text(b))
        }
    }
}
