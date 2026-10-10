import AppKit
import Combine
import PounceCore

/// Central coordinator: owns config, the event tap, the overlay and the active mode.
@MainActor
final class AppController: ObservableObject {
    let store: ConfigStore
    let overlay = OverlayController()
    let usage = UsageKeeper()
    /// Background pre-scans so modes open with labels already in place.
    let cache = ScanCache()
    private let tap = EventTap()
    private let matcher = HotkeyMatcher()

    @Published private(set) var activeMode: ModeKind?
    @Published private(set) var tapInstalled = false
    @Published var paused = false
    /// Set by the shortcut recorder so global shortcuts don't fire while recording.
    var recordingShortcut = false

    private var mode: Mode?
    private(set) var frontApp: NSRunningApplication?
    var lastAction: (key: String, action: HintAction)?
    /// The last click from any mode, replayed by `repeatLast()`.
    struct Activation {
        var action: HintAction
        var point: CGPoint
        var element: AXUIElement?
        var frame: Rect?
        var dragFrom: CGPoint?
    }
    var lastActivation: Activation?
    /// After-click "scroll": the point whose scroll area the next scroll mode selects.
    var scrollFocus: CGPoint?
    private var lastClick: (point: CGPoint, at: Date)?
    private var trustTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var hyperApplied: Bool?
    private var mouseMonitor: Any?
    private var modeStarted = Date.distantPast
    /// Set by `startHint(scope:)` for the duration of `start(.hint)`.
    private var hintScopeOverride: HintScopeKind?

    /// false for throwaway controllers (self-test, snapshots): no file writes, no key remaps.
    private let live: Bool

    init(persist: Bool = true) {
        live = persist
        store = ConfigStore(persist: persist)
        store.$config.sink { [weak self] c in
            DispatchQueue.main.async { self?.apply(c) }
        }.store(in: &cancellables)
        tap.handler = { [weak self] e in self?.handle(e) ?? false }
        cache.scopeFor = { [weak self] app in
            guard let cfg = self?.store.config else { return nil }
            let sources = Set(cfg.hints.sources)
            guard sources.contains(.window) || sources.contains(.menubar) else { return nil }
            return HintScope(
                pid: app.processIdentifier, mode: cfg.scanMode(for: app.bundleIdentifier),
                menubar: sources.contains(.menubar), window: sources.contains(.window))
        }
        cache.sourcesNeedGlobals = { [weak self] in
            let s = self?.store.config.hints.sources ?? []
            return (s.contains(.extras), s.contains(.dock))
        }
        tap.attach(matcher, activeMode: $activeMode)
    }

    func startup() {
        apply(store.config)
        ensureTap()
        IPC.listen { [weak self] cmd in self?.run(command: cmd) }
        if live {
            Updater.shared.scheduleAutomaticChecks()
            cache.startLive { [weak self] id in self?.store.config.isIgnored(id) ?? true }
            MenuExtras.shared.prewarm()
        }
        // A real mouse click or switching apps ends the current mode.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // Our own synthetic clicks (mouse mode) don't count.
            let synthetic = event.cgEvent?.getIntegerValueField(.eventSourceUserData) == EventTap.syntheticMarker
            MainActor.assumeIsolated {
                guard let self, self.mode != nil, !synthetic, Date().timeIntervalSince(self.modeStarted) > 0.2 else { return }
                self.stopMode()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let m = self.activeMode, m != .windows, m != .grid, m != .mouse,
                    let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    app.processIdentifier != self.frontApp?.processIdentifier, app.processIdentifier != getpid()
                else { return }
                self.stopMode()
            }
        }
    }

    func shutdown() {
        usage.flush()
        if hyperApplied == true { HyperKeyRemap.setEnabled(false) }
    }

    private func apply(_ c: Config) {
        matcher.update(c.shortcuts)
        matcher.hyperEnabled = c.general.hyperKey
        matcher.capsLockEscape = c.general.capsLockEscape
        Sound.enabled = c.general.sounds
        overlay.model.style = OverlayStyle(theme: c.hints.theme, size: c.hints.size)
        cache.setEnabled(c.general.prewarm)
        overlay.prewarm(alphabet: c.hints.alphabet)
        if live, hyperApplied != c.general.hyperKey {
            // On first apply this also clears a remap left behind by a crash.
            HyperKeyRemap.setEnabled(c.general.hyperKey)
            hyperApplied = c.general.hyperKey
        }
    }

    /// Installs the event tap now, or polls until Accessibility is granted.
    func ensureTap() {
        if tap.install() {
            tapInstalled = true
            trustTimer?.invalidate()
            trustTimer = nil
            return
        }
        tapInstalled = false
        guard trustTimer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AX.isTrusted else { return }
                self.ensureTap()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        trustTimer = t
    }

    // MARK: - Keyboard routing

    private func handle(_ e: KeyEvent) -> Bool {
        if e.kind == .down, !e.isRepeat {
            log.debug("key \(e.keyCode) mods \(e.modifiers.rawValue) mode \(self.activeMode.map { "\($0)" } ?? "-", privacy: .public)")
        }
        let (swallowHyper, mods) = matcher.applyHyper(e)
        if swallowHyper { return true }
        if recordingShortcut { return false }

        if let mode {
            if let k = matcher.match(e, modifiers: mods) {
                if k == mode.kind { stopMode() } else { start(k) }
                return true
            }
            let purpose = Self.keyPurpose(mode.kind)
            switch e.kind {
            case .flags: return false
            case .up:
                mode.keyUp(e, input: e.input(for: purpose))
                return true
            case .down:
                let input = e.input(for: purpose)
                // ⌘-chords (⌘Tab, ⌘Q…) cancel the mode and go through to the system.
                if input == nil && mods.contains(.command) {
                    stopMode()
                    return false
                }
                return mode.keyDown(e, input: input)
            }
        }

        // Outside a mode, unbound keys always pass through (no Return-after-click double-click hijack:
        // double-click is ⌃⏎ inside the mode).
        guard !paused, let k = matcher.match(e, modifiers: mods) else { return false }
        if store.config.isIgnored(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) { return false }
        start(k)
        return true
    }

    /// How a mode wants letters translated (see `KeyText`): hint-style modes search with real
    /// characters; the menu palette is pure text; scroll, grid and other key-driven modes want physical keys.
    static func keyPurpose(_ k: ModeKind) -> KeyText.Purpose {
        switch k {
        case .menu: .literal
        case .hint, .windows, .text: .search
        default: .labels
        }
    }

    // MARK: - Modes

    func toggle(_ k: ModeKind) {
        if activeMode == k { stopMode() } else { start(k) }
    }

    func start(_ k: ModeKind) {
        log.debug(
            "start \("\(k)", privacy: .public) front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public)")
        stopMode()
        if k == .repeatLast {
            repeatLast()
            return
        }
        guard AX.isTrusted || k == .grid || k == .mouse else {
            overlay.model.flash("Pounce needs Accessibility permission")
            Permissions.openAccessibilitySettings()
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        frontApp = front
        let pid = front?.processIdentifier ?? getpid()
        let (win, winFrame) = focusedWindow(pid)
        overlay.model.activeScreen = activeScreen(winFrame)
        activeMode = k
        modeStarted = Date()
        let cfg = store.config
        let bundle = front?.bundleIdentifier

        switch k {
        case .hint:
            let m = HintMode(kind: .hint, app: self, presentation: .badges)
            mode = m
            let sources = Set(cfg.hints.sources)
            let hintScope = hintScopeOverride ?? cfg.hints.scope
            if hintScope != .window {
                loadAllWindows(m, scope: hintScope, front: front, sources: sources)
                break
            }
            let firstTime = front.map(AppSupport.prepare) ?? false
            let scope = HintScope(
                pid: pid, mode: cfg.scanMode(for: bundle), menubar: sources.contains(.menubar), window: sources.contains(.window))
            loadHints(m, scope: scope, bundle: bundle, window: win, frame: winFrame, sources: sources, delay: firstTime ? 0.35 : 0)
        case .windows:
            let m = HintMode(kind: .windows, app: self, presentation: .windows)
            mode = m
            if let ws = cache.cachedWindows() { m.load(Targets.windows(ws), verified: false) }
            cache.scanWindows { ws in m.load(Targets.windows(ws)) }
        case .menu:
            let m = HintMode(kind: .menu, app: self, presentation: .palette)
            mode = m
            if let ms = cache.cachedMenus(pid: pid) { m.load(Targets.menus(ms, bundleID: bundle), verified: false) }
            cache.scanMenus(pid: pid) { ms in m.load(Targets.menus(ms, bundleID: bundle)) }
        case .text:
            guard Permissions.screenRecording else {
                activeMode = nil
                overlay.model.flash("Text mode needs Screen Recording permission")
                Permissions.requestScreenRecording()
                return
            }
            let m = HintMode(kind: .text, app: self, presentation: .badges)
            mode = m
            Task {
                do {
                    let boxes = try await TextScanner.scan(pid: pid, windowFrame: winFrame)
                    m.load(Targets.text(boxes))
                } catch {
                    guard self.mode === m else { return }
                    self.stopMode()
                    self.overlay.model.flash(error.localizedDescription)
                    Sound.playWarn()
                    if case TextScanError.noPermission = error { Permissions.requestScreenRecording() }
                }
            }
        case .scroll:
            let m = ScrollMode(app: self, near: scrollFocus)
            scrollFocus = nil
            mode = m
            Task.detached {
                let areas = ScrollScanner.scan(pid: pid)
                await MainActor.run { m.load(areas) }
            }
        case .grid:
            mode = GridMode(app: self)
        case .mouse:
            mode = MouseMode(app: self)
        case .repeatLast:
            break
        }
    }

    /// Click mode over the focused window (`.window`, same as `start(.hint)`), every visible
    /// window on the active screen (`.screen`), or on all screens (`.all`).
    func startHint(scope: HintScopeKind) {
        hintScopeOverride = scope
        defer { hintScopeOverride = nil }
        start(.hint)
    }

    /// All-windows click mode: scans every visible window (WindowVisibility rule) of every regular
    /// app in parallel, drops elements hidden behind windows in front, and labels them together.
    /// Clicking an element of a background window activates that window first.
    private func loadAllWindows(_ m: HintMode, scope: HintScopeKind, front: NSRunningApplication?, sources: Set<HintSource>) {
        let cfg = store.config
        let screenRect: Rect? = scope == .screen ? overlay.model.activeScreen : nil
        let frontPid = front?.processIdentifier
        let menubar = sources.contains(.menubar), ex = sources.contains(.extras), dk = sources.contains(.dock)
        var globals = cache.enabled ? cache.globals(extras: ex, dock: dk) : nil
        var scanned: [Target]?
        func finish() {
            guard let t = scanned, let g = globals else { return }
            m.load(t + Targets.elements(g, bundleID: front?.bundleIdentifier, windowOrigin: Point(x: 0, y: 0)))
        }
        if globals == nil || ((ex || dk) && cache.globalsStale) {
            let wait = globals == nil
            cache.refreshGlobals { [weak self] in
                guard wait else { return }
                globals = self?.cache.globals(extras: ex, dock: dk) ?? []
                finish()
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var wins = WindowScanner.scan(includeHidden: false).filter { $0.element != nil }
            if let sr = screenRect {
                wins = wins.filter { w in
                    let v = w.visibleFrame.intersection(sr)
                    return v.width >= WindowVisibility.minSide && v.height >= WindowVisibility.minSide
                }
            }
            // Fully covered by a window in front: nothing to label, don't scan.
            wins = wins.enumerated().filter { i, w in
                let f = w.visibleFrame
                return !wins[..<i].contains { a in a.visibleFrame.intersection(f) == f }
            }.map(\.1)
            var first = false
            for a in Set(wins.map(\.app)) where AppSupport.prepare(a) { first = true }
            if first { Thread.sleep(forTimeInterval: 0.35) }  // Electron/Chromium build their AX tree on demand
            var results = [[ScannedElement]](repeating: [], count: wins.count)
            let lock = NSLock()
            var frontMenusAdded = false
            DispatchQueue.concurrentPerform(iterations: wins.count) { i in
                let w = wins[i]
                var opts = Scanner.Options()
                opts.mode = cfg.scanMode(for: w.app.bundleIdentifier)
                opts.deadline = 1.0
                var clip = w.visibleFrame
                if let sr = screenRect { clip = clip.intersection(sr) }
                var roots: [(AXUIElement, Rect?)] = [(w.element!, clip)]
                lock.lock()
                let addMenus = w.app.processIdentifier == frontPid && !frontMenusAdded
                if addMenus { frontMenusAdded = true }
                lock.unlock()
                if addMenus, let pid = frontPid {
                    // Open context menus of the front app, as in single-window mode.
                    roots = Scanner.appRoots(pid: pid).filter { $0.1 == nil } + roots
                }
                let els = Scanner.scan(roots: roots, options: opts, source: .window)
                lock.lock()
                results[i] = els
                lock.unlock()
            }
            let bar = menubar ? frontPid.map { Scanner.scanMenuBar(pid: $0) } ?? [] : []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var t: [Target] = []
                    for (i, w) in wins.enumerated() {
                        let above = wins[..<i].map(\.visibleFrame)
                        let els = results[i].filter { e in !above.contains { $0.contains(x: e.frame.midX, y: e.frame.midY) } }
                        for var x in Targets.elements(
                            els, bundleID: w.app.bundleIdentifier, windowOrigin: Point(x: w.frame.x, y: w.frame.y))
                        {
                            x.owner = w
                            t.append(x)
                        }
                    }
                    t += Targets.elements(bar, bundleID: front?.bundleIdentifier, windowOrigin: Point(x: 0, y: 0))
                    scanned = t
                    finish()
                }
            }
        }
    }

    func stopMode(keepToast: Bool = false, caller: String = #function, line: Int = #line) {
        if mode != nil { log.debug("stop from \(caller, privacy: .public):\(line)") }
        mode?.stop()
        mode = nil
        activeMode = nil
        let t = overlay.model.toast
        overlay.hideNow()
        if keepToast || t != nil { overlay.model.toast = t }
    }

    /// Installs a mode directly (self-test drives modes without a frontmost app).
    func install(_ m: Mode, kind: ModeKind) {
        stopMode()
        mode = m
        activeMode = kind
    }

    /// The active mode object (self-test).
    var currentMode: Mode? { mode }

    /// Feeds a key event through the same routing as the event tap (self-test).
    func inject(_ e: KeyEvent) -> Bool { handle(e) }

    func noteClick(at p: CGPoint) {
        lastClick = (p, Date())
        if let pid = frontApp?.processIdentifier { cache.noteChange(pid: pid, hard: true) }
    }

    /// Click mode: shows cached labels on this runloop turn when the window was pre-scanned,
    /// then reconciles with a fresh scan (or shows that scan's labels if nothing was cached).
    func loadHints(
        _ m: HintMode, scope: HintScope, bundle: String?, window: AXUIElement?, frame: Rect?, sources: Set<HintSource>,
        delay: TimeInterval = 0
    ) {
        let ex = sources.contains(.extras), dk = sources.contains(.dock)
        func targets(_ s: WindowScan, globals: [ScannedElement], frame now: Rect?) -> [Target] {
            let origin = Point(x: s.windowFrame?.x ?? 0, y: s.windowFrame?.y ?? 0)
            var t = Targets.elements(s.all, bundleID: bundle, windowOrigin: origin)
            // The window moved since the scan: shift its elements along (keys stay window-relative).
            if let a = s.windowFrame, let b = now, a.x != b.x || a.y != b.y {
                for i in t.indices {
                    guard case .element(let e) = t[i].payload, e.source == .window, var f = t[i].frame else { continue }
                    f.x += b.x - a.x
                    f.y += b.y - a.y
                    t[i].frame = f
                }
            }
            return t + Targets.elements(globals, bundleID: bundle, windowOrigin: Point(x: 0, y: 0))
        }
        let cachedGlobals = cache.enabled ? cache.globals(extras: ex, dock: dk) : nil
        if delay == 0, let g = cachedGlobals,
            let e = cache.entry(pid: scope.pid, window: window, frame: frame, mode: scope.mode, menubar: scope.menubar)
        {
            m.load(targets(e.scan, globals: g, frame: frame), verified: false)
        }
        var scan: WindowScan?
        var globals = cachedGlobals
        func finish() {
            guard let s = scan, let g = globals else { return }
            m.load(targets(s, globals: g, frame: s.windowFrame))
        }
        if globals == nil || ((ex || dk) && cache.globalsStale) {
            let wait = globals == nil
            cache.refreshGlobals { [weak self] in
                guard wait else { return }
                globals = self?.cache.globals(extras: ex, dock: dk) ?? []
                finish()
            }
        }
        // Slow scan, nothing cached: show what's been found so far, reconcile when done.
        let early: ([ScannedElement]) -> Void = { [weak m] els in
            guard let m, !m.hasSession else { return }
            var t = Targets.elements(els, bundleID: bundle, windowOrigin: Point(x: frame?.x ?? 0, y: frame?.y ?? 0))
            if let g = globals { t += Targets.elements(g, bundleID: bundle, windowOrigin: Point(x: 0, y: 0)) }
            m.load(t, verified: false)
        }
        cache.scan(scope, delay: delay, partial: early) { s in
            scan = s
            finish()
        }
    }

    /// Click chain: re-enter the mode once the UI has reacted to the click.
    /// `at`: for scroll mode, select the scroll area containing this point.
    func chain(_ k: ModeKind, at p: CGPoint? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.mode == nil else { return }
            self.scrollFocus = p
            self.start(k)
        }
    }

    /// Repeats the last click (any mode) without opening a mode: on the same element if it's
    /// still on screen (re-read via AX), else at the same point.
    func repeatLast() {
        guard let a = lastActivation else {
            overlay.model.flash("Nothing to repeat yet")
            Sound.playWarn()
            return
        }
        var p = a.point
        var element: AXUIElement?
        if let el = a.element, let f = a.frame, let live = HintMode.liveCenter(f, el, trustCached: false) {
            p = live
            element = el
        }
        Sound.playClick()
        overlay.pulse(at: p)
        if case .drag = a.action, let from = a.dragFrom {
            Mouse.drag(from: from, to: p)
            return
        }
        let cfg = store.config.hints
        Clicker.perform(a.action, at: p, element: element, method: element == nil ? .mouse : cfg.click, restoreCursor: cfg.restoreCursor)
        noteClick(at: p)
    }

    /// The app's focused (else main) window and its frame: one lookup shared by everything at mode start.
    private func focusedWindow(_ pid: pid_t) -> (AXUIElement?, Rect?) {
        let app = AXUIElement.app(pid)
        app.setTimeout(0.5)
        let w = app.element("AXFocusedWindow") ?? app.element("AXMainWindow")
        return (w, w?.frame)
    }

    private func activeScreen(_ windowFrame: Rect?) -> Rect {
        if let f = windowFrame { return Screens.topLeft(Screens.screen(for: f)) }
        let m = Screens.mouse
        return Screens.topLeft(Screens.screen(containing: m.x, m.y))
    }

    // MARK: - Commands (CLI / URL scheme / menu)

    /// `reply` is set for CLI request/response commands (status, doctor, login, reload, overlayshot…);
    /// nil from the URL scheme / menus. Commands that don't answer just ignore it.
    func run(command raw: String, reply: IPC.Reply? = nil) {
        let cmd = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if let k = ModeKind(rawValue: cmd) ?? (cmd == "click" ? .hint : cmd == "window" ? .windows : nil) {
            // Let the caller's terminal/launcher give focus back before scanning.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.toggle(k) }
            reply?("ok\n")
            return
        }
        if let scope = ["hint-all": HintScopeKind.all, "hint-screen": .screen, "hint-window": .window][cmd] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.startHint(scope: scope) }
            reply?("ok\n")
            return
        }
        if cmd.hasPrefix("login") {
            let arg = cmd.dropFirst("login".count).trimmingCharacters(in: .whitespaces)
            var msg = ""
            if arg == "on" || arg == "off" {
                do { try LoginItem.set(arg == "on") } catch { msg = "error: \(error.localizedDescription)\n" }
            }
            reply?(msg + "open at login: \(Self.loginStatus)\n")
            return
        }
        if cmd == "overlayshot" {
            let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("pounce-overlayshot-\(UUID().uuidString.prefix(8))")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var paths = overlay.capture(to: dir)
            if case .hints(let badges, _, _, _) = overlay.model.scene {
                paths += badges.map { "\($0.label) \(Int($0.frame.x)),\(Int($0.frame.y)) \(Int($0.frame.width))×\(Int($0.frame.height))" }
            }
            let px = overlay.verifyPills()
            paths.append("pixels: \(px.matched)/\(px.checked) pills show their own label")
            paths.append("activeScreen \(overlay.model.activeScreen)")
            reply?(paths.joined(separator: "\n") + "\n")
            return
        }
        if cmd == "keytest" {
            // Post ⌘⇧Space through the whole input pipeline, as if typed.
            let src = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let ev = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(KeyCodes.space), keyDown: down)
                ev?.flags = [.maskCommand, .maskShift]
                ev?.post(tap: .cghidEventTap)
            }
            return
        }
        if cmd == "doctor" || cmd.hasPrefix("doctor ") {
            // Bundle ids are case-insensitive for matching; keep the user's spelling for messages.
            let target = raw.trimmingCharacters(in: .whitespaces).dropFirst("doctor".count).trimmingCharacters(in: .whitespaces)
            let state =
                "tap installed: \(tapInstalled), paused: \(paused), mode: \(activeMode.map { "\($0)" } ?? "none"), "
                + "pills on screen: \(overlay.visiblePills), hint shortcut: \(store.config.shortcuts.hint), front: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")"
            Doctor.run(target: target.isEmpty ? nil : target, state: state) { reply?($0) }
            return
        }
        switch cmd {
        case "status": reply?(statusReport())
        case "settings", "preferences": WindowManager.shared.showSettings(self)
        case "onboarding", "welcome": WindowManager.shared.showOnboarding(self)
        case "cheatsheet", "cheat", "keys": WindowManager.shared.showCheatSheet(self)
        case "selftest": WindowManager.shared.showSelfTest(self)
        case "reload":
            store.load()
            reply?(store.error.map { "error: \($0) — using last good config\n" } ?? "reloaded \(Paths.configFile.path)\n")
            return
        case "pause", "resume", "toggle":
            // main.swift persists `paused` and posts .pouncePausedChanged for the menu bar icon.
            paused = cmd == "toggle" ? !paused : cmd == "pause"
            overlay.model.flash(paused ? "Pounce paused" : "Pounce resumed")
            reply?(paused ? "paused\n" : "resumed\n")
            return
        case "repeat": repeatLast()
        case "quit":
            reply?("quitting\n")
            NSApp.terminate(nil)
        default:
            reply?("error: unknown command “\(raw)”\n")
            if reply == nil { overlay.model.flash("Unknown command “\(raw)”") }
            return
        }
        if cmd != "status" { reply?("ok\n") }
    }

    static var loginStatus: String {
        LoginItem.managedByLaunchd
            ? "managed by launchd"
            : LoginItem.needsApproval ? "needs approval in System Settings › Login Items" : LoginItem.isEnabled ? "on" : "off"
    }

    /// `pounce status`: one "key: value" per line.
    func statusReport() -> String {
        let cfg = Paths.configFile
        let exists = FileManager.default.fileExists(atPath: cfg.path)
        let validity =
            store.error.map { "error: \($0)" }
            ?? (!exists ? "no file (defaults)" : store.warnings.isEmpty ? "valid" : "\(store.warnings.count) warning(s)")
        let lines: [(String, String)] = [
            ("running", "yes (pid \(getpid()))"),
            ("version", appVersionWithCommit),
            ("accessibility", AX.isTrusted ? "trusted" : "NOT trusted"),
            ("screen recording", Permissions.screenRecording ? "granted" : "not granted (text mode unavailable)"),
            ("event tap", tapInstalled ? "installed" : "not installed"),
            ("paused", paused ? "yes" : "no"),
            ("secure input", SecureInput.isEnabled ? "ON (another app hides keystrokes; shortcuts won't fire)" : "off"),
            ("open at login", Self.loginStatus),
            ("config", "\(cfg.path) (\(validity))"),
            ("preset", store.config.general.preset.rawValue),
            ("mode", activeMode.map { "\($0)" } ?? "none"),
        ]
        return lines.map { "\($0.0): \($0.1)" }.joined(separator: "\n") + "\n"
    }
}
