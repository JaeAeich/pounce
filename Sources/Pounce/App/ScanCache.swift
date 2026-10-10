import AppKit
import ApplicationServices
import PounceCore

/// What a click-mode window scan covers.
struct HintScope: @unchecked Sendable {
    var pid: pid_t
    var mode: ScanMode
    var menubar: Bool
    var window = true
    /// Scan exactly this window instead of the app's focused window (self-test).
    var root: AXUIElement? = nil
}

/// One finished scan of an app's focused window (+ its menu bar).
struct WindowScan: @unchecked Sendable {
    let pid: pid_t
    let window: AXUIElement?
    let windowFrame: Rect?
    let mode: ScanMode
    let elements: [ScannedElement]
    let menubar: [ScannedElement]?
    let at: Date
    let ms: Double

    var all: [ScannedElement] { elements + (menubar ?? []) }

    static func run(_ s: HintScope, onBatch: (([ScannedElement]) -> Void)? = nil) -> WindowScan {
        let t0 = DispatchTime.now().uptimeNanoseconds
        var opts = Scanner.Options()
        opts.mode = s.mode
        let win: AXUIElement?
        var els: [ScannedElement] = []
        if !s.window {
            win = AXUIElement.app(s.pid).element("AXFocusedWindow")
        } else if let root = s.root {
            win = root
            els = Scanner.scan(roots: [(root, root.frame)], options: opts, source: .window, onBatch: onBatch)
        } else {
            let app = AXUIElement.app(s.pid)
            app.setTimeout(0.5)
            win = app.element("AXFocusedWindow") ?? app.element("AXMainWindow")
            els = Scanner.scanApp(pid: s.pid, options: opts, onBatch: onBatch)
        }
        let frame = win?.frame
        let bar = s.menubar ? Scanner.scanMenuBar(pid: s.pid) : nil
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return WindowScan(pid: s.pid, window: win, windowFrame: frame, mode: s.mode, elements: els, menubar: bar, at: Date(), ms: ms)
    }
}

/// Keeps recent scans of the frontmost app warm so modes open with labels on the first frame.
///
/// - Click mode: the front app's focused window is re-scanned in the background (utility QoS,
///   debounced) whenever its AX tree reports a change; scroll/click/resize mark the cache unusable
///   until the rescan lands. At most one scan per pid is in flight; changes during a scan queue
///   exactly one follow-up.
/// - Menu extras / Dock: global, refreshed lazily (on activation when older than 10 s, or on launch/quit).
/// - Windows / menu search: only prewarmed after the mode has been used once.
@MainActor
final class ScanCache {
    final class Entry {
        var scan: WindowScan
        /// Content changed since the scan (still shown, then reconciled).
        var dirty = false
        /// Layout changed (scroll, resize, click): don't show until rescanned.
        var invalid = false
        init(_ s: WindowScan) { scan = s }
    }

    private final class Flight: @unchecked Sendable {  // main-actor only; crosses to the scan queue untouched
        let scope: HintScope
        var dirty = false
        var hard = false
        var waiters: [(WindowScan) -> Void] = []
        var followUp: [(WindowScan) -> Void]?
        var followUpScope: HintScope?
        /// Waiters wanting early results; called once with what was found so far if the scan is slow.
        var partial: [([ScannedElement]) -> Void] = []
        init(_ s: HintScope) { scope = s }
    }

    var enabled = true
    /// Debounce after the last change before a background rescan.
    var debounce: TimeInterval = 0.12
    /// Never start background scans of one app closer together than this.
    var minGap: TimeInterval = 0.4
    /// Cached scans older than this are never shown.
    var maxAge: TimeInterval = 300

    private(set) var entries: [Entry] = []
    private var flights: [pid_t: Flight] = [:]
    private var timers: [pid_t: DispatchWorkItem] = [:]
    private var dirtySince: [pid_t: Date] = [:]
    private var lastStart: [pid_t: Date] = [:]
    private(set) var scansRun = 0

    private(set) var extras: [ScannedElement]?
    private(set) var dock: [ScannedElement]?
    private var globalsAt = Date.distantPast
    private var globalsFlight: [() -> Void]?

    private(set) var windowList: (list: [WindowInfo], at: Date)?
    private var windowsFlight: [([WindowInfo]) -> Void]?
    private var windowsWanted = false

    private var menuCache: [pid_t: (list: [MenuEntry], at: Date)] = [:]
    private var menuFlights: [pid_t: [([MenuEntry]) -> Void]] = [:]
    private var menusWanted = false

    private var observer: AppObserver?
    private var ignored: (String?) -> Bool = { _ in false }
    private var windowsTimer: DispatchWorkItem?
    private var monitors: [Any] = []
    private var workspaceTokens: [NSObjectProtocol] = []
    /// What a background scan of the front app should cover (set by the controller from config).
    var scopeFor: ((NSRunningApplication) -> HintScope?)?
    var sourcesNeedGlobals: () -> (extras: Bool, dock: Bool) = { (true, false) }

    // MARK: Lookup

    /// A usable cached scan for this window, or nil.
    func entry(pid: pid_t, window: AXUIElement?, frame: Rect?, mode: ScanMode, menubar: Bool) -> Entry? {
        guard enabled else { return nil }
        let now = Date()
        return entries.last { e in
            let s = e.scan
            guard s.pid == pid, !e.invalid, s.mode == mode, !menubar || s.menubar != nil,
                now.timeIntervalSince(s.at) < maxAge, !s.all.isEmpty
            else { return false }
            guard Self.same(s.window, window) else { return false }
            // A move just shifts frames; a resize reflows the layout.
            if let a = s.windowFrame, let b = frame, abs(a.width - b.width) > 1 || abs(a.height - b.height) > 1 { return false }
            return true
        }
    }

    /// Global parts (menu extras, Dock) if cached for the requested sources.
    func globals(extras wantExtras: Bool, dock wantDock: Bool) -> [ScannedElement]? {
        guard enabled else { return nil }
        if wantExtras && extras == nil || wantDock && dock == nil { return nil }
        return (wantExtras ? extras ?? [] : []) + (wantDock ? dock ?? [] : [])
    }

    var globalsStale: Bool { Date().timeIntervalSince(globalsAt) > 10 }

    // MARK: Scanning

    /// Scans now (or joins an in-flight scan that started after the last change). Result on main.
    /// Results arriving after this long are shown progressively (`partial`) instead of all at once.
    nonisolated static let partialAfter: UInt64 = 40_000_000

    func scan(
        _ scope: HintScope, qos: DispatchQoS.QoSClass = .userInitiated, delay: TimeInterval = 0,
        partial: (([ScannedElement]) -> Void)? = nil, _ done: @escaping (WindowScan) -> Void
    ) {
        if let f = flights[scope.pid] {
            if !f.dirty && f.scope.mode == scope.mode && (f.scope.menubar || !scope.menubar) && f.scope.window == scope.window
                && Self.same(f.scope.root, scope.root)
            {
                f.waiters.append(done)
                if let partial { f.partial.append(partial) }
            } else {
                f.dirty = true
                f.followUp = (f.followUp ?? []) + [done]
                f.followUpScope = scope
            }
            return
        }
        start(scope, qos: qos, delay: delay, waiters: [done], partial: partial.map { [$0] } ?? [])
    }

    private func start(
        _ scope: HintScope, qos: DispatchQoS.QoSClass, delay: TimeInterval, waiters: [(WindowScan) -> Void],
        partial: [([ScannedElement]) -> Void] = []
    ) {
        let f = Flight(scope)
        f.waiters = waiters
        f.partial = partial
        flights[scope.pid] = f
        timers[scope.pid]?.cancel()
        timers[scope.pid] = nil
        dirtySince[scope.pid] = nil
        lastStart[scope.pid] = Date()
        scansRun += 1
        DispatchQueue.global(qos: qos).asyncAfter(deadline: .now() + delay) {
            // Batches never overlap (Scanner contract), so plain captured state is safe here.
            let t0 = DispatchTime.now().uptimeNanoseconds
            var soFar: [ScannedElement] = []
            var sent = false
            let r = WindowScan.run(scope) { batch in
                soFar += batch
                guard !sent, DispatchTime.now().uptimeNanoseconds - t0 > Self.partialAfter, !soFar.isEmpty else { return }
                sent = true
                let early = soFar
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self.flights[scope.pid] === f else { return }
                        for p in f.partial { p(early) }
                        f.partial = []
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(f, r) }
            }
        }
    }

    private func finish(_ f: Flight, _ r: WindowScan) {
        if flights[r.pid] === f { flights[r.pid] = nil }
        store(r, dirty: f.dirty, invalid: f.hard)
        for w in f.waiters { w(r) }
        if let next = f.followUp {
            start(f.followUpScope ?? f.scope, qos: .userInitiated, delay: 0, waiters: next)
        } else if f.dirty, enabled, observer?.pid == r.pid {
            schedule(r.pid)
        }
    }

    static func same(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case (let a?, let b?): CFEqual(a, b)
        default: false
        }
    }

    func store(_ r: WindowScan, dirty: Bool = false, invalid: Bool = false) {
        guard enabled else { return }
        entries.removeAll { $0.scan.pid == r.pid && Self.same($0.scan.window, r.window) }
        let e = Entry(r)
        e.dirty = dirty
        e.invalid = invalid
        entries.append(e)
        if entries.count > 8 { entries.removeFirst(entries.count - 8) }
    }

    /// Refreshes menu extras / Dock in the background.
    func refreshGlobals(_ done: (() -> Void)? = nil) {
        if globalsFlight != nil {
            if let done { globalsFlight?.append(done) }
            return
        }
        globalsFlight = done.map { [$0] } ?? []
        let need = sourcesNeedGlobals()
        DispatchQueue.global(qos: .utility).async {
            let ex = need.extras ? Scanner.scanMenuExtras() : nil
            let dk = need.dock ? Scanner.scanDock() : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let ex { self.extras = ex }
                    if let dk { self.dock = dk }
                    self.globalsAt = Date()
                    let ws = self.globalsFlight ?? []
                    self.globalsFlight = nil
                    ws.forEach { $0() }
                }
            }
        }
    }

    func cachedWindows() -> [WindowInfo]? {
        guard enabled, let w = windowList, Date().timeIntervalSince(w.at) < maxAge, !w.list.isEmpty else { return nil }
        return w.list
    }

    func scanWindows(qos: DispatchQoS.QoSClass = .userInitiated, _ done: (([WindowInfo]) -> Void)? = nil) {
        windowsWanted = true
        if windowsFlight != nil {
            if let done { windowsFlight?.append(done) }
            return
        }
        windowsFlight = done.map { [$0] } ?? []
        DispatchQueue.global(qos: qos).async {
            let ws = WindowScanner.scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.enabled { self.windowList = (ws, Date()) }
                    let cbs = self.windowsFlight ?? []
                    self.windowsFlight = nil
                    cbs.forEach { $0(ws) }
                }
            }
        }
    }

    func cachedMenus(pid: pid_t) -> [MenuEntry]? {
        guard enabled, let m = menuCache[pid], Date().timeIntervalSince(m.at) < maxAge, !m.list.isEmpty else { return nil }
        return m.list
    }

    func scanMenus(pid: pid_t, qos: DispatchQoS.QoSClass = .userInitiated, _ done: (([MenuEntry]) -> Void)? = nil) {
        menusWanted = true
        if menuFlights[pid] != nil {
            if let done { menuFlights[pid]?.append(done) }
            return
        }
        menuFlights[pid] = done.map { [$0] } ?? []
        DispatchQueue.global(qos: qos).async {
            let ms = MenuScanner.scan(pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.enabled {
                        self.menuCache[pid] = (ms, Date())
                        if self.menuCache.count > 6, let old = self.menuCache.min(by: { $0.value.at < $1.value.at })?.key {
                            self.menuCache[old] = nil
                        }
                    }
                    let cbs = self.menuFlights[pid] ?? []
                    self.menuFlights[pid] = nil
                    cbs.forEach { $0(ms) }
                }
            }
        }
    }

    // MARK: Invalidation

    /// Content of `pid` changed: keep showing the cache, rescan soon.
    func noteChange(pid: pid_t, hard: Bool) {
        for e in entries where e.scan.pid == pid {
            e.dirty = true
            if hard { e.invalid = true }
        }
        flights[pid]?.dirty = true
        if hard { flights[pid]?.hard = true }
        if enabled, observer?.pid == pid { schedule(pid) }
    }

    func clear() {
        entries = []
        windowList = nil
        menuCache = [:]
        extras = nil
        dock = nil
        globalsAt = .distantPast
    }

    /// Debounced background rescan of the front app.
    func schedule(_ pid: pid_t, delay: TimeInterval? = nil) {
        guard enabled, let app = NSRunningApplication(processIdentifier: pid), let scope = scopeFor?(app) else { return }
        let now = Date()
        let first = dirtySince[pid] ?? now
        dirtySince[pid] = first
        var d = delay ?? debounce
        // Busy apps never go quiet: scan anyway once a change is 1 s old.
        if now.timeIntervalSince(first) > 1 { d = 0 }
        if let last = lastStart[pid] { d = max(d, minGap - now.timeIntervalSince(last)) }
        timers[pid]?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.enabled else { return }
                self.timers[pid] = nil
                if let f = self.flights[pid] {
                    f.dirty = true  // finish() reschedules
                    return
                }
                self.start(scope, qos: .utility, delay: 0, waiters: [])
            }
        }
        timers[pid] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(d, 0), execute: w)
    }

    // MARK: Live wiring (only for the real app controller)

    /// Watches the front app. `ignored` decides which apps are never prewarmed.
    func startLive(ignored: @escaping (String?) -> Bool) {
        self.ignored = ignored
        let nc = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(
            nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.activated(app) }
            })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceTokens.append(
                nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                    let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if name == NSWorkspace.didTerminateApplicationNotification, let pid = app?.processIdentifier {
                            self.entries.removeAll { $0.scan.pid == pid }
                            self.menuCache[pid] = nil
                        }
                        self.globalsAt = .distantPast
                        guard self.enabled else { return }
                        // Menu extras appear a moment after launch.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refreshGlobals() }
                        self.scheduleWindows()
                    }
                })
        }
        // Scrolling and clicking move content without reliable AX notifications.
        if let m = NSEvent.addGlobalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDown, .rightMouseDown],
            handler: { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let pid = self.observer?.pid else { return }
                    self.noteChange(pid: pid, hard: true)
                }
            })
        {
            monitors.append(m)
        }
        activated(NSWorkspace.shared.frontmostApplication)
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if !on {
            observer?.invalidate()
            observer = nil
            timers.values.forEach { $0.cancel() }
            timers = [:]
            clear()
        } else if !workspaceTokens.isEmpty {
            activated(NSWorkspace.shared.frontmostApplication)
        }
    }

    private func activated(_ app: NSRunningApplication?) {
        guard enabled, let app else { return }
        let pid = app.processIdentifier
        if pid == getpid() { return }  // our own windows (Settings) aren't worth prewarming
        if observer?.pid != pid {
            observer?.invalidate()
            observer = nil
        }
        guard !ignored(app.bundleIdentifier), app.activationPolicy == .regular else { return }
        let first = AppSupport.prepare(app)
        if observer == nil {
            observer = AppObserver(pid: pid) { [weak self] name in self?.notification(name, pid: pid) }
        }
        // Whatever we have for this app wasn't observed while it was in the background.
        for e in entries where e.scan.pid == pid { e.dirty = true }
        schedule(pid, delay: first ? 0.4 : 0.05)
        if globalsStale { refreshGlobals() }
        scheduleWindows()
        if menusWanted, menuCache[pid].map({ Date().timeIntervalSince($0.at) > 60 }) ?? true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.observer?.pid == pid else { return }
                self.scanMenus(pid: pid, qos: .utility)
            }
        }
    }

    /// Debounced background refresh of the window list, once Windows mode has been used.
    private func scheduleWindows() {
        guard enabled, windowsWanted else { return }
        windowsTimer?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.scanWindows(qos: .utility) }
        }
        windowsTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    private func notification(_ name: String, pid: pid_t) {
        if AppObserver.moved.contains(name) {
            // Click-mode frames are translated on use; Windows mode positions change though.
            scheduleWindows()
            return
        }
        let hard = AppObserver.hard.contains(name)
        if hard { scheduleWindows() }
        noteChange(pid: pid, hard: hard)
    }
}
