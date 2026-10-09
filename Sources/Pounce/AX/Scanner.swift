import AppKit
import ApplicationServices
import PounceCore

/// A UI element found by a scan, with everything needed to label, search and act on it.
struct ScannedElement: @unchecked Sendable {
    let element: AXUIElement
    let role: String
    let subrole: String?
    let title: String?
    let desc: String?
    let value: String?
    let help: String?
    let placeholder: String?
    let identifier: String?
    let frame: Rect
    let category: HintCategory
    let source: HintSource

    var isTextInput: Bool { category == .input }

    /// Text matched by search queries.
    var searchText: String {
        [title, desc, placeholder, valueForSearch, help].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var valueForSearch: String? {
        guard let v = value, v.count <= 120, category != .input else { return nil }
        return v
    }

    /// The most useful text to copy for ⌃Y.
    var copyText: String? {
        for c in [category == .input ? value : nil, title, desc, value, placeholder, help] {
            if let c, !c.isEmpty { return c }
        }
        return nil
    }

    func key(bundleID: String?, windowOrigin: Point) -> String {
        let name = (title?.isEmpty == false ? title : desc) ?? ""
        let gx = Int((frame.x - windowOrigin.x) / 24), gy = Int((frame.y - windowOrigin.y) / 24)
        return "\(bundleID ?? "?")|\(role)|\(name.prefix(40))|\(gx),\(gy)"
    }
}

// MARK: - Scanner
//
// Streaming API (for the cache / prewarm layer):
//
//     Scanner.scanApp(pid: pid_t, options: Options, source: HintSource = .window,
//                     onBatch: (([ScannedElement]) -> Void)?) -> [ScannedElement]
//     Scanner.scan(roots: [(AXUIElement, Rect?)], options: Options, source: HintSource,
//                  onBatch: (([ScannedElement]) -> Void)?) -> [ScannedElement]
//
// - Both block until the scan finishes; call from a background thread (Task.detached).
//   Scanning our own process from the main thread would deadlock (we serve AX there).
// - `onBatch` gets elements progressively while the walk is still running: the first
//   batch as soon as there is something to show after `options.batchInterval` (8 ms),
//   then at most every `batchInterval`, plus a final flush before returning.
//   Calls are serial (never concurrent) but come from scanner worker threads, so keep the
//   closure cheap and hop to the main actor yourself. Each batch only contains new
//   elements, already de-duplicated against everything delivered before.
// - The return value is authoritative: the same elements in tree (DFS) order, deduped,
//   capped at `maxElements`. Prefer it over the accumulated batches for label assignment
//   (stable across activations). The union of batches equals it up to dedupe tie-breaks.
// - `options.cancel` (a `ScanCancel`) stops a scan early; partial results are returned.
// - The non-streaming `scanApp(pid:options:source:)` / `scan(roots:options:source:)`
//   are unchanged wrappers.
//
// How it is fast:
// - Pass 1 per node fetches only [role, AXFrame, enabled, children] in one IPC
//   (AXFrame is ~2x cheaper than AXPosition + AXSize); falls back to position/size for
//   apps without AXFrame. Text attributes are fetched (one more IPC) only for hits.
// - Tables/outlines use AXVisibleRows (+ AXHeader), lists AXVisibleChildren, so a
//   10k-row table costs O(visible). Children of scroll areas are fetched after we know
//   their role, so we never pull a 10k-element AXChildren array.
// - AXWebArea in fast mode: one AXUIElementsForSearchPredicate call returns the visible
//   links/controls/text fields; falls back to walking if unsupported or empty.
// - A shared LIFO work queue keeps all workers busy regardless of tree shape.

/// Cancels a running scan (thread-safe).
final class ScanCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

enum Scanner {
    static let attributes = [
        "AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXValue", "AXHelp",
        "AXPlaceholderValue", "AXIdentifier", "AXPosition", "AXSize", "AXEnabled", "AXChildren",
    ]

    static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXMenuBarItem", "AXMenuItem", "AXTextField", "AXTextArea", "AXComboBox", "AXSlider",
        "AXDisclosureTriangle", "AXIncrementor", "AXColorWell", "AXDockItem", "AXSegmentedControl",
        "AXRow", "AXSearchField", "AXTab",
    ]
    static let exhaustiveExtraRoles: Set<String> = ["AXStaticText", "AXImage", "AXCell", "AXHeading"]
    static let pressActions: Set<String> = ["AXPress", "AXShowMenu", "AXPick", "AXConfirm", "AXOpen"]
    static let clipRoles: Set<String> = ["AXScrollArea", "AXWebArea", "AXList", "AXOutline", "AXTable", "AXBrowser"]
    static let skipSubtreeRoles: Set<String> = ["AXMenuBar", "AXMenu"]

    struct Options {
        var mode: ScanMode = .fast
        var maxDepth = 80
        var maxElements = 3000
        var deadline: TimeInterval = 1.5
        /// Use AXUIElementsForSearchPredicate for web areas in fast mode.
        var webSearch = true
        /// Worker threads; 0 = automatic.
        var workers = 0
        /// Streaming: minimum time between `onBatch` calls.
        var batchInterval: TimeInterval = 0.008
        var cancel: ScanCancel? = nil
        /// Testing only: spread top-level subtrees over this many fake process lanes.
        var testLanes = 0
    }

    // MARK: Entry points

    /// Scans the frontmost window of `app` plus any open menus / sheets.
    static func scanApp(pid: pid_t, options: Options, source: HintSource = .window) -> [ScannedElement] {
        scanApp(pid: pid, options: options, source: source, onBatch: nil)
    }

    /// Streaming variant; see the API notes at the top of this section.
    static func scanApp(
        pid: pid_t, options: Options, source: HintSource = .window,
        onBatch: (([ScannedElement]) -> Void)?
    ) -> [ScannedElement] {
        scan(roots: appRoots(pid: pid), options: options, source: source, onBatch: onBatch)
    }

    /// Open context menus (children of the app element) plus the focused window.
    static func appRoots(pid: pid_t) -> [(AXUIElement, Rect?)] {
        let app = AXUIElement.app(pid)
        app.setTimeout(0.5)
        var roots: [(AXUIElement, Rect?)] = []
        // One round trip for the usual case: children (open menus) + focused window.
        let v = app.values(["AXChildren", "AXFocusedWindow"])
        for child in (v[0] as? [AXUIElement]) ?? [] where child.string("AXRole") == "AXMenu" {
            roots.append((child, nil))
        }
        var win: AXUIElement?
        if let w = v[1], CFGetTypeID(w) == AXUIElementGetTypeID() { win = (w as! AXUIElement) }
        if let win = win ?? app.element("AXMainWindow") ?? app.elements("AXWindows").first {
            roots.append((win, win.fastFrame))
        }
        return roots
    }

    /// Scans arbitrary roots (used by the self-test against our own windows).
    static func scan(roots: [(AXUIElement, Rect?)], options: Options, source: HintSource) -> [ScannedElement] {
        scan(roots: roots, options: options, source: source, onBatch: nil)
    }

    static func scan(
        roots: [(AXUIElement, Rect?)], options: Options, source: HintSource,
        onBatch: (([ScannedElement]) -> Void)?
    ) -> [ScannedElement] {
        let run = ScanRun(options: options, source: source, onBatch: onBatch)
        let screens = Screens.union
        for (i, (root, frame)) in roots.enumerated() {
            let clip = (frame ?? screens).intersection(screens)
            run.add(root: ScanRun.Job(el: root, clip: clip.isEmpty ? screens : clip, depth: 0, path: [Int32(i)], kind: .root))
        }
        return run.execute()
    }

    /// Top-level menu bar items of the app (File, Edit, …).
    static func scanMenuBar(pid: pid_t) -> [ScannedElement] {
        let app = AXUIElement.app(pid)
        app.setTimeout(0.3)
        guard let bar = app.element("AXMenuBar") else { return [] }
        return elements(bar.elements("AXChildren"), source: .menubar)
    }

    /// Status-bar extras of all running apps (Wi-Fi, battery, third-party icons).
    /// Only apps known to have extras (plus never-seen apps) are queried on the hot path;
    /// the rest are re-checked in the background.
    static func scanMenuExtras() -> [ScannedElement] { MenuExtras.shared.scan() }

    static func scanDock() -> [ScannedElement] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
        let app = AXUIElement.app(dock.processIdentifier)
        app.setTimeout(0.3)
        return elements(app.elements("AXChildren").flatMap { $0.elements("AXChildren") }, source: .dock)
    }

    /// Builds elements for a flat list (menu bar, extras, dock) in parallel, keeping order.
    static func elements(_ els: [AXUIElement], source: HintSource) -> [ScannedElement] {
        guard !els.isEmpty else { return [] }
        let opts = Options(mode: .exhaustive)
        let clip = Screens.union
        var out = [ScannedElement?](repeating: nil, count: els.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: min(els.count, 8)) { w in
            var i = w
            while i < els.count {
                let e = makeElement(els[i], values: els[i].values(attributes), clip: clip, options: opts, source: source)
                lock.lock()
                out[i] = e
                lock.unlock()
                i += 8
            }
        }
        return out.compactMap { $0 }
    }

    /// Builds an element from a fetch of `attributes` (legacy layout).
    static func makeElement(_ el: AXUIElement, values v: [CFTypeRef?], clip: Rect, options: Options, source: HintSource) -> ScannedElement?
    {
        guard let role = v[0] as? String else { return nil }
        if (v[10] as? NSNumber)?.boolValue == false { return nil }  // disabled
        guard let frame = AX.frame(position: v[8], size: v[9]), frame.width >= 2, frame.height >= 2 else { return nil }
        let visible = frame.intersection(clip)
        guard visible.width >= 3, visible.height >= 3 else { return nil }

        var include = clickableRoles.contains(role)
        if !include, options.mode == .exhaustive {
            include = exhaustiveExtraRoles.contains(role) || !pressActions.isDisjoint(with: el.actions)
        }
        let subrole = v[1] as? String
        // Rows in big tables would flood the screen; only label rows when exhaustive.
        if role == "AXRow" && options.mode == .fast { include = false }
        guard include else { return nil }

        let title = AX.string(v[2]), desc = AX.string(v[3])
        if role == "AXStaticText", (AX.string(v[4]) ?? title ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return nil }

        return ScannedElement(
            element: el, role: role, subrole: subrole, title: title, desc: desc, value: AX.string(v[4]),
            help: AX.string(v[5]), placeholder: AX.string(v[6]), identifier: AX.string(v[7]),
            frame: visible, category: category(role: role, subrole: subrole), source: source)
    }

    static func category(role: String, subrole: String?) -> HintCategory {
        switch role {
        case "AXLink": .link
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField": .input
        case "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem",
            "AXMenuBarItem", "AXDisclosureTriangle", "AXTab", "AXDockItem", "AXIncrementor":
            .button
        default: .other
        }
    }

    /// Drops elements nested in an already-labelled element with nearly the same frame
    /// (e.g. an image inside a link), keeping the outer one.
    static func dedupe(_ items: [ScannedElement]) -> [ScannedElement] {
        var seen = FrameSet()
        return items.filter { seen.insert($0.frame) }
    }
}

/// Near-duplicate frame detection in O(1) per insert (spatial hash on the origin).
struct FrameSet {
    private var buckets: [Int64: [Rect]] = [:]
    private static let cell = 8.0

    private static func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: y))) }

    /// Returns false (and doesn't insert) if a near-identical frame is already present.
    mutating func insert(_ f: Rect) -> Bool {
        let cx = Int((f.x / Self.cell).rounded(.down)), cy = Int((f.y / Self.cell).rounded(.down))
        for dx in -1...1 {
            for dy in -1...1 {
                if let b = buckets[Self.key(cx + dx, cy + dy)],
                    b.contains(where: {
                        abs($0.x - f.x) < 3 && abs($0.y - f.y) < 3 && abs($0.width - f.width) < 4 && abs($0.height - f.height) < 4
                    })
                {
                    return false
                }
            }
        }
        buckets[Self.key(cx, cy), default: []].append(f)
        return true
    }
}
