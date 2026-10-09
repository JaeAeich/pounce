import AppKit
import ApplicationServices
import PounceCore
import WebKit

/// `pounce bench`: builds heavy fixture windows in-process and times AX scans of them.
/// Our own process serves its AX tree on the main thread, so scans run off-main while
/// the main run loop keeps spinning (same as against a real app).
@MainActor
final class Bench {
    private var windows: [NSWindow] = []
    private var webDelegate: WebLoadWaiter?
    private let runs: Int

    init(runs: Int = 7) { self.runs = runs }

    func run(completion: @escaping () -> Void) {
        Task {
            await runAll()
            windows.forEach { $0.close() }
            completion()
        }
    }

    private func runAll() async {
        let buttons = makeButtonsWindow(count: 2000)
        let table = makeTableWindow(rows: 10_000)
        let mixed = makeSmallWindow()
        let web = await makeWebWindow(links: 300)
        windows = [buttons, table, mixed] + (web.map { [$0] } ?? [])
        try? await Task.sleep(nanoseconds: 500_000_000)

        print(pad("scenario", 26) + pad("impl", 11) + "  cold ms   warm ms    min ms   found  vs legacy")
        print(String(repeating: "-", count: 74))
        for (name, title) in [
            ("small fixture", "Bench Small"), ("2000 buttons (stacks)", "Bench Buttons"),
            ("table 10k rows", "Bench Table"), ("webview 300 links", "Bench Web"),
        ] {
            guard let win = await axWindow(title) else {
                print("\(name): window not reachable via AX – skipped")
                continue
            }
            let frame = await Task.detached { win.frame }.value
            var reference: [String] = []
            for impl in ["legacy", "new", "new-4lanes"] {
                var times: [Double] = []
                var found = 0
                var sig: [String] = []
                var cold = 0.0
                for i in 0..<(runs + 1) {
                    let (ms, n, s) = await Task.detached { () -> (Double, Int, [String]) in
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        var o = Scanner.Options()
                        o.testLanes = impl == "new-4lanes" ? 4 : 0
                        let els =
                            impl == "legacy"
                            ? LegacyScanner.scan(roots: [(win, frame)], options: o, source: .window)
                            : Scanner.scan(roots: [(win, frame)], options: o, source: .window)
                        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                        return (ms, els.count, els.map { "\($0.role)|\($0.title ?? "")|\($0.desc ?? "")|\($0.value ?? "")|\($0.frame)" })
                    }.value
                    if i == 0 { cold = ms } else { times.append(ms) }
                    found = n
                    sig = s
                }
                times.sort()
                if impl == "legacy" { reference = sig }
                let same =
                    sig == reference
                    ? "identical" : Set(sig) == Set(reference) ? "same set" : "DIFFERS (\(Set(sig).symmetricDifference(reference).count))"
                print(
                    pad(name, 26) + pad(impl, 11) + String(format: "%9.1f %9.1f %9.1f %7d  ", cold, times[times.count / 2], times[0], found)
                        + same)
            }
        }
        // Streaming: time to first batch.
        if let win = await axWindow("Bench Buttons") {
            let frame = await Task.detached { win.frame }.value
            let (first, total, n) = await Task.detached { () -> (Double, Double, Int) in
                let t0 = DispatchTime.now().uptimeNanoseconds
                var first = 0.0
                let els = Scanner.scan(roots: [(win, frame)], options: Scanner.Options(), source: .window) { batch in
                    if first == 0, !batch.isEmpty { first = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 }
                }
                return (first, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6, els.count)
            }.value
            print(String(format: "\nstreaming 2000 buttons: first batch %.1f ms, done %.1f ms, %d elements", first, total, n))
        }
        let appScan = await Task.detached { () -> (Double, Int) in
            let t0 = Clock.now
            let n = Scanner.scanApp(pid: getpid(), options: Scanner.Options()).count
            return (Double(Clock.now - t0) / 1e6, n)
        }.value
        print(String(format: "scanApp(self, front window): %.1f ms, %d elements\n", appScan.0, appScan.1))
        // System-wide sources (other apps answer only with Accessibility permission).
        let system: [(String, @Sendable () -> Int)] = [
            ("menu extras legacy", { LegacyScanner.scanMenuExtras().count }),
            ("menu extras", { Scanner.scanMenuExtras().count }),
            ("window switcher", { WindowScanner.scan().count }),
        ]
        for (name, fn) in system {
            var times: [Double] = []
            var n = 0
            for _ in 0..<5 {
                let (ms, c) = await Task.detached { () -> (Double, Int) in
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    let c = fn()
                    return (Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6, c)
                }.value
                times.append(ms)
                n = c
            }
            print(pad(name, 26) + String(format: "first %7.1f ms, median %7.1f ms, %d found", times[0], times.sorted()[2], n))
        }
        print("(AX trusted: \(AX.isTrusted))")
    }

    private func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: max(n, s.count + 1), withPad: " ", startingAt: 0) }

    private func axWindow(_ title: String) async -> AXUIElement? {
        await Task.detached {
            AXUIElement.app(getpid()).elements("AXWindows").first { $0.string("AXTitle") == title }
        }.value
    }

    // MARK: Fixtures

    private func window(_ title: String, _ size: CGSize, at origin: CGPoint) -> NSWindow {
        let w = Quiet.window(contentRect: CGRect(origin: origin, size: size), styleMask: [.titled])
        w.title = title
        w.isReleasedWhenClosed = false
        w.orderFrontRegardless()
        return w
    }

    private func makeSmallWindow() -> NSWindow {
        let w = window("Bench Small", CGSize(width: 420, height: 200), at: CGPoint(x: 40, y: 40))
        for i in 0..<8 {
            let b = NSButton(title: "Small \(i)", target: nil, action: nil)
            b.frame = CGRect(x: 10 + (i % 4) * 100, y: 20 + (i / 4) * 40, width: 90, height: 30)
            w.contentView!.addSubview(b)
        }
        return w
    }

    private func makeButtonsWindow(count: Int) -> NSWindow {
        let cols = 40
        let w = window("Bench Buttons", CGSize(width: cols * 22 + 20, height: (count / cols) * 17 + 20), at: CGPoint(x: 20, y: 20))
        let outer = NSStackView()
        outer.orientation = .vertical
        outer.spacing = 1
        var i = 0
        while i < count {
            let group = NSStackView()  // nested: group → rows → buttons
            group.orientation = .vertical
            group.spacing = 1
            for _ in 0..<5 where i < count {
                let row = NSStackView()
                row.orientation = .horizontal
                row.spacing = 1
                for _ in 0..<cols where i < count {
                    let b = NSButton(title: "\(i)", target: nil, action: nil)
                    b.bezelStyle = .inline
                    b.controlSize = .mini
                    b.font = .systemFont(ofSize: 7)
                    b.translatesAutoresizingMaskIntoConstraints = false
                    b.widthAnchor.constraint(equalToConstant: 21).isActive = true
                    b.heightAnchor.constraint(equalToConstant: 15).isActive = true
                    row.addArrangedSubview(b)
                    i += 1
                }
                group.addArrangedSubview(row)
            }
            outer.addArrangedSubview(group)
        }
        outer.frame = w.contentView!.bounds.insetBy(dx: 5, dy: 5)
        outer.autoresizingMask = [.width, .height]
        w.contentView!.addSubview(outer)
        return w
    }

    private func makeTableWindow(rows: Int) -> NSWindow {
        let w = window("Bench Table", CGSize(width: 520, height: 800), at: CGPoint(x: 960, y: 20))
        let scroll = NSScrollView(frame: w.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        let table = NSTableView()
        for (id, width) in [("name", 300.0), ("action", 160.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.width = width
            table.addTableColumn(c)
        }
        let source = BenchTableSource(rows: rows)
        objc_setAssociatedObject(table, "src", source, .OBJC_ASSOCIATION_RETAIN)
        table.dataSource = source
        table.delegate = source
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        w.contentView!.addSubview(scroll)
        return w
    }

    private func makeWebWindow(links: Int) async -> NSWindow? {
        let w = window("Bench Web", CGSize(width: 700, height: 800), at: CGPoint(x: 300, y: 60))
        let web = WKWebView(frame: w.contentView!.bounds)
        web.autoresizingMask = [.width, .height]
        w.contentView!.addSubview(web)
        var html = "<html><body style='font:11px sans-serif'>"
        for i in 0..<links { html += "<a href='#\(i)' style='display:inline-block;width:60px'>link \(i)</a> " }
        html += "<p><button>Go</button> <input placeholder='Search'> <input type=checkbox></p></body></html>"
        let waiter = WebLoadWaiter()
        webDelegate = waiter
        web.navigationDelegate = waiter
        web.loadHTMLString(html, baseURL: nil)
        await waiter.wait(timeout: 3)
        return w
    }
}

private final class BenchTableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let rows: Int
    init(rows: Int) { self.rows = rows }
    func numberOfRows(in tableView: NSTableView) -> Int { rows }
    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        if col?.identifier.rawValue == "action" {
            let b = NSButton(title: "Open \(row)", target: nil, action: nil)
            b.controlSize = .small
            return b
        }
        return NSTextField(labelWithString: "Row \(row) of the big table")
    }
}

@MainActor
private final class WebLoadWaiter: NSObject, WKNavigationDelegate {
    private var cont: CheckedContinuation<Void, Never>?
    private var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    private func finish() {
        done = true
        cont?.resume()
        cont = nil
    }
    func wait(timeout: Double) async {
        if done { return }
        await withCheckedContinuation { c in
            cont = c
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish() }
        }
    }
}

// MARK: - Legacy scanner (pre-optimisation copy, for old-vs-new numbers)

enum LegacyScanner {
    static let attributes = Scanner.attributes

    static func scan(roots: [(AXUIElement, Rect?)], options: Scanner.Options, source: HintSource) -> [ScannedElement] {
        let deadline = Date().addingTimeInterval(options.deadline)
        let screens = Screens.union
        var jobs: [(AXUIElement, Rect, Int)] = []
        var results: [ScannedElement] = []
        for (root, frame) in roots {
            let clip = (frame ?? screens).intersection(screens)
            let rootClip = clip.isEmpty ? screens : clip
            if let e = makeElement(root, values: root.values(attributes), clip: rootClip, options: options, source: source) {
                results.append(e)
            }
            for child in root.elements("AXChildren") { jobs.append((child, rootClip, 1)) }
        }
        let lock = NSLock()
        var buckets = [[ScannedElement]](repeating: [], count: jobs.count)
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            var local: [ScannedElement] = []
            var budget = options.maxElements
            walk(
                jobs[i].0, clip: jobs[i].1, depth: jobs[i].2, options: options, source: source, deadline: deadline, budget: &budget,
                into: &local)
            lock.lock()
            buckets[i] = local
            lock.unlock()
        }
        results += buckets.joined()
        return Scanner.dedupe(Array(results.prefix(options.maxElements)))
    }

    private static func walk(
        _ el: AXUIElement, clip: Rect, depth: Int, options: Scanner.Options, source: HintSource,
        deadline: Date, budget: inout Int, into out: inout [ScannedElement]
    ) {
        guard depth <= options.maxDepth, budget > 0, Date() < deadline else { return }
        let v = el.values(attributes)
        guard let role = v[0] as? String else { return }
        if Scanner.skipSubtreeRoles.contains(role) { return }
        let frame = AX.frame(position: v[8], size: v[9])
        var childClip = clip
        if let f = frame, !f.isEmpty {
            let visible = f.intersection(clip)
            if visible.isEmpty { return }
            if Scanner.clipRoles.contains(role) { childClip = visible }
        }
        if let e = makeElement(el, values: v, clip: clip, options: options, source: source) {
            out.append(e)
            budget -= 1
        }
        guard let children = v[11] as? [AXUIElement] else { return }
        for child in children {
            walk(
                child, clip: childClip, depth: depth + 1, options: options, source: source, deadline: deadline, budget: &budget, into: &out)
        }
    }

    static func makeElement(
        _ el: AXUIElement, values v: [CFTypeRef?], clip: Rect, options: Scanner.Options, source: HintSource
    ) -> ScannedElement? {
        guard let role = v[0] as? String else { return nil }
        if (v[10] as? NSNumber)?.boolValue == false { return nil }
        guard let frame = AX.frame(position: v[8], size: v[9]), frame.width >= 2, frame.height >= 2 else { return nil }
        let visible = frame.intersection(clip)
        guard visible.area >= 4 else { return nil }
        var include = Scanner.clickableRoles.contains(role)
        if !include, options.mode == .exhaustive {
            include = Scanner.exhaustiveExtraRoles.contains(role) || !Scanner.pressActions.isDisjoint(with: el.actions)
        }
        let subrole = v[1] as? String
        if role == "AXRow" && options.mode == .fast { include = false }
        guard include else { return nil }
        let title = AX.string(v[2]), desc = AX.string(v[3])
        if role == "AXStaticText", (AX.string(v[4]) ?? title ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        return ScannedElement(
            element: el, role: role, subrole: subrole, title: title, desc: desc, value: AX.string(v[4]),
            help: AX.string(v[5]), placeholder: AX.string(v[6]), identifier: AX.string(v[7]),
            frame: visible, category: Scanner.category(role: role, subrole: subrole), source: source)
    }

    static func scanMenuExtras() -> [ScannedElement] {
        let pids = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }.map(\.processIdentifier)
        let lock = NSLock()
        var out: [ScannedElement] = []
        DispatchQueue.concurrentPerform(iterations: pids.count) { i in
            let app = AXUIElement.app(pids[i])
            app.setTimeout(0.08)
            guard let extras = app.element("AXExtrasMenuBar") else { return }
            let items = extras.elements("AXChildren").compactMap {
                makeElement(
                    $0, values: $0.values(attributes), clip: Screens.union, options: Scanner.Options(mode: .exhaustive), source: .extras)
            }
            lock.lock()
            out += items
            lock.unlock()
        }
        return out
    }
}
