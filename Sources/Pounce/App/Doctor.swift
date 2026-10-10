import AppKit
import ApplicationServices
import PounceCore

/// `pounce doctor [bundle-id]`: the running (trusted) app scans another app and sends back a
/// diagnostic report, so scanning problems in real apps can be debugged from a terminal.
enum Doctor {
    /// `done` gets the report (or a line starting with "error:") on the main queue.
    static func run(target: String?, state: String = "", done: @escaping (String) -> Void) {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != getpid() }
        let app: NSRunningApplication?
        if let t = target?.lowercased() {
            // An explicit target that isn't running is an error, never a silent fallback to the front app.
            app = apps.first { $0.bundleIdentifier?.lowercased() == t } ?? apps.first { $0.localizedName?.lowercased() == t }
            guard app != nil else { return done("error: no running app with bundle id '\(target!)'\n") }
        } else {
            app = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == getpid() ? nil : $0 }
        }
        guard let app else { return done("error: no frontmost app to diagnose (pass a bundle id)\n") }
        let pid = app.processIdentifier
        let firstPrepare = AppSupport.prepare(app)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (firstPrepare ? 0.5 : 0)) {
            let text = "state: \(state)\n" + report(app: app, pid: pid, firstPrepare: firstPrepare)
            DispatchQueue.main.async { done(text) }
        }
    }

    private static func ms(_ t0: UInt64) -> String { String(format: "%.1f ms", Double(Clock.now - t0) / 1e6) }

    private static func histogram(_ els: [ScannedElement]) -> String {
        Dictionary(grouping: els, by: \.role).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " ")
    }

    private static func sample(_ els: [ScannedElement], _ n: Int = 25) -> String {
        els.prefix(n).map { e in
            let name = [e.title, e.desc, e.value, e.placeholder].compactMap { $0 }.first { !$0.isEmpty } ?? "–"
            return "    \(e.role) “\(name.prefix(50))” @\(Int(e.frame.x)),\(Int(e.frame.y)) \(Int(e.frame.width))×\(Int(e.frame.height))"
        }.joined(separator: "\n")
    }

    private static func report(app: NSRunningApplication, pid: pid_t, firstPrepare: Bool) -> String {
        var r: [String] = []
        r.append("Pounce doctor — \(Date())")
        r.append("trusted: \(AX.isTrusted)")
        r.append("app: \(app.localizedName ?? "?") \(app.bundleIdentifier ?? "?") pid \(pid), prepared first time: \(firstPrepare)")
        let ax = AXUIElement.app(pid)
        ax.setTimeout(1)
        r.append(
            "AXManualAccessibility: \(String(describing: ax.value("AXManualAccessibility"))), AXEnhancedUserInterface: \(String(describing: ax.value("AXEnhancedUserInterface")))"
        )
        let roots = Scanner.appRoots(pid: pid)
        r.append("roots: \(roots.count)")
        for (el, f) in roots {
            r.append(
                "  root \(el.string("AXRole") ?? "?") “\(el.string("AXTitle") ?? "")” frame \(String(describing: f)) AXFrame=\(String(describing: el.value("AXFrame")))"
            )
        }

        func dump(_ el: AXUIElement, _ d: Int, _ budget: inout Int) {
            guard budget > 0, d < 14 else { return }
            budget -= 1
            let v = el.values(["AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXChildren", "AXFrame"])
            let kids = (v[4] as? [AXUIElement]) ?? []
            var names: CFArray?
            AXUIElementCopyAttributeNames(el, &names)
            let extra = ((names as? [String]) ?? []).filter { $0.contains("Web") || $0.contains("Children") || $0.contains("Contents") }
            r.append(
                String(repeating: "  ", count: d)
                    + "\(v[0] as? String ?? "?")/\(v[1] as? String ?? "") “\((v[2] as? String ?? v[3] as? String ?? "").prefix(30))” kids=\(kids.count) \(extra)"
            )
            for k in kids { dump(k, d + 1, &budget) }
        }
        r.append("tree (first 80 nodes):")
        var budget = 80
        for (el, _) in Scanner.appRoots(pid: pid) { dump(el, 1, &budget) }
        // Find web areas by a bounded BFS.
        var webAreas: [AXUIElement] = []
        var queue = roots.map(\.0)
        var visited = 0
        let tBFS = Clock.now
        while !queue.isEmpty, visited < 4000, webAreas.count < 4 {
            let el = queue.removeFirst()
            visited += 1
            let v = el.values(["AXRole", "AXChildren"])
            if (v[0] as? String) == "AXWebArea" {
                webAreas.append(el)
                continue
            }
            queue += (v[1] as? [AXUIElement]) ?? []
        }
        r.append("web areas: \(webAreas.count) (visited \(visited) nodes in \(ms(tBFS)))")
        for (i, w) in webAreas.enumerated() {
            r.append(
                "  web[\(i)] “\(w.string("AXTitle") ?? w.string("AXDescription") ?? "")” frame \(String(describing: w.frame)) children \(w.elements("AXChildren").count)"
            )
            var names: CFArray?
            AXUIElementCopyParameterizedAttributeNames(w, &names)
            r.append("    params: \((names as? [String])?.joined(separator: " ") ?? "none")")
            for keys in [
                ["AXLinkSearchKey", "AXButtonSearchKey", "AXControlSearchKey", "AXTextFieldSearchKey", "AXCheckBoxSearchKey"],
                ["AXLinkSearchKey"], ["AXAnyTypeSearchKey"],
            ] {
                for visibleOnly in [true, false] {
                    let params: [String: Any] = [
                        "AXSearchKey": keys.count == 1 ? keys[0] as Any : keys as Any, "AXVisibleOnly": visibleOnly,
                        "AXResultsLimit": 3000, "AXDirection": "AXDirectionNext", "AXImmediateDescendantsOnly": false,
                    ]
                    var out: CFTypeRef?
                    let t0 = Clock.now
                    let err = AXUIElementCopyParameterizedAttributeValue(
                        w, "AXUIElementsForSearchPredicate" as CFString, params as CFDictionary, &out)
                    let found = out as? [AXUIElement] ?? []
                    let roles = Dictionary(grouping: found.prefix(400)) { $0.string("AXRole") ?? "?" }.map { "\($0.key)=\($0.value.count)" }
                        .sorted().joined(separator: " ")
                    r.append(
                        "    search \(keys.count == 1 ? keys[0] : "combined") visibleOnly=\(visibleOnly): err \(err.rawValue) count \(found.count) in \(ms(t0)) [\(roles)]"
                    )
                }
            }
        }

        for (label, mode, web) in [
            ("fast+websearch", ScanMode.fast, true), ("fast walk", .fast, false), ("exhaustive", .exhaustive, false),
        ] {
            var o = Scanner.Options()
            o.mode = mode
            o.webSearch = web
            let t0 = Clock.now
            let els = Scanner.scanApp(pid: pid, options: o)
            r.append("\nscan \(label): \(els.count) elements in \(ms(t0))")
            r.append("  roles: \(histogram(els))")
            r.append(sample(els))
        }
        return r.joined(separator: "\n") + "\n"
    }
}
