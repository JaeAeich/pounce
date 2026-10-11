import AppKit
import PounceCore
import SwiftUI

/// End-to-end checks against a fixture window inside Pounce itself:
/// accessibility scanning, search + labels, pressing, scrolling, menus, OCR, overlay and config.
/// Reading our own accessibility tree needs no permission, so this runs anywhere.
@MainActor
final class SelfTest: ObservableObject {
    struct Result: Identifiable {
        enum Status { case pass, fail, skip }
        let id = UUID()
        let name: String
        let status: Status
        let detail: String
    }

    @Published private(set) var results: [Result] = []
    @Published private(set) var running = false
    private let app: AppController?
    private var fixture: Fixture?

    init(app: AppController?) { self.app = app }

    var failed: Int { results.filter { $0.status == .fail }.count }

    func run(completion: (() -> Void)? = nil) {
        guard !running else { return }
        running = true
        results = []
        Task {
            await runAll()
            running = false
            fixture?.window.close()
            fixture = nil
            completion?()
        }
    }

    private func record(_ name: String, _ ok: Bool?, _ detail: String) {
        let s: Result.Status = ok == nil ? .skip : ok! ? .pass : .fail
        results.append(Result(name: name, status: s, detail: detail))
    }

    private func runAll() async {
        let f = Fixture()
        fixture = f
        try? await Task.sleep(nanoseconds: 400_000_000)

        // 1. Find our fixture window through the AX API.
        let axWin: AXUIElement? = await Task.detached {
            AXUIElement.app(getpid()).elements("AXWindows").first { $0.string("AXTitle") == Fixture.title }
        }.value
        guard let win = axWin else {
            record("Find fixture window", false, "AXWindows did not include the fixture")
            return
        }
        record("Find fixture window", true, "AXWindow “\(Fixture.title)”")

        // 2. Scan.
        let started = Date()
        let els: [ScannedElement] = await Task.detached {
            Scanner.scan(roots: [(win, win.frame)], options: Scanner.Options(), source: .window)
        }.value
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let titles = Set(els.compactMap { $0.title ?? $0.desc ?? $0.placeholder })
        let expected = ["Submit Order", "Cancel", "Remember me", "Email address"]
        let missing = expected.filter { !titles.contains($0) }
        record(
            "Scan clickable elements", missing.isEmpty,
            missing.isEmpty ? "\(els.count) elements in \(ms) ms" : "missing: \(missing.joined(separator: ", ")) – found \(titles.sorted())"
        )
        let roles = Set(els.map(\.role))
        let wantRoles: Set = ["AXButton", "AXCheckBox", "AXTextField", "AXPopUpButton"]
        record(
            "Element roles", wantRoles.isSubset(of: roles),
            "found " + roles.sorted().map { $0.replacingOccurrences(of: "AX", with: "") }.joined(separator: ", "))
        let winFrame = win.frame
        let insideWindow = els.allSatisfy { e in winFrame.map { !e.frame.intersection($0).isEmpty } ?? true }
        record("Frames inside window", insideWindow, insideWindow ? "all \(els.count) on screen" : "some frames outside the window")
        let clippedOut = !titles.contains("Hidden Below")
        record(
            "Clip scrolled-out content", clippedOut,
            clippedOut ? "off-screen button skipped" : "labelled a button that is scrolled out of view")
        await scannerChecks(win: win, reference: els)

        // 3. Search + labels.
        let targets = Targets.elements(els, bundleID: "selftest", windowOrigin: Point(x: 0, y: 0))
        var session = HintSession(items: targets.map(\.item), alphabet: "asdfghjkl")
        for c in "subord" { _ = session.handle(.char(c)) }
        let focusedTitle = session.focused.flatMap { i -> String? in
            if case .element(let e) = targets[i].payload { return e.title }
            return nil
        }
        record("Fuzzy search “subord”", focusedTitle == "Submit Order", "focused: \(focusedTitle ?? "nothing")")
        let fresh = HintSession(items: targets.map(\.item), alphabet: "asdfghjkl")
        let labels = fresh.visible.compactMap { fresh.labels[$0] }
        let prefixFree = !labels.contains { a in labels.contains { b in a != b && b.hasPrefix(a) } }
        record("Labels unique & prefix-free", Set(labels).count == labels.count && prefixFree, "\(labels.count) labels")

        // 4. Activate via label typing → AXPress.
        var s2 = HintSession(items: targets.map(\.item), alphabet: "asdfghjkl")
        if let i = targets.firstIndex(where: {
            if case .element(let e) = $0.payload { return e.title == "Submit Order" }
            return false
        }),
            let label = s2.labels[i]
        {
            var fx: [HintEffect] = []
            for c in label.uppercased() { fx = s2.handle(.char(c)) }
            let ok = fx.contains(.activate(item: i, .click))
            if ok, case .element(let e) = targets[i].payload {
                let before = f.submitCount
                _ = await Task.detached { e.element.perform("AXPress") }.value
                try? await Task.sleep(nanoseconds: 150_000_000)
                record(
                    "Type label “\(label.uppercased())” → press", f.submitCount == before + 1, "Submit pressed \(f.submitCount - before)×")
            } else {
                record("Type label → press", false, "effects: \(fx)")
            }
        }

        // 5. Checkbox toggles through AXPress.
        if let cb = els.first(where: { $0.role == "AXCheckBox" }) {
            let before = f.checkbox.state
            _ = await Task.detached { cb.element.perform("AXPress") }.value
            try? await Task.sleep(nanoseconds: 100_000_000)
            record("Toggle checkbox", f.checkbox.state != before, "state \(before.rawValue) → \(f.checkbox.state.rawValue)")
        }

        // 6. Focus the text field.
        if let tf = els.first(where: { $0.isTextInput }) {
            Quiet.show(f.window)
            let ok = await Task.detached { tf.element.set("AXFocused", kCFBooleanTrue) }.value
            try? await Task.sleep(nanoseconds: 100_000_000)
            record("Focus text field", ok, ok ? "AXFocused set" : "AXFocused not settable")
        }

        // 7. Scroll areas + edge jump via the scrollbar.
        let areas: [ScrollArea] = await Task.detached { ScrollScanner.scan(window: win) }.value
        record("Find scroll areas", !areas.isEmpty, "\(areas.count) area(s)")

        // 8. Menu search over our own main menu (menu bars only exist for regular apps).
        let wasPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let menus: [MenuEntry] = await Task.detached { MenuScanner.scan(pid: getpid()) }.value
        if menus.isEmpty {
            record("Menu search scan", nil, "no AXMenuBar exposed for this process")
        } else {
            let found = menus.first { $0.title == "Self-Test Action" }
            record(
                "Menu search scan", found != nil, "\(menus.count) items, e.g. \(menus.prefix(3).map { $0.path.joined(separator: " › ") })")
            var ms = HintSession(items: Targets.menus(menus, bundleID: "selftest").map(\.item), alphabet: "asdfghjkl")
            for c in "selftestact" { _ = ms.handle(.char(c)) }
            let top = ms.focused.map { menus[$0].title }
            record("Menu search ranking", top == "Self-Test Action", "top hit for “selftestact”: \(top ?? "none")")
        }
        if wasPolicy != .regular { NSApp.setActivationPolicy(wasPolicy) }

        // 8b. Drive the real modes with synthetic key events.
        await driveModes(f, targets: targets, areas: areas)
        await inputChecks(targets: targets)

        // 8c. Prewarm cache: instant labels from a cached scan, reconciled by a rescan.
        await cacheChecks(f, win: win, winFrame: winFrame)

        // 9. OCR on a rendered image.
        let img = Fixture.ocrImage("Pounce Clicks Words")
        let boxes = (try? TextScanner.recognize(img, in: Rect(x: 0, y: 0, width: 600, height: 160))) ?? []
        let words = Set(boxes.map { $0.text.lowercased() })
        record("OCR words", words.isSuperset(of: ["pounce", "clicks", "words"]), "read: \(boxes.map(\.text).joined(separator: " "))")

        // 10. Overlay renders.
        do {
            let overlay = app?.overlay ?? OverlayController()
            overlay.model.activeScreen = Screens.topLeft(NSScreen.main ?? NSScreen.screens[0])
            overlay.model.scene = .hints(
                badges: targets.prefix(20).enumerated().map {
                    HintBadge(
                        id: $0.offset, label: labels.indices.contains($0.offset) ? labels[$0.offset] : "?", typed: 0,
                        frame: $0.element.frame!, focused: $0.offset == 0, dragSource: false)
                },
                focusedFrame: targets.first?.frame, tutor: nil, large: false)
            overlay.model.hud = HUDState(mode: .hint, query: "self-test", detail: "\(targets.count) matches", keys: ["esc"])
            try? await Task.sleep(nanoseconds: 900_000_000)
            let visible = NSApp.windows.contains {
                $0 is NSPanel && $0.isVisible && $0.level.rawValue >= Int(CGWindowLevelForKey(.assistiveTechHighWindow))
            }
            let pills = overlay.visiblePills
            overlay.hideNow()
            // Enough labels for a multi-row sprite atlas, spread over the screen, then compare real screen pixels.
            let grid = Labels.generate(count: 80, alphabet: "asdfghjkl").enumerated().map { i, l in
                HintBadge(
                    id: i, label: l, typed: 0, frame: Rect(x: 60 + Double(i % 10) * 90, y: 80 + Double(i / 10) * 60, width: 60, height: 24),
                    focused: false, dragSource: false)
            }
            overlay.model.scene = .hints(badges: grid, focusedFrame: nil, tutor: nil, large: false)
            try? await Task.sleep(nanoseconds: 500_000_000)
            let px = overlay.verifyPills()
            record(
                "Overlay pixels match labels", px.checked >= 60 && Double(px.matched) >= Double(px.checked) * 0.95,
                "\(px.matched)/\(px.checked) pills on screen show their own label")
            overlay.hideNow()
            let cleared = overlay.visiblePills == 0
            record(
                "Overlay shows hints", visible && pills == min(20, targets.count) && cleared,
                visible
                    ? "panel above all windows, \(pills) pill layers, \(cleared ? "cleared on hide" : "not cleared")"
                    : "no overlay panel visible")
            let bench = OverlayBench.run(overlay)
            record("Overlay render latency", bench.worstKeystroke < 8, bench.summary)
        }

        // 11. Config round trip.
        let text = (try? String(contentsOf: Paths.configFile, encoding: .utf8)) ?? Config().toTOML()
        do {
            let (c, w) = try Config.parse(text)
            let back = try Config.parse(c.toTOML()).0
            record("Config parses", back == c, w.isEmpty ? "no warnings" : "\(w.count) warning(s): \(w.joined(separator: "; "))")
        } catch {
            record("Config parses", false, "\(error)")
        }

        // 12. Things that need Accessibility permission.
        if AX.isTrusted {
            record("Accessibility permission", true, "granted")
            if let cancel = els.first(where: { $0.title == "Cancel" }) {
                let before = f.cancelCount
                f.window.orderFrontRegardless()
                if !Quiet.enabled { NSApp.activate(ignoringOtherApps: true) }
                try? await Task.sleep(nanoseconds: 300_000_000)
                Mouse.click(at: cancel.frame.center)
                try? await Task.sleep(nanoseconds: 300_000_000)
                record("Synthetic mouse click", f.cancelCount == before + 1, "Cancel clicked \(f.cancelCount - before)×")
            }
            let tap = EventTap()
            let ok = tap.install()
            tap.uninstall()
            record("Keyboard event tap", ok, ok ? "installs" : "CGEvent.tapCreate failed")
        } else {
            record("Accessibility permission", nil, "not granted – mouse-click and keyboard-hook checks skipped")
        }
    }
}

extension SelfTest {
    private func key(_ code: UInt16, _ mods: Modifiers = [], down: Bool = true) -> KeyEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        e.flags = EventTap.flags(mods)
        let ns = NSEvent(cgEvent: e)
        return KeyEvent(
            kind: down ? .down : .up, keyCode: code, modifiers: mods, characters: ns?.characters,
            charactersIgnoringModifiers: ns?.charactersIgnoringModifiers, isRepeat: false, cgEvent: e)
    }

    private func press(_ ctl: AppController, _ code: UInt16, _ mods: Modifiers = []) {
        _ = ctl.inject(key(code, mods))
        _ = ctl.inject(key(code, mods, down: false))
    }

    private func type(_ ctl: AppController, _ s: String) {
        for ch in s {
            guard let code = KeyCodes.code(for: String(ch).lowercased()) else { continue }
            press(ctl, code, ch.isUppercase ? .shift : [])
        }
    }

    private func badges(_ ctl: AppController) -> [HintBadge] {
        if case .hints(let b, _, _, _) = ctl.overlay.model.scene { return b }
        return []
    }

    private func settle(_ ms: UInt64 = 120) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    fileprivate func driveModes(_ f: Fixture, targets: [Target], areas: [ScrollArea]) async {
        let ctl = AppController(persist: false)
        ctl.store.config.hints.click = .accessibility  // AXPress works without permission
        ctl.store.config.hints.showHUD = true
        ctl.store.config.hints.alphabet = "asd"  // few keys → multi-character labels to exercise prefixes
        Sound.enabled = false
        defer {
            ctl.stopMode()
            Sound.enabled = true
        }
        func newHintMode() -> HintMode {
            let m = HintMode(kind: .hint, app: ctl, presentation: .badges)
            ctl.install(m, kind: .hint)
            m.load(targets)
            return m
        }

        // Render: every target gets a badge, HUD shows the count.
        _ = newHintMode()
        let b = badges(ctl)
        record(
            "Click mode renders badges", b.count == targets.count && ctl.overlay.model.hud?.detail?.contains("\(targets.count)") == true,
            "\(b.count) badges, HUD: \(ctl.overlay.model.hud?.detail ?? "none")")

        // Search + Return → press.
        var before = f.cancelCount
        type(ctl, "cancel")
        press(ctl, KeyCodes.returnKey)
        await settle()
        record(
            "Click mode: search “cancel” + ⏎", f.cancelCount == before + 1 && ctl.activeMode == nil,
            "Cancel pressed \(f.cancelCount - before)×, mode \(ctl.activeMode == nil ? "closed" : "still open")")

        // Shift + label → auto-click.
        _ = newHintMode()
        let submitFrame = targets.first {
            if case .element(let e) = $0.payload { return e.title == "Submit Order" }
            return false
        }?.frame
        if let label = badges(ctl).first(where: { $0.frame == submitFrame })?.label {
            before = f.submitCount
            type(ctl, label.uppercased())
            await settle()
            record(
                "Click mode: ⇧ + label “\(label.uppercased())”", f.submitCount == before + 1, "Submit pressed \(f.submitCount - before)×")
        } else {
            record("Click mode: ⇧ + label", false, "no badge on Submit Order")
        }

        // Typing a label hides badges that don't share the prefix.
        _ = newHintMode()
        let all = badges(ctl)
        if let two = all.first(where: { $0.label.count > 1 }) {
            type(ctl, String(two.label.first!).uppercased())
            let shown = badges(ctl)
            record(
                "Label prefix narrows badges", shown.allSatisfy { $0.label.hasPrefix(String(two.label.first!)) } && shown.count < all.count,
                "\(all.count) → \(shown.count) badges")
        } else {
            record("Label prefix narrows badges", nil, "all labels are single characters with \(all.count) targets")
        }
        ctl.stopMode()

        // ⌃I filters to inputs; ? shows the tutor; Esc closes.
        _ = newHintMode()
        press(ctl, KeyCodes.code(for: "i")!, .control)
        let inputs = badges(ctl).count
        let expectInputs = targets.filter { $0.item.category == .input }.count
        record("Filter ⌃I (inputs only)", inputs == expectInputs && inputs > 0, "\(inputs) badge(s)")
        press(ctl, KeyCodes.code(for: "i")!, .control)
        press(ctl, KeyCodes.tab)
        press(ctl, KeyCodes.code(for: "/")!, .shift)  // "?"
        var tutorShown = false
        if case .hints(_, _, let t, _) = ctl.overlay.model.scene { tutorShown = t != nil }
        record("Tutor (?)", tutorShown, tutorShown ? "card shown for focused element" : "no tutor card")
        press(ctl, KeyCodes.escape)
        record("Esc closes", ctl.activeMode == nil && ctl.overlay.model.scene == .none, ctl.activeMode == nil ? "closed" : "still open")

        // ⌃Y copies the element's text (clipboard restored afterwards).
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        _ = newHintMode()
        type(ctl, "submit")
        press(ctl, KeyCodes.code(for: "y")!, .control)
        let copied = pb.string(forType: .string)
        pb.clearContents()
        if let saved { pb.setString(saved, forType: .string) }
        record("Copy element text (⌃Y)", copied == "Submit Order", "clipboard: \(copied ?? "empty")")

        // Scroll mode: G → bottom, gg → top via the scroll bar.
        if !areas.isEmpty {
            let sm = ScrollMode(app: ctl)
            ctl.install(sm, kind: .scroll)
            sm.load(areas)
            let y0 = f.scroll.contentView.bounds.origin.y
            type(ctl, "G")
            await settle(200)
            let y1 = f.scroll.contentView.bounds.origin.y
            type(ctl, "gg")
            await settle(200)
            let y2 = f.scroll.contentView.bounds.origin.y
            record("Scroll mode: G / gg", y1 > y0 + 50 && y2 < y1 - 50, "offset \(Int(y0)) → G \(Int(y1)) → gg \(Int(y2))")
            var shown = false
            if case .scroll(let a, _) = ctl.overlay.model.scene { shown = a.count == areas.count }
            record("Scroll mode renders areas", shown, "\(areas.count) area(s) outlined")
            press(ctl, KeyCodes.escape)
        }

        // Grid mode via its global shortcut (works without permission).
        let gridChord = KeyChord.parse(ctl.store.config.shortcuts.grid)!
        _ = ctl.inject(key(gridChord.keyCode, gridChord.modifiers))
        var gridRect: Rect?
        if case .grid(let r, _, _, _) = ctl.overlay.model.scene { gridRect = r }
        record("Grid shortcut opens grid", ctl.activeMode == .grid && gridRect != nil, "mode: \(ctl.activeMode?.rawValue ?? "none")")
        if let full = gridRect {
            type(ctl, "o")
            var r2: Rect?
            if case .grid(let r, _, _, _) = ctl.overlay.model.scene { r2 = r }
            let ok = r2.map { abs($0.width - full.width / 3) < 1 && abs($0.maxX - full.maxX) < 1 && abs($0.y - full.y) < 1 } ?? false
            press(ctl, KeyCodes.delete)
            var r3: Rect?
            if case .grid(let r, _, _, _) = ctl.overlay.model.scene { r3 = r }
            record(
                "Grid narrows (o) and backs out (⌫)", ok && r3 == full,
                "\(full) → \(r2.map(\.description) ?? "?") → \(r3.map(\.description) ?? "?")")
        }
        _ = ctl.inject(key(gridChord.keyCode, gridChord.modifiers))
        record("Same shortcut toggles off", ctl.activeMode == nil, ctl.activeMode == nil ? "closed" : "still open")

        // Two-key grid: labelled cells, two letters pick one, then 3×3 refines.
        ctl.store.config.grid.style = .twokey
        _ = ctl.inject(key(gridChord.keyCode, gridChord.modifiers))
        var cells = 0
        if case .gridLabels(_, let c, _, _) = ctl.overlay.model.scene { cells = c.count }
        type(ctl, "ab")
        var picked: Rect?
        if case .grid(let r, _, _, _) = ctl.overlay.model.scene { picked = r }
        record(
            "Two-key grid: labels → “ab” picks a cell", cells > 100 && picked.map { $0.width < 200 } == true,
            "\(cells) labelled cells → \(picked.map(\.description) ?? "no cell")")
        press(ctl, KeyCodes.escape)
        ctl.store.config.grid.style = .recursive

        // Mouse mode: shortcut opens it, a held key glides the (internal) pointer, esc exits.
        let mouseChord = KeyChord.parse(ctl.store.config.shortcuts.mouse)!
        _ = ctl.inject(key(mouseChord.keyCode, mouseChord.modifiers))
        var ringShown = false
        if case .pointer = ctl.overlay.model.scene { ringShown = true }
        if ctl.activeMode == .mouse, let mm = ctl.currentMode as? MouseMode {
            let x0 = mm.position.x
            // Glide away from the nearer screen edge so clamping can't stop it.
            let scr = Screens.topLeft(Screens.screen(containing: mm.position.x, mm.position.y))
            let right = x0 < scr.midX
            let l = KeyCodes.code(for: right ? "l" : "h")!
            _ = ctl.inject(key(l))
            await settle(150)
            _ = ctl.inject(key(l, down: false))
            let x1 = mm.position.x
            await settle(50)
            let still = mm.position.x == x1
            // No clicks / drags here: with Accessibility granted they'd hit whatever is under the pointer.
            record(
                "Mouse mode: held key glides pointer", ringShown && (right ? x1 > x0 + 10 : x1 < x0 - 10) && still,
                "x \(Int(x0)) → \(Int(x1)) in 150 ms, stops on release: \(still), ring: \(ringShown)")
            press(ctl, KeyCodes.escape)
            record("Mouse mode: esc exits", ctl.activeMode == nil, ctl.activeMode == nil ? "closed" : "still open")
        } else {
            record("Mouse mode opens", false, "mode: \(ctl.activeMode?.rawValue ?? "none")")
        }

        // Repeat last click (no mode): the last click was Cancel via ⏎ in click mode above.
        _ = newHintMode()
        type(ctl, "cancel")
        press(ctl, KeyCodes.returnKey)
        await settle()
        before = f.cancelCount
        ctl.repeatLast()
        await settle()
        record(
            "Repeat last click (repeatLast)", f.cancelCount == before + 1 && ctl.activeMode == nil,
            "Cancel pressed \(f.cancelCount - before)× again")

        // Click & type: "email" "=" ⏎ focuses the field (typing the text needs Accessibility).
        f.window.makeFirstResponder(nil)
        _ = newHintMode()
        type(ctl, "email")
        type(ctl, "=")
        let filling = ctl.overlay.model.hud?.detail?.contains("Type into field") == true
        // Empty text: nothing is typed, so no keystrokes can leak into another app.
        press(ctl, KeyCodes.returnKey)
        await settle(250)
        let editor = f.window.firstResponder as? NSTextView
        let focusedField = (editor?.delegate as? NSTextField)?.placeholderString == "Email address"
        record(
            "Click & type (query = text ⏎)", filling && focusedField && ctl.activeMode == nil,
            "fill HUD: \(filling), field focused: \(focusedField)")

        // gi-style: ⌃I focuses the first input, ⏎ acts on it.
        _ = newHintMode()
        press(ctl, KeyCodes.code(for: "i")!, .control)
        let gi = (ctl.currentMode as? HintMode)?.focusedIsInput == true
        ctl.stopMode()
        record("⌃I focuses the first input", gi, gi ? "first input focused" : "nothing focused")

        // ⌘-chords cancel a mode and pass through.
        _ = newHintMode()
        let passed = !ctl.inject(key(KeyCodes.code(for: "c")!, .command))
        record("⌘-chord cancels & passes through", passed && ctl.activeMode == nil, passed ? "passed through" : "swallowed")
    }
}

extension SelfTest {
    private func waitFor(_ ms: Int = 2000, _ cond: () -> Bool) async -> Bool {
        for _ in 0..<(ms / 5) {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond()
    }

    /// Keyboard-layer edge cases: Esc / ⌘ while scanning, Caps Lock, Return after a click, non-Latin keys.
    fileprivate func inputChecks(targets: [Target]) async {
        let ctl = AppController(persist: false)
        ctl.store.config.hints.click = .accessibility
        Sound.enabled = false
        defer {
            ctl.stopMode()
            Sound.enabled = true
        }
        func ev(_ code: UInt16, _ chars: String, mods: Modifiers = [], caps: Bool = false) -> KeyEvent {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
            e.flags = EventTap.flags(mods).union(caps ? .maskAlphaShift : [])
            return KeyEvent(
                kind: .down, keyCode: code, modifiers: mods, characters: chars, charactersIgnoringModifiers: chars,
                isRepeat: false, cgEvent: e)
        }

        // Esc while "Scanning…" cancels at once.
        ctl.install(HintMode(kind: .hint, app: ctl, presentation: .badges), kind: .hint)
        let escSwallowed = ctl.inject(ev(KeyCodes.escape, "\u{1b}"))
        record(
            "Esc while scanning cancels", ctl.activeMode == nil && escSwallowed, "mode \(ctl.activeMode == nil ? "closed" : "still open")")

        // ⌘-chords while scanning pass through (even ⌘⏎, which is a mode key once labels are up).
        ctl.install(HintMode(kind: .hint, app: ctl, presentation: .badges), kind: .hint)
        let cmdSwallowed = ctl.inject(ev(KeyCodes.returnKey, "\r", mods: .command))
        record(
            "⌘-chord while scanning passes through", !cmdSwallowed && ctl.activeMode == nil,
            "swallowed \(cmdSwallowed), mode \(ctl.activeMode == nil ? "closed" : "open")")

        // Caps Lock: "A" with Caps on and no Shift searches "a" instead of jumping to a label.
        let m = HintMode(kind: .hint, app: ctl, presentation: .badges)
        ctl.install(m, kind: .hint)
        m.load(targets)
        _ = ctl.inject(ev(0, "A", caps: true))
        record("Caps Lock types search, not ⇧+label", m.sessionQuery == "a" && ctl.activeMode == .hint, "query “\(m.sessionQuery)”")

        // Return right after a Pounce click is the user's own key: never turned into a double-click.
        ctl.stopMode()
        ctl.noteClick(at: .zero)
        let retSwallowed = ctl.inject(ev(KeyCodes.returnKey, "\r"))
        record("⏎ after a click passes through", !retSwallowed, "swallowed \(retSwallowed)")

        // Non-Latin layout: Cyrillic "ф" on the A key is a label key "a" (via the ASCII-capable layout).
        if let ascii = KeyboardLayout.shared.asciiCharacter(keyCode: 0, shift: false), ascii.isLetter {
            let e = ev(0, "ф")
            let ok =
                e.input(for: .labels) == .char(Character(ascii.lowercased())) && e.input(for: .search) == .char("ф")
                && ev(0, "Ф", mods: .shift).input(for: .search) == .char(Character(ascii.uppercased()))
            record("Non-Latin keys map to labels", ok, "ф → \(ascii) for labels, ф for search")
        } else {
            record("Non-Latin keys map to labels", nil, "no ASCII-capable layout")
        }
    }

    fileprivate func cacheChecks(_ f: Fixture, win: AXUIElement, winFrame: Rect?) async {
        let ctl = AppController(persist: false)
        ctl.store.config.hints.click = .accessibility
        ctl.store.config.hints.alphabet = "asd"
        Sound.enabled = false
        defer {
            ctl.stopMode()
            Sound.enabled = true
        }
        let scope = HintScope(pid: getpid(), mode: .fast, menubar: false, root: win)
        func open() -> HintMode {
            let m = HintMode(kind: .hint, app: ctl, presentation: .badges)
            ctl.install(m, kind: .hint)
            ctl.loadHints(m, scope: scope, bundle: "selftest", window: win, frame: winFrame, sources: [.window])
            return m
        }
        func fmt(_ v: Double?) -> String { v.map { String(format: "%.2f ms", $0) } ?? "–" }

        // Cold: nothing cached → HUD first, labels when the scan lands.
        ctl.cache.clear()
        let cold = open()
        let coldSync = !badges(ctl).isEmpty
        let coldOK = await waitFor { cold.firstLabelsMs != nil }
        let coldMs = cold.firstLabelsMs
        ctl.stopMode()
        record(
            "Uncached hint open waits for scan", !coldSync && coldOK,
            "first labels after \(fmt(coldMs)) (scan \(fmt(ctl.cache.entries.last?.scan.ms)))")

        // The UI changes after the cache was filled; the cached open still shows the old scan instantly.
        let late = NSButton(title: "Late Arrival", target: nil, action: nil)
        late.frame = CGRect(x: 290, y: 270, width: 110, height: 30)
        f.window.contentView?.addSubview(late)
        defer { late.removeFromSuperview() }
        let scansBefore = ctl.cache.scansRun
        let warm = open()
        let warmBadges = badges(ctl).count
        let warmMs = warm.firstLabelsMs
        let shown = warm.labelsByKey
        record(
            "Cached hint open shows labels synchronously", warmBadges > 0 && warmMs != nil && !warm.verified,
            "\(warmBadges) badges in \(fmt(warmMs)) (uncached \(fmt(coldMs)))")

        // Type before the rescan lands; the rescan must keep the query and the labels.
        type(ctl, "canc")
        let queryLabels = warm.labelsByKey
        let reconciled = await waitFor { warm.reconciledMs != nil }
        let afterQuery = warm.labelsByKey
        let query = warm.sessionQuery
        let keptQuery = query == "canc" && ctl.activeMode == .hint
        press(ctl, KeyCodes.code(for: "u")!, .control)  // clear the query → full set again
        let full = warm.labelsByKey
        let stable = shown.allSatisfy { full[$0.key] == $0.value }
        let grew = full.count == shown.count + 1
        record(
            "Rescan reconciles keeping labels",
            reconciled && keptQuery && afterQuery == queryLabels && stable && grew && ctl.cache.scansRun == scansBefore + 1,
            "reconciled at \(fmt(warm.reconciledMs)); query “\(query)” kept: \(keptQuery); \(shown.count) → \(full.count) labels, stable: \(stable)"
        )
        ctl.stopMode()

        // A hard change (scroll / click / resize) makes the cache unusable until rescanned.
        ctl.cache.noteChange(pid: getpid(), hard: true)
        let after = open()
        let hidden = badges(ctl).isEmpty
        _ = await waitFor { after.firstLabelsMs != nil }
        record(
            "Hard change hides stale cache", hidden && after.verified,
            hidden ? "no stale labels; fresh in \(fmt(after.firstLabelsMs))" : "stale labels shown")
        ctl.stopMode()

        // Stale frames are re-read before clicking.
        let els: [ScannedElement] = await Task.detached {
            Scanner.scan(roots: [(win, win.frame)], options: Scanner.Options(), source: .window)
        }.value
        if let cancel = els.first(where: { $0.title == "Cancel" }) {
            var stale = cancel.frame
            stale.x += 300
            let p = HintMode.liveCenter(stale, cancel.element, trustCached: false)
            let ok = p.map { cancel.frame.contains(x: $0.x, y: $0.y) } ?? false
            record(
                "Stale frame re-validated before click", ok,
                ok ? "click moved to the element's current frame" : "would click \(p.map { "\($0)" } ?? "nothing")")
        }

        // AX notifications reach the observer (own process may not post them: skip if silent).
        var names: [String] = []
        let obs = AppObserver(pid: getpid()) { names.append($0) }
        f.checkbox.title = "Remember me later"
        f.window.contentView?.addSubview(NSButton(title: "Observed", target: nil, action: nil))
        _ = await waitFor(400) { !names.isEmpty }
        obs?.invalidate()
        f.checkbox.title = "Remember me"
        f.window.contentView?.subviews.last.map { $0.removeFromSuperview() }
        record(
            "AX observer sees UI changes", names.isEmpty ? nil : true,
            names.isEmpty
                ? "no notifications for our own process (observer \(obs == nil ? "unavailable" : "installed"))"
                : Set(names).sorted().joined(separator: ", "))
    }
}

/// A window full of standard controls to scan.
@MainActor
final class Fixture: NSObject {
    nonisolated static let title = "Pounce Self-Test Fixture"
    let window: NSWindow
    let checkbox: NSButton
    let scroll: NSScrollView
    var submitCount = 0
    var cancelCount = 0

    override init() {
        window = Quiet.window(contentRect: CGRect(x: 0, y: 0, width: 420, height: 320), styleMask: [.titled])
        window.title = Self.title
        window.isReleasedWhenClosed = false
        checkbox = NSButton(checkboxWithTitle: "Remember me", target: nil, action: nil)
        scroll = NSScrollView(frame: CGRect(x: 20, y: 20, width: 380, height: 120))
        super.init()

        let v = window.contentView!
        let submit = NSButton(title: "Submit Order", target: self, action: #selector(submit(_:)))
        submit.frame = CGRect(x: 20, y: 270, width: 140, height: 30)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.frame = CGRect(x: 170, y: 270, width: 100, height: 30)
        checkbox.frame = CGRect(x: 20, y: 240, width: 200, height: 22)
        let field = NSTextField(frame: CGRect(x: 20, y: 205, width: 260, height: 24))
        field.placeholderString = "Email address"
        let popup = NSPopUpButton(frame: CGRect(x: 20, y: 160, width: 200, height: 28))
        popup.addItems(withTitles: ["Small", "Medium", "Large"])

        let doc = FlippedView(frame: CGRect(x: 0, y: 0, width: 360, height: 900))
        for i in 0..<8 {
            let t = NSTextField(labelWithString: "Row \(i + 1) of scrollable content")
            t.frame = CGRect(x: 10, y: 10 + i * 30, width: 300, height: 20)
            doc.addSubview(t)
        }
        let hidden = NSButton(title: "Hidden Below", target: nil, action: nil)
        hidden.frame = CGRect(x: 10, y: 850, width: 140, height: 30)
        doc.addSubview(hidden)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        [submit, cancel, checkbox, field, popup, scroll].forEach(v.addSubview)

        // A menu to find via Menu Search.
        if NSApp.mainMenu == nil { NSApp.mainMenu = NSMenu() }
        let top = NSMenuItem(title: "Pounce Test", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Pounce Test")
        sub.addItem(withTitle: "Self-Test Action", action: nil, keyEquivalent: "")
        top.submenu = sub
        if NSApp.mainMenu?.item(withTitle: "Pounce Test") == nil { NSApp.mainMenu?.addItem(top) }

        window.center()
        window.orderFrontRegardless()
    }

    @objc func submit(_: Any) { submitCount += 1 }
    @objc func cancel(_: Any) { cancelCount += 1 }

    static func ocrImage(_ text: String) -> CGImage {
        let size = CGSize(width: 600, height: 160)
        let img = NSImage(size: size, flipped: false) { r in
            NSColor.white.setFill()
            r.fill()
            (text as NSString).draw(
                at: CGPoint(x: 30, y: 55),
                withAttributes: [.font: NSFont.systemFont(ofSize: 44, weight: .semibold), .foregroundColor: NSColor.black])
            return true
        }
        var rect = CGRect(origin: .zero, size: size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
    }
}

struct SelfTestView: View {
    @ObservedObject var runner: SelfTest
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Self-Test").font(.title2.weight(.bold))
                Spacer()
                if runner.running {
                    ProgressView().controlSize(.small)
                } else {
                    let f = runner.failed
                    StatusPill(ok: f == 0, okText: "All passed", badText: "\(f) failed")
                    Button("Run Again") { runner.run() }
                }
            }
            .padding(20)
            List(runner.results) { r in
                HStack(alignment: .top, spacing: 10) {
                    Image(
                        systemName: r.status == .pass
                            ? "checkmark.circle.fill" : r.status == .fail ? "xmark.circle.fill" : "minus.circle.fill"
                    )
                    .foregroundStyle(r.status == .pass ? .green : r.status == .fail ? .red : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name).font(.system(size: 13, weight: .medium))
                        Text(r.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Scanner engine checks (streaming, parallel lanes, big tables)

extension SelfTest {
    fileprivate func scannerChecks(win: AXUIElement, reference els: [ScannedElement]) async {
        let sig: ([ScannedElement]) -> Set<String> = { Set($0.map { "\($0.role)|\($0.title ?? "")|\($0.frame)" }) }
        let (batches, final): ([[ScannedElement]], [ScannedElement]) = await Task.detached {
            var batches: [[ScannedElement]] = []
            let final = Scanner.scan(roots: [(win, win.frame)], options: Scanner.Options(), source: .window) { batches.append($0) }
            return (batches, final)
        }.value
        let streamed = batches.flatMap { $0 }
        record(
            "Streaming scan", !batches.isEmpty && sig(streamed) == sig(final) && sig(final) == sig(els),
            "\(batches.count) batch(es), \(streamed.count) streamed, \(final.count) final")

        let laned: [ScannedElement] = await Task.detached {
            var o = Scanner.Options()
            o.testLanes = 3
            return Scanner.scan(roots: [(win, win.frame)], options: o, source: .window)
        }.value
        record(
            "Parallel lanes scan", laned.map(\.frame) == els.map(\.frame),
            "\(laned.count) elements, same order: \(laned.map(\.frame) == els.map(\.frame))")

        // A 5000-row table must cost O(visible rows), not O(rows).
        let tw = Quiet.window(contentRect: CGRect(x: 60, y: 60, width: 360, height: 300), styleMask: [.titled])
        tw.title = "Pounce Self-Test Table"
        tw.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: tw.contentView!.bounds)
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        let src = SelfTestTableSource()
        table.dataSource = src
        table.delegate = src
        scroll.documentView = table
        tw.contentView!.addSubview(scroll)
        tw.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let (n, ms): (Int, Double) = await Task.detached {
            guard let w = AXUIElement.app(getpid()).elements("AXWindows").first(where: { $0.string("AXTitle") == "Pounce Self-Test Table" })
            else { return (-1, 0) }
            let t0 = Clock.now
            let found = Scanner.scan(roots: [(w, w.frame)], options: Scanner.Options(), source: .window)
            return (found.filter { $0.title?.hasPrefix("Open ") == true }.count, Double(Clock.now - t0) / 1e6)
        }.value
        tw.close()
        _ = src
        record("Big table: visible rows only", n > 0 && n < 40 && ms < 150, String(format: "%d row buttons in %.1f ms (5000 rows)", n, ms))
    }
}

private final class SelfTestTableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { 5000 }
    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        NSButton(title: "Open \(row)", target: nil, action: nil)
    }
}
