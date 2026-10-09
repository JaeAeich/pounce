import AppKit
import ApplicationServices
import PounceCore

/// Role → behaviour bits, looked up by CFString without bridging to Swift `String`.
struct RoleFlags: OptionSet {
    let rawValue: Int
    static let clickable = RoleFlags(rawValue: 1 << 0)
    static let exhaustiveExtra = RoleFlags(rawValue: 1 << 1)
    static let clip = RoleFlags(rawValue: 1 << 2)
    static let skipSubtree = RoleFlags(rawValue: 1 << 3)
    static let scrollArea = RoleFlags(rawValue: 1 << 4)
    /// AXTable / AXOutline: walk AXVisibleRows (+ AXHeader) instead of every row.
    static let rows = RoleFlags(rawValue: 1 << 5)
    /// AXList / AXGrid: walk AXVisibleChildren.
    static let visibleChildren = RoleFlags(rawValue: 1 << 6)
    static let webArea = RoleFlags(rawValue: 1 << 7)
    static let row = RoleFlags(rawValue: 1 << 8)
    static let staticText = RoleFlags(rawValue: 1 << 9)
    /// Never a hint when returned by a web search predicate.
    static let notSearchHit = RoleFlags(rawValue: 1 << 10)
    /// Text inputs (the only roles whose AXPlaceholderValue we fetch).
    static let input = RoleFlags(rawValue: 1 << 11)

    private static let table: NSDictionary = {
        var d: [String: Int] = [:]
        func add(_ roles: Set<String>, _ f: RoleFlags) { for r in roles { d[r, default: 0] |= f.rawValue } }
        add(Scanner.clickableRoles, .clickable)
        add(Scanner.exhaustiveExtraRoles, .exhaustiveExtra)
        add(Scanner.clipRoles, .clip)
        add(Scanner.skipSubtreeRoles, .skipSubtree)
        add(["AXScrollArea"], .scrollArea)
        add(["AXTable", "AXOutline"], .rows)
        add(["AXList", "AXGrid"], .visibleChildren)
        add(["AXWebArea"], .webArea)
        add(["AXRow"], .row)
        add(["AXStaticText"], .staticText)
        add(["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"], .input)
        add(
            [
                "AXGroup", "AXStaticText", "AXImage", "AXCell", "AXUnknown", "AXRow", "AXColumn", "AXWebArea",
                "AXScrollArea", "AXList", "AXTable", "AXOutline", "AXHeading", "AXSplitGroup", "AXLayoutArea",
            ], .notSearchHit)
        let ns = NSMutableDictionary()
        for (k, v) in d { ns[k as NSString] = NSNumber(value: v) }
        return ns.copy() as! NSDictionary
    }()

    static func of(_ role: NSString) -> RoleFlags {
        RoleFlags(rawValue: (table.object(forKey: role) as? NSNumber)?.intValue ?? 0)
    }
}

/// One scan: a shared LIFO work queue drained by a few worker threads.
final class ScanRun {
    enum Kind { case root, node, deferredChildren, searchResult }
    struct Job {
        let el: AXUIElement
        let clip: Rect
        let depth: Int
        let path: [Int32]
        let kind: Kind
    }
    struct Hit {
        let path: [Int32]
        let element: ScannedElement
    }

    // Pass 1: just enough to prune, decide hits and descend. Children last so it can be dropped.
    static let pass1Frame = ["AXRole", "AXFrame", "AXChildren"]
    static let pass1PosSize = ["AXRole", "AXPosition", "AXSize", "AXChildren"]
    // Pass 2, hit candidates only. AXPlaceholderValue only matters (and costs) for inputs.
    static let pass2 = ["AXEnabled", "AXSubrole", "AXTitle", "AXDescription", "AXValue", "AXHelp", "AXIdentifier", "AXPlaceholderValue"]
    static let pass2NoPlaceholder = Array(pass2.dropLast())
    static let webSearchKeys = [
        "AXLinkSearchKey", "AXButtonSearchKey", "AXControlSearchKey", "AXTextFieldSearchKey", "AXCheckBoxSearchKey",
    ]
    /// Lists/tables with fewer children than this are walked from the AXChildren we already have.
    static let bigContainer = 64

    let options: Scanner.Options
    let source: HintSource
    let onBatch: (([ScannedElement]) -> Void)?
    private let fast: Bool
    private let start = Clock.now
    private let deadline: UInt64
    private let interval: UInt64

    private let cond = NSCondition()
    private var lanes: [pid_t: [Job]] = [:]
    private var busy: Set<pid_t> = []
    private var active = 0
    private var liveWorkers = 0
    private var maxWorkers = 1
    private let group = DispatchGroup()
    private var hits: [Hit] = []
    private var pending: [ScannedElement] = []
    private var delivered = FrameSet()
    private var lastFlush: UInt64
    private let deliverLock = NSLock()
    private var useFrame = true

    init(options: Scanner.Options, source: HintSource, onBatch: (([ScannedElement]) -> Void)?) {
        self.options = options
        self.source = source
        self.onBatch = onBatch
        fast = options.mode == .fast
        deadline = start + UInt64(max(options.deadline, 0) * 1e9)
        interval = UInt64(max(options.batchInterval, 0) * 1e9)
        lastFlush = start
    }

    /// Queues a root before `execute()`.
    func add(root: Job) { lanes[lane(root), default: []].insert(root, at: 0) }

    /// Lane = owning process. `Options.testLanes` > 0 fakes several processes (bench/self-test).
    private func lane(_ job: Job) -> pid_t {
        if options.testLanes > 0, job.path.count > 1 { return pid_t(job.path[1] % Int32(options.testLanes)) }
        return job.el.pid
    }

    func execute() -> [ScannedElement] {
        maxWorkers = options.workers > 0 ? options.workers : min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
        cond.lock()
        liveWorkers = 1
        cond.unlock()
        work()
        group.wait()
        if onBatch != nil {
            deliverLock.lock()
            cond.lock()
            let batch = pending.filter { delivered.insert($0.frame) }
            pending = []
            cond.unlock()
            if !batch.isEmpty { onBatch?(batch) }
            deliverLock.unlock()
        }
        hits.sort { a, b in a.path.lexicographicallyPrecedes(b.path) }
        return Scanner.dedupe(hits.prefix(options.maxElements).map(\.element))
    }

    private var shouldStop: Bool {
        hits.count >= options.maxElements || Clock.now >= deadline || options.cancel?.isCancelled == true
    }

    /// With `cond` held: a lane (process) with work that no other worker is serving.
    private func freeLane() -> pid_t? {
        for (pid, jobs) in lanes where !jobs.isEmpty && !busy.contains(pid) { return pid }
        return nil
    }

    /// Workers drain per-process lanes. A process answers AX requests on one thread, so
    /// concurrent requests to the same pid only contend (measured: 2 threads ≈ 15% slower);
    /// different processes (e.g. a WebKit content process inside a window) run in parallel.
    private func work() {
        cond.lock()
        while true {
            if shouldStop {
                lanes.removeAll()
                cond.broadcast()
                break
            }
            if let pid = freeLane(), let job = lanes[pid]?.popLast() {
                busy.insert(pid)
                active += 1
                let uf = useFrame
                cond.unlock()
                var out = Output()
                process(job, useFrame: uf, into: &out)
                cond.lock()
                active -= 1
                busy.remove(pid)
                if out.noFrame { useFrame = false }
                for h in out.hits {
                    hits.append(h)
                    if onBatch != nil { pending.append(h.element) }
                }
                var foreign = false
                for c in out.children.reversed() {
                    let p = lane(c)
                    if p != pid { foreign = true }
                    lanes[p, default: []].append(c)
                }
                if foreign {
                    spawnIfNeeded()
                    cond.broadcast()
                }
                if onBatch != nil { maybeFlush() }
                continue
            }
            if active == 0 && freeLane() == nil {
                cond.broadcast()
                break
            }
            cond.wait()
        }
        cond.unlock()
    }

    /// With `cond` held: adds a worker if more lanes have work than there are workers.
    private func spawnIfNeeded() {
        guard liveWorkers < maxWorkers else { return }
        let free = lanes.filter { !$0.value.isEmpty && !busy.contains($0.key) }.count
        guard free > liveWorkers - active else { return }  // more free lanes than idle workers
        liveWorkers += 1
        group.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            self.work()
            self.group.leave()
        }
    }

    /// Called with `cond` held; delivers pending hits if a batch is due and nobody else is delivering.
    private func maybeFlush() {
        guard !pending.isEmpty else { return }
        let now = Clock.now
        guard now &- lastFlush >= interval, deliverLock.try() else { return }
        let batch = pending.filter { delivered.insert($0.frame) }
        pending = []
        lastFlush = now
        cond.unlock()
        if !batch.isEmpty { onBatch?(batch) }
        deliverLock.unlock()
        cond.lock()
    }

    private struct Output {
        var hits: [Hit] = []
        var children: [Job] = []
        var noFrame = false
    }

    // MARK: Node processing (no locks held)

    private func frame(_ el: AXUIElement, _ v: [CFTypeRef?], useFrame: Bool, out: inout Output) -> Rect? {
        if !useFrame { return AX.frame(position: v[1], size: v[2]) }
        if let r = AX.rect(v[1]) { return r }
        // App without AXFrame: fall back for this node and switch the rest of the scan over.
        let ps = el.values(["AXPosition", "AXSize"])
        let r = AX.frame(position: ps[0], size: ps[1])
        if r != nil { out.noFrame = true }
        return r
    }

    private func process(_ job: Job, useFrame: Bool, into out: inout Output) {
        // Per-element timeout (a local setting, no IPC): a hung app can't stall the scan
        // for the default 6 s per request, only until the scan's own deadline.
        let left = Double(deadline &- min(Clock.now, deadline)) / 1e9
        job.el.setTimeout(Float(max(0.05, min(0.5, left))))
        if job.kind == .searchResult { return processSearchResult(job, useFrame: useFrame, into: &out) }
        let el = job.el
        let deferKids = job.kind == .deferredChildren
        var attrs = useFrame ? Self.pass1Frame : Self.pass1PosSize
        if deferKids { attrs.removeLast() }
        let v = el.values(attrs)
        guard let roleRef = v[0], CFGetTypeID(roleRef) == CFStringGetTypeID() else { return }
        let roleNS = roleRef as! NSString
        let flags = RoleFlags.of(roleNS)
        let isRoot = job.kind == .root
        if !isRoot, flags.contains(.skipSubtree) { return }
        let f = frame(el, v, useFrame: useFrame, out: &out)

        // Prune subtrees that are entirely clipped away (scrolled out, hidden tabs…).
        var childClip = job.clip
        if let f, !f.isEmpty {
            let visible = f.intersection(job.clip)
            if visible.isEmpty && !isRoot { return }
            if flags.contains(.clip) && !isRoot { childClip = visible }
        }

        if let f, f.width >= 2, f.height >= 2 {
            let visible = f.intersection(job.clip)
            if visible.width >= 3, visible.height >= 3 {  // not slivers (1 px status bubbles, clipped edges)
                var include = flags.contains(.clickable)
                if !include, !fast {
                    include = flags.contains(.exhaustiveExtra) || !Scanner.pressActions.isDisjoint(with: el.actions)
                }
                if flags.contains(.row) && fast { include = false }
                if include, let e = hit(el, role: roleNS as String, flags: flags, frame: visible, text: nil) {
                    out.hits.append(Hit(path: job.path, element: e))
                }
            }
        }

        guard job.depth < options.maxDepth else { return }
        let depth = job.depth + 1
        if flags.contains(.webArea), fast, options.webSearch, let found = webSearch(el), !found.isEmpty {
            out.children = found.enumerated().map { i, c in
                Job(el: c, clip: childClip, depth: depth, path: job.path + [Int32(i)], kind: .searchResult)
            }
            return
        }
        let fetched = deferKids ? nil : v[attrs.count - 1] as? [AXUIElement]
        let kids = Self.children(of: el, flags: flags, fetched: fetched, deferred: deferKids)
        guard !kids.isEmpty else { return }
        // Children of scroll areas are fetched once their role is known (tables, web areas).
        let kind: Kind = flags.contains(.scrollArea) ? .deferredChildren : .node
        out.children.reserveCapacity(kids.count)
        for (i, c) in kids.enumerated() {
            out.children.append(Job(el: c, clip: childClip, depth: depth, path: job.path + [Int32(i)], kind: kind))
        }
    }

    /// Children worth walking: visible rows for tables/outlines (+ header), visible children
    /// for lists, otherwise AXChildren (`fetched` if pass 1 already returned it).
    static func children(of el: AXUIElement, flags: RoleFlags, fetched: [AXUIElement]?, deferred: Bool) -> [AXUIElement] {
        if flags.contains(.rows), deferred || (fetched?.count ?? 0) > bigContainer {
            let r = el.values(["AXVisibleRows", "AXHeader"])
            if var rows = r[0] as? [AXUIElement] {
                if let h = r[1], CFGetTypeID(h) == AXUIElementGetTypeID() { rows.insert(h as! AXUIElement, at: 0) }
                return rows
            }
        } else if flags.contains(.visibleChildren), deferred || (fetched?.count ?? 0) > bigContainer {
            if let kids = el.value("AXVisibleChildren") as? [AXUIElement] { return kids }
        }
        if let fetched { return fetched }
        return deferred ? el.elements("AXChildren") : []
    }

    /// An element returned by AXUIElementsForSearchPredicate: one fetch, no descent.
    private func processSearchResult(_ job: Job, useFrame: Bool, into out: inout Output) {
        let el = job.el
        let head = useFrame ? ["AXRole", "AXFrame"] : ["AXRole", "AXPosition", "AXSize"]
        let v = el.values(head + Self.pass2)
        guard let roleRef = v[0], CFGetTypeID(roleRef) == CFStringGetTypeID() else { return }
        let roleNS = roleRef as! NSString
        let flags = RoleFlags.of(roleNS)
        guard flags.contains(.clickable) || !flags.contains(.notSearchHit), !flags.contains(.skipSubtree) else { return }
        guard let f = frame(el, v, useFrame: useFrame, out: &out), f.width >= 2, f.height >= 2 else { return }
        let visible = f.intersection(job.clip)
        guard visible.width >= 3, visible.height >= 3 else { return }
        if let e = hit(el, role: roleNS as String, flags: flags, frame: visible, text: Array(v[head.count...])) {
            out.hits.append(Hit(path: job.path, element: e))
        }
    }

    private func hit(_ el: AXUIElement, role: String, flags: RoleFlags, frame: Rect, text: [CFTypeRef?]?) -> ScannedElement? {
        let t = text ?? el.values(flags.contains(.input) ? Self.pass2 : Self.pass2NoPlaceholder)
        if (t[0] as? NSNumber)?.boolValue == false { return nil }  // disabled
        let subrole = t[1] as? String
        let title = AX.string(t[2]), value = AX.string(t[4])
        if flags.contains(.staticText), (value ?? title ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        return ScannedElement(
            element: el, role: role, subrole: subrole, title: title, desc: AX.string(t[3]), value: value,
            help: AX.string(t[5]), placeholder: t.count > 7 ? AX.string(t[7]) : nil, identifier: AX.string(t[6]),
            frame: frame, category: Scanner.category(role: role, subrole: subrole), source: source)
    }

    /// Visible links/controls of a web area in one IPC (WebKit, Chromium, Electron).
    private func webSearch(_ el: AXUIElement) -> [AXUIElement]? {
        let params: [String: Any] = [
            "AXSearchKey": Self.webSearchKeys,
            "AXVisibleOnly": true,
            "AXResultsLimit": options.maxElements,
            "AXDirection": "AXDirectionNext",
            "AXImmediateDescendantsOnly": false,
        ]
        var out: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(el, "AXUIElementsForSearchPredicate" as CFString, params as CFDictionary, &out)
                == .success
        else { return nil }
        return out as? [AXUIElement]
    }
}

/// Cheap monotonic nanoseconds (commpage read, no syscall).
enum Clock {
    static var now: UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}

// MARK: - Menu extras

/// Remembers which processes own status-bar extras so activation only asks those
/// (plus newly launched apps). Everything else is re-checked in the background.
final class MenuExtras: @unchecked Sendable {
    static let shared = MenuExtras()

    private let lock = NSLock()
    private var bars: [pid_t: AXUIElement] = [:]
    private var without: Set<pid_t> = []
    private var lastRecheck: UInt64 = 0
    private var rechecking = false
    private static let recheckEvery: UInt64 = 10_000_000_000

    private static func candidatePids() -> [pid_t] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }.map(\.processIdentifier)
    }

    private static func lookupBar(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElement.app(pid)
        app.setTimeout(0.08)
        guard let bar = app.element("AXExtrasMenuBar") else { return nil }
        bar.setTimeout(0.15)
        return bar
    }

    func scan() -> [ScannedElement] {
        let pids = Self.candidatePids()
        let alive = Set(pids)
        lock.lock()
        bars = bars.filter { alive.contains($0.key) }
        without.formIntersection(alive)
        let known = bars
        let unseen = pids.filter { known[$0] == nil && !without.contains($0) }
        lock.unlock()

        let work: [(pid_t, AXUIElement?)] = known.map { ($0.key, $0.value) } + unseen.map { ($0, nil) }
        var found: [pid_t: AXUIElement] = [:]
        var missing: [pid_t] = []
        var items: [[ScannedElement]] = Array(repeating: [], count: work.count)
        let rlock = NSLock()
        DispatchQueue.concurrentPerform(iterations: work.count) { i in
            let (pid, cached) = work[i]
            var bar = cached
            var kids = bar.map { $0.elements("AXChildren") } ?? []
            if kids.isEmpty {
                // Unknown pid, or the cached element went stale.
                bar = Self.lookupBar(pid)
                kids = bar.map { $0.elements("AXChildren") } ?? []
            }
            let els = Scanner.elements(kids, source: .extras)
            rlock.lock()
            if let bar { found[pid] = bar } else { missing.append(pid) }
            items[i] = els
            rlock.unlock()
        }

        lock.lock()
        for (p, b) in found { bars[p] = b }
        for p in missing {
            bars[p] = nil
            without.insert(p)
        }
        let due = !rechecking && Clock.now &- lastRecheck > Self.recheckEvery && !without.isEmpty
        if due { rechecking = true }
        lock.unlock()
        if due { DispatchQueue.global(qos: .utility).async { self.recheck() } }

        // Stable left-to-right order keeps labels stable between activations.
        return items.joined().sorted { $0.frame.x < $1.frame.x }
    }

    /// Re-asks apps that had no extras last time (they may have added one since).
    private func recheck() {
        lock.lock()
        let pids = Array(without)
        lock.unlock()
        var found: [pid_t: AXUIElement] = [:]
        let rlock = NSLock()
        DispatchQueue.concurrentPerform(iterations: pids.count) { i in
            guard let bar = Self.lookupBar(pids[i]) else { return }
            rlock.lock()
            found[pids[i]] = bar
            rlock.unlock()
        }
        lock.lock()
        for (p, b) in found {
            bars[p] = b
            without.remove(p)
        }
        lastRecheck = Clock.now
        rechecking = false
        lock.unlock()
    }

    /// Warms the pid cache off the hot path (call at startup).
    func prewarm() {
        DispatchQueue.global(qos: .utility).async { _ = self.scan() }
    }
}
