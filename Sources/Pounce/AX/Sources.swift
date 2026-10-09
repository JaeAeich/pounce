import AppKit
import ApplicationServices
import PounceCore
import ScreenCaptureKit
import Vision

// MARK: - Scroll areas

struct ScrollArea: @unchecked Sendable {
    let element: AXUIElement
    let frame: Rect
    var verticalBar: AXUIElement? { element.element("AXVerticalScrollBar") }
}

enum ScrollScanner {
    static func scan(pid: pid_t) -> [ScrollArea] {
        let app = AXUIElement.app(pid)
        app.setTimeout(0.5)
        guard let win = app.element("AXFocusedWindow") ?? app.element("AXMainWindow") else { return [] }
        return scan(window: win)
    }

    static func scan(window win: AXUIElement) -> [ScrollArea] {
        let winFrame = win.fastFrame ?? Screens.union
        var out: [ScrollArea] = []
        var visited = 0
        var useFrame = true
        // Same tricks as the hint scanner: AXFrame instead of position+size, children of
        // scroll areas fetched once their role is known, tables/lists walk visible rows only.
        func walk(_ el: AXUIElement, depth: Int, deferKids: Bool) {
            guard depth < 40, visited < 4000 else { return }
            visited += 1
            var attrs = useFrame ? ["AXRole", "AXFrame", "AXChildren"] : ["AXRole", "AXPosition", "AXSize", "AXChildren"]
            if deferKids { attrs.removeLast() }
            let v = el.values(attrs)
            guard let roleRef = v[0], CFGetTypeID(roleRef) == CFStringGetTypeID() else { return }
            let role = roleRef as! NSString
            let flags = RoleFlags.of(role)
            var f = useFrame ? AX.rect(v[1]) : AX.frame(position: v[1], size: v[2])
            if f == nil, useFrame {
                let ps = el.values(["AXPosition", "AXSize"])
                f = AX.frame(position: ps[0], size: ps[1])
                if f != nil { useFrame = false }
            }
            if let f, !f.isEmpty {
                let vis = f.intersection(winFrame)
                if vis.isEmpty { return }
                if flags.contains(.scrollArea), vis.width > 80, vis.height > 60 {
                    out.append(ScrollArea(element: el, frame: vis))
                }
            }
            let fetched = deferKids ? nil : v[attrs.count - 1] as? [AXUIElement]
            for c in ScanRun.children(of: el, flags: flags, fetched: fetched, deferred: deferKids) {
                walk(c, depth: depth + 1, deferKids: flags.contains(.scrollArea))
            }
        }
        walk(win, depth: 0, deferKids: false)
        // Biggest first, but nested duplicates (same frame) collapse to the outer one.
        var unique: [ScrollArea] = []
        for a in out.sorted(by: { $0.frame.area > $1.frame.area })
        where !unique.contains(where: { $0.frame == a.frame }) {
            unique.append(a)
        }
        return unique
    }
}

// MARK: - Windows

struct WindowInfo: @unchecked Sendable {
    /// Why a window is (not) on screen. Everything but `.visible` goes into Windows mode's list.
    enum State: Int, Comparable {
        case visible
        /// Parked off screen by a tiling WM (AeroSpace hides other workspaces this way).
        case parked
        /// On another Space (CGWindowList knows it, it isn't on screen).
        case otherSpace
        case minimized
        case appHidden
        static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }
    }

    /// nil for windows only CGWindowList knows (other Spaces): focused via app activation.
    let element: AXUIElement?
    let app: NSRunningApplication
    let title: String
    /// AX frame (global top-left); off screen for parked windows.
    let frame: Rect
    var state: State = .visible
    var windowID: CGWindowID = 0

    var isVisible: Bool { state == .visible }
    /// The part of the window on its screen (badge placement, scan clip).
    var visibleFrame: Rect { WindowVisibility.visiblePart(frame, screens: NSScreen.screens.map(Screens.topLeft)) }

    /// Short reason shown in the list ("hidden", "minimized"…), nil when visible.
    var stateText: String? {
        switch state {
        case .visible: nil
        case .parked: "hidden"
        case .otherSpace: "other Space"
        case .minimized: "minimized"
        case .appHidden: "app hidden"
        }
    }
}

/// Private but long-stable (used by every window manager): the CGWindowID behind an AX window.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum WindowScanner {
    /// Standard windows of all regular apps: on-screen ones front-to-back first, then hidden
    /// ones (parked by a tiling WM, other Spaces, minimized, hidden apps).
    ///
    /// Visible = at least 10% and 40×40 pt on one screen (`WindowVisibility`): AeroSpace parks
    /// hidden-workspace windows with ~1 px on screen, and CGWindowList still calls them on-screen.
    /// Spaces: AX only lists windows on the current Space for most apps. Windows on other Spaces
    /// are taken from CGWindowList (`.optionAll`, no public workspace id) only when they have a
    /// title (needs Screen Recording) and their app has no AX-visible window, since ordered-out
    /// (closed but alive) windows look the same there.
    static func scan(includeHidden: Bool = true) -> [WindowInfo] {
        struct CGWin {
            let id: CGWindowID
            let pid: pid_t
            let bounds: Rect
            let onScreen: Bool
            let name: String?
            let z: Int
        }
        let opts: CGWindowListOption =
            includeHidden ? [.optionAll, .excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements]
        let list = (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []
        var cg: [CGWin] = []
        for (i, w) in list.enumerated() where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int, let num = w[kCGWindowNumber as String] as? Int,
                let b = w[kCGWindowBounds as String] as? [String: Double], (w[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { continue }
            let r = Rect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            let on = includeHidden ? (w[kCGWindowIsOnscreen as String] as? Bool ?? false) : true
            cg.append(
                CGWin(id: CGWindowID(num), pid: pid_t(pid), bounds: r, onScreen: on, name: w[kCGWindowName as String] as? String, z: i))
        }
        var byID: [CGWindowID: CGWin] = [:]
        var bySig: [String: CGWin] = [:]
        for w in cg {
            byID[w.id] = w
            let k = sig(Int(w.pid), w.bounds.x, w.bounds.y, w.bounds.width, w.bounds.height)
            if bySig[k] == nil { bySig[k] = w }
        }
        // Only ask apps that own a window-sized window somewhere (skips dozens of idle apps).
        var owners = Set<pid_t>()
        for w in cg where w.bounds.width >= 100 && w.bounds.height >= 60 && (includeHidden || w.onScreen) { owners.insert(w.pid) }
        let me = getpid()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me && owners.contains($0.processIdentifier)
                && (includeHidden || !$0.isHidden)
        }
        let screens = NSScreen.screens.map(Screens.topLeft)
        let lock = NSLock()
        var found: [(WindowInfo, Int)] = []
        var axCount: [pid_t: Int] = [:]
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let app = apps[i]
            let ax = AXUIElement.app(app.processIdentifier)
            ax.setTimeout(0.25)
            var mine: [(WindowInfo, Int)] = []
            for w in ax.elements("AXWindows") {
                let v = w.values(["AXRole", "AXSubrole", "AXTitle", "AXFrame", "AXMinimized"])
                guard v[0] as? String == "AXWindow", let f = AX.rect(v[3]) ?? w.frame, f.width > 60, f.height > 40 else { continue }
                let sub = v[1] as? String
                if let sub, sub != "AXStandardWindow", sub != "AXDialog" { continue }
                var id: CGWindowID = 0
                _ = _AXUIElementGetWindow(w, &id)
                let c = (id != 0 ? byID[id] : nil) ?? bySig[sig(Int(app.processIdentifier), f.x, f.y, f.width, f.height)]
                let state: WindowInfo.State
                if (v[4] as? NSNumber)?.boolValue == true {
                    state = .minimized
                } else if app.isHidden {
                    state = .appHidden
                } else if let c, c.onScreen {
                    state = WindowVisibility.isVisible(f, screens: screens) ? .visible : .parked
                } else if c != nil {
                    state = .otherSpace
                } else {
                    continue  // no window server window: not a real window
                }
                if !includeHidden && state != .visible { continue }
                let title = (v[2] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? app.localizedName ?? "Window"
                mine.append(
                    (WindowInfo(element: w, app: app, title: title, frame: f, state: state, windowID: c?.id ?? id), c?.z ?? Int.max))
            }
            lock.lock()
            found += mine
            axCount[app.processIdentifier] = mine.count
            lock.unlock()
        }
        if includeHidden {
            let byPid = Dictionary(apps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
            for w in cg where !w.onScreen && w.bounds.width >= 300 && w.bounds.height >= 200 {
                guard let app = byPid[w.pid], !app.isHidden, axCount[w.pid] == 0, let name = w.name, !name.isEmpty else { continue }
                found.append((WindowInfo(element: nil, app: app, title: name, frame: w.bounds, state: .otherSpace, windowID: w.id), w.z))
            }
        }
        return found.sorted { ($0.0.state, $0.1) < ($1.0.state, $1.1) }.map(\.0)
    }

    private static func sig(_ pid: Int, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> String {
        "\(pid):\(Int(x.rounded())),\(Int(y.rounded())),\(Int(w.rounded())),\(Int(h.rounded()))"
    }

    /// Brings the window forward. AeroSpace follows the focus change and switches workspace;
    /// macOS switches Space when an app with windows only on another Space is activated.
    static func focus(_ w: WindowInfo) {
        if w.app.isHidden { w.app.unhide() }
        if let el = w.element {
            if w.state == .minimized { el.set("AXMinimized", kCFBooleanFalse) }
            el.perform("AXRaise")
            el.set("AXMain", kCFBooleanTrue)
        }
        w.app.activate(options: [])
    }

    static func apply(_ op: WindowOp, to w: WindowInfo) {
        let screen = Screens.screen(for: w.frame)
        var target = screen
        if op == .nextScreen, NSScreen.screens.count > 1, let i = NSScreen.screens.firstIndex(of: screen) {
            target = NSScreen.screens[(i + 1) % NSScreen.screens.count]
        }
        let vf = Screens.topLeftVisible(target)
        let r: Rect =
            switch op {
            case .leftHalf: Rect(x: vf.x, y: vf.y, width: vf.width / 2, height: vf.height)
            case .rightHalf: Rect(x: vf.x + vf.width / 2, y: vf.y, width: vf.width / 2, height: vf.height)
            case .maximize: vf
            case .nextScreen:
                // Keep relative position/size on the new screen.
                {
                    let from = Screens.topLeftVisible(screen)
                    let sx = vf.width / from.width, sy = vf.height / from.height
                    return Rect(
                        x: vf.x + (w.frame.x - from.x) * sx, y: vf.y + (w.frame.y - from.y) * sy,
                        width: w.frame.width * sx, height: w.frame.height * sy)
                }()
            }
        w.element?.setFrame(r)
        focus(w)
    }
}

// MARK: - Menu items

struct MenuEntry: @unchecked Sendable {
    let element: AXUIElement
    let path: [String]
    let shortcut: String?
    var title: String { path.last ?? "" }
}

enum MenuScanner {
    static func scan(pid: pid_t) -> [MenuEntry] {
        let app = AXUIElement.app(pid)
        app.setTimeout(0.5)
        guard let bar = app.element("AXMenuBar") else { return [] }
        let tops = bar.elements("AXChildren").dropFirst()  // skip the Apple menu
        let lock = NSLock()
        var all: [[MenuEntry]] = Array(repeating: [], count: tops.count)
        let topArr = Array(tops)
        DispatchQueue.concurrentPerform(iterations: topArr.count) { i in
            var out: [MenuEntry] = []
            let top = topArr[i]
            let tv = top.values(["AXTitle", "AXChildren"])
            let name = tv[0] as? String ?? ""
            for menu in (tv[1] as? [AXUIElement]) ?? [] { walk(menu, path: [name], depth: 0, into: &out) }
            lock.lock()
            all[i] = out
            lock.unlock()
        }
        return all.flatMap { $0 }
    }

    private static func walk(_ menu: AXUIElement, path: [String], depth: Int, into out: inout [MenuEntry]) {
        guard depth < 6 else { return }
        for item in menu.elements("AXChildren") {
            let v = item.values([
                "AXTitle", "AXEnabled", "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXChildren", "AXMenuItemCmdVirtualKey",
            ])
            guard let title = v[0] as? String, !title.isEmpty else { continue }
            let children = (v[4] as? [AXUIElement]) ?? []
            if let sub = children.first {
                walk(sub, path: path + [title], depth: depth + 1, into: &out)
                continue
            }
            guard (v[1] as? NSNumber)?.boolValue != false else { continue }
            out.append(
                MenuEntry(
                    element: item, path: path + [title],
                    shortcut: shortcutString(
                        char: v[2] as? String, mods: (v[3] as? NSNumber)?.intValue, vkey: (v[5] as? NSNumber)?.intValue)))
        }
    }

    /// AXMenuItemCmdModifiers: bit0 shift, bit1 option, bit2 control, bit3 = NO command.
    static func shortcutString(char: String?, mods: Int?, vkey: Int?) -> String? {
        var key = char.flatMap { $0.isEmpty ? nil : $0.uppercased() }
        if key == nil, let vk = vkey { key = KeyCodes.displayName(for: UInt16(vk)) }
        guard let k = key, k != "\u{0}" else { return nil }
        let m = mods ?? 0
        var s = ""
        if m & 4 != 0 { s += "⌃" }
        if m & 2 != 0 { s += "⌥" }
        if m & 1 != 0 { s += "⇧" }
        if m & 8 == 0 { s += "⌘" }
        return s + k
    }
}

// MARK: - On-screen text (OCR)

struct TextBox: Sendable {
    let text: String
    let frame: Rect
}

enum TextScanError: LocalizedError {
    case noPermission
    case nothingToCapture
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noPermission: "Text mode needs Screen Recording permission"
        case .nothingToCapture: "No window or display to read text from"
        case .failed(let s): "Couldn’t capture the screen: \(s)"
        }
    }
}

enum TextScanner {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Recognises words in the app's focused window (`windowFrame`, from AX), else the display
    /// under the mouse. Boxes are clipped to the screens.
    static func scan(pid: pid_t, windowFrame: Rect?) async throws -> [TextBox] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            if !hasPermission { throw TextScanError.noPermission }
            throw TextScanError.failed(error.localizedDescription)
        }
        let screenRect: Rect
        let filter: SCContentFilter
        if let win = window(in: content, pid: pid, frame: windowFrame) {
            filter = SCContentFilter(desktopIndependentWindow: win)
            screenRect = Rect(x: win.frame.minX, y: win.frame.minY, width: win.frame.width, height: win.frame.height)
        } else if let d = displayUnderMouse(content) {
            filter = SCContentFilter(display: d, excludingWindows: [])
            screenRect = Rect(x: d.frame.minX, y: d.frame.minY, width: d.frame.width, height: d.frame.height)
        } else {
            throw TextScanError.nothingToCapture
        }
        let config = SCStreamConfiguration()
        let scale = Screens.screen(for: screenRect).backingScaleFactor
        config.width = Int(screenRect.width * scale)
        config.height = Int(screenRect.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            if !hasPermission { throw TextScanError.noPermission }
            throw TextScanError.failed(error.localizedDescription)
        }
        let screens = NSScreen.screens.map(Screens.topLeft)
        return try recognize(image, in: screenRect).compactMap { b in
            // Parts of the window off screen (or under the menu bar of another display) can't be clicked.
            let v = WindowVisibility.visiblePart(b.frame, screens: screens)
            return v.width >= 3 && v.height >= 3 ? TextBox(text: b.text, frame: v) : nil
        }
    }

    /// The SCWindow behind the AX focused window: same frame (±2 pt), else the largest overlap.
    /// nil when there's no AX frame or nothing of the app's matches (caller falls back to a display).
    static func window(in content: SCShareableContent, pid: pid_t, frame: Rect?) -> SCWindow? {
        guard let frame else { return nil }
        let mine = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 50 }
        func r(_ w: SCWindow) -> Rect { Rect(x: w.frame.minX, y: w.frame.minY, width: w.frame.width, height: w.frame.height) }
        if let exact = mine.first(where: { w in
            let f = r(w)
            return abs(f.x - frame.x) <= 2 && abs(f.y - frame.y) <= 2 && abs(f.width - frame.width) <= 2
                && abs(f.height - frame.height) <= 2
        }) {
            return exact
        }
        let best = mine.max { r($0).intersection(frame).area < r($1).intersection(frame).area }
        return best.flatMap { r($0).intersection(frame).area > frame.area * 0.5 ? $0 : nil }
    }

    static func displayUnderMouse(_ content: SCShareableContent) -> SCDisplay? {
        let m = Screens.mouse
        var id: CGDirectDisplayID = 0
        var n: UInt32 = 0
        if CGGetDisplaysWithPoint(CGPoint(x: m.x, y: m.y), 1, &id, &n) == .success, n > 0,
            let d = content.displays.first(where: { $0.displayID == id })
        {
            return d
        }
        return content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first
    }

    /// The user's preferred languages that Vision can read, plus English.
    static let languages: [String] = {
        let supported = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? ["en-US"]
        return OCRLanguages.pick(preferred: Locale.preferredLanguages, supported: supported)
    }()

    static func recognize(_ image: CGImage, in rect: Rect) throws -> [TextBox] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        // Word boxes are what we click; correction only fixes the recognised spelling.
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        var out: [TextBox] = []
        for obs in request.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            let s = cand.string
            // One box per word so you can click a specific word.
            var found = false
            s.enumerateSubstrings(in: s.startIndex..., options: .byWords) { word, range, _, _ in
                guard let word, let box = try? cand.boundingBox(for: range) else { return }
                out.append(TextBox(text: word, frame: convert(box.boundingBox, rect)))
                found = true
            }
            if !found { out.append(TextBox(text: s, frame: convert(obs.boundingBox, rect))) }
        }
        return out
    }

    /// Vision boxes are normalised with a bottom-left origin.
    private static func convert(_ b: CGRect, _ r: Rect) -> Rect {
        Rect(x: r.x + b.minX * r.width, y: r.y + (1 - b.maxY) * r.height, width: b.width * r.width, height: b.height * r.height)
    }
}
