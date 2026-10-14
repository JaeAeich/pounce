import AppKit
import PounceCore
import SwiftUI

/// Renders a SwiftUI view to a PNG via a borderless window (see `renderWindow`).
@MainActor
func renderPNG<V: View>(_ view: V, size: CGSize, to url: URL, appearance: NSAppearance.Name = .darkAqua) throws {
    let host = NSHostingView(
        rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.controlActiveState, .key).environment(\.appearsActive, true))
    let win: NSWindow =
        Quiet.enabled
        ? Quiet.Panel(
            contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        : PounceWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = host
    try renderWindow(win, to: url, appearance: appearance)
}

/// Captures a real window as the window server composites it (title bar, toolbar, sidebar
/// vibrancy, Liquid Glass). The window is ordered in behind everything for a moment.
/// Falls back to `cacheDisplay` (which drops materials) if no image is available.
@MainActor
func renderWindow(_ win: NSWindow, to url: URL, appearance: NSAppearance.Name = .darkAqua) throws {
    win.appearance = NSAppearance(named: appearance)
    win.isReleasedWhenClosed = false
    if Quiet.enabled {
        (win as? NSPanel)?.hidesOnDeactivate = false
        win.setFrameOrigin(Quiet.offscreen)  // composited (capturable) but never on a screen
        win.orderFrontRegardless()
    } else {
        if let screen = NSScreen.main {
            win.setFrameOrigin(CGPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40))
        }
        win.orderBack(nil)
    }
    win.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.7))
    win.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    defer { win.orderOut(nil) }
    var png: Data?
    if let cg = windowImage(win) {
        png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    } else if let v = win.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
        v.cacheDisplay(in: v.bounds, to: rep)
        png = rep.representation(using: .png, properties: [:])
    }
    guard let png else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: url)
}

/// Rasterises a layer tree (CALayer.render) into an image of `size` points.
@MainActor
func renderLayer(_ layer: CALayer, size: CGSize, scale: CGFloat) -> NSImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard
        let ctx = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return NSImage() }
    ctx.scaleBy(x: scale, y: scale)
    layer.render(in: ctx)
    guard let img = ctx.makeImage() else { return NSImage() }
    return NSImage(cgImage: img, size: size)
}

/// The composited image of one of our own windows (no Screen Recording permission needed for own windows).
@MainActor
/// `full`: capture the window's whole frame instead of trimming to its drawn content.
func windowImage(_ w: NSWindow, full: Bool = false) -> CGImage? {
    typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    // Looked up dynamically: the symbol is marked obsolete in newer SDKs but still works for own windows.
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
    let f = unsafeBitCast(sym, to: Fn.self)
    let opts = CGWindowListOption.optionIncludingWindow.rawValue
    let img = CGWindowImageOption([.bestResolution]).rawValue
    // Off-screen (quiet) windows can only be captured unbounded; they carry corner markers so the
    // trimmed image still spans the whole window (see OverlayController.makeScreen).
    let rect = full && !Quiet.enabled ? Screens.topLeft(cocoa: w.frame).cg : CGRect.null
    guard let cg = f(rect, opts, UInt32(w.windowNumber), img)?.takeRetainedValue(), cg.width > 1 else { return nil }
    return cg
}

/// The app icon on the standard macOS canvas: an 824/1024 rounded square, centred, with a soft shadow.
@MainActor
func renderIcon(size: CGFloat) -> NSImage {
    let r = ImageRenderer(content: AppIconIcon(size: size))
    r.scale = 1
    return r.nsImage ?? NSImage()
}

struct AppIconIcon: View {
    let size: CGFloat
    var body: some View {
        AppIconView(size: size * 824 / 1024)
            .shadow(color: .black.opacity(0.28), radius: size * 0.012, y: size * 0.01)
            .frame(width: size, height: size)
    }
}

/// A fake app window to put hints on top of in snapshots.
private struct MockApp: View {
    static let buttons: [(String, Rect)] = [
        ("Back", Rect(x: 60, y: 92, width: 60, height: 28)), ("Forward", Rect(x: 126, y: 92, width: 74, height: 28)),
        ("Search docs", Rect(x: 260, y: 90, width: 360, height: 32)), ("Share", Rect(x: 780, y: 92, width: 70, height: 28)),
        ("New Song", Rect(x: 860, y: 92, width: 90, height: 28)),
        ("Library", Rect(x: 60, y: 160, width: 160, height: 26)), ("Playlists", Rect(x: 60, y: 192, width: 160, height: 26)),
        ("Artists", Rect(x: 60, y: 224, width: 160, height: 26)), ("Albums", Rect(x: 60, y: 256, width: 160, height: 26)),
        ("Play", Rect(x: 300, y: 420, width: 120, height: 36)), ("Shuffle", Rect(x: 430, y: 420, width: 120, height: 36)),
        ("Add to queue", Rect(x: 560, y: 420, width: 140, height: 36)), ("Download", Rect(x: 710, y: 420, width: 120, height: 36)),
        ("Settings", Rect(x: 60, y: 540, width: 160, height: 26)), ("Sign out", Rect(x: 60, y: 572, width: 160, height: 26)),
        ("Volume", Rect(x: 800, y: 560, width: 150, height: 20)),
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color(red: 0.25, green: 0.3, blue: 0.55), Color(red: 0.55, green: 0.3, blue: 0.5)], startPoint: .topLeading,
                endPoint: .bottomTrailing)
            RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.96)).frame(width: 920, height: 560).offset(x: 40, y: 60)
                .shadow(radius: 20)
            Rectangle().fill(Color(white: 0.9)).frame(width: 180, height: 520).offset(x: 40, y: 100)
            Text("Midnight Drive").font(.system(size: 34, weight: .bold)).foregroundStyle(.black).offset(x: 300, y: 180)
            Text("24 songs · 1 hr 32 min").foregroundStyle(.gray).offset(x: 300, y: 230)
            ForEach(Array(Self.buttons.enumerated()), id: \.offset) { _, b in
                RoundedRectangle(cornerRadius: 6).fill(Color.white).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(white: 0.8)))
                    .overlay(Text(b.0).font(.system(size: 12)).foregroundStyle(.black.opacity(0.8)))
                    .frame(width: b.1.width, height: b.1.height).offset(x: b.1.x, y: b.1.y)
            }
        }
    }
}

@MainActor
func runSnapshot(_ dir: String) {
    // Liquid Glass samples the live window-server backdrop, which offscreen captures don't have; use the material fallback.
    OverlayGlass.enabled = false
    let out = URL(fileURLWithPath: dir, isDirectory: true)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    // Taller than the mock window so the HUD has a free bottom band, as on a real screen.
    let size = CGSize(width: 1000, height: 740)
    let screen = Rect(x: 0, y: 0, width: size.width, height: size.height)
    var written: [String] = []

    func save<V: View>(_ name: String, _ v: V, _ s: CGSize = size, _ appearance: NSAppearance.Name = .darkAqua) {
        do {
            try renderPNG(v, size: s, to: out.appendingPathComponent(name + ".png"), appearance: appearance)
            written.append(name)
        } catch {
            print("✗ \(name): \(error)")
        }
    }

    /// Renders through the real layer renderer (OverlayCanvas → bitmap), with the SwiftUI surfaces on top.
    func overlay(_ configure: (OverlayModel) -> Void, theme: Theme = .dark) -> some View {
        let m = OverlayModel()
        m.style = OverlayStyle(theme: theme, size: 12)
        m.activeScreen = screen
        let canvas = OverlayCanvas(screen: screen, scale: 2)
        let cache = OverlayImageCache(style: m.style)
        m.onSceneChange = {
            cache.use(m.style, space: OverlayArt.displaySpace())
            canvas.apply(m.scene, cache: cache)
        }
        configure(m)
        let layers = renderLayer(canvas.root, size: size, scale: 2)
        return ZStack(alignment: .topLeading) {
            MockApp()
            Image(nsImage: layers).resizable().frame(width: size.width, height: size.height)
            OverlayRoot(model: m, screen: screen)
        }
    }

    // Hints, via the real session so labels are what users would see.
    let items = MockApp.buttons.enumerated().map { HintItem(text: $0.element.0, key: "\($0.offset)", category: .button) }
    func hints(_ s: HintSession, tutor: Bool = false) -> OverlayScene {
        let badges = s.visible.compactMap { i -> HintBadge? in
            guard let l = s.labels[i], s.typed.isEmpty || l.hasPrefix(s.typed) else { return nil }
            return HintBadge(
                id: i, label: l, typed: s.typed.count, frame: MockApp.buttons[i].1, focused: s.focused == i, dragSource: s.dragSource == i)
        }
        let f = s.focused.map { MockApp.buttons[$0].1 }
        let t =
            tutor
            ? s.focused.map {
                TutorInfo(
                    frame: MockApp.buttons[$0].1,
                    rows: [("role", "Button"), ("title", MockApp.buttons[$0].0), ("label", s.labels[$0]!.uppercased())])
            } : nil
        return .hints(badges: badges, focusedFrame: f, tutor: t, large: false)
    }
    let all = HintSession(items: items, alphabet: "asdfghjkl")
    var search = HintSession(items: items, alphabet: "asdfghjkl")
    for c in "pla" { _ = search.handle(.char(c)) }
    func matches(_ n: Int) -> String { n == 1 ? "1 match" : "\(n) matches" }
    let hud = { (q: String, d: String) in
        HUDState(mode: .hint, query: q, detail: d, keys: ["type to search", "⇧+label jump", "⏎ click", "? tutor", "esc"])
    }

    for theme in [Theme.dark, .light, .vimium] {
        save(
            "hints-\(theme.rawValue)",
            overlay(
                { m in
                    m.scene = hints(all)
                    m.hud = hud("", matches(all.visible.count))
                }, theme: theme))
    }
    save(
        "hints-search",
        overlay({ m in
            m.scene = hints(search, tutor: true)
            m.hud = hud("pla", matches(search.visible.count))
        }))
    // README demo: frames of a real click-mode session typing "shu" (Shuffle), assembled into a GIF by
    // scripts/demo-gif.sh.
    do {
        var demo = HintSession(items: items, alphabet: "asdfghjkl")
        var frames: [(String, OverlayScene, HUDState?)] = [
            ("00", .none, nil), ("01", hints(demo), hud("", matches(demo.visible.count))),
        ]
        for (i, c) in "shu".enumerated() {
            _ = demo.handle(.char(c))
            frames.append(("0\(i + 2)", hints(demo), hud(String("shu".prefix(i + 1)), matches(demo.visible.count))))
        }
        frames.append(("05", .none, nil))
        try? FileManager.default.createDirectory(at: out.appendingPathComponent("demo"), withIntermediateDirectories: true)
        for (name, scene, h) in frames {
            save(
                "demo/frame-\(name)",
                overlay({ m in
                    m.scene = scene
                    m.hud = h
                }))
        }
    }
    save(
        "scroll",
        overlay({ m in
            m.scene = .scroll(
                areas: [Rect(x: 240, y: 140, width: 700, height: 460), Rect(x: 40, y: 140, width: 180, height: 480)], selected: 0)
            m.hud = HUDState(
                mode: .scroll, query: "", detail: "Area 1 of 2",
                keys: ["hjkl scroll", "⇧ dash", "d/u half page", "gg/G top/bottom", "⇥ area", "esc"])
        }))
    var grid = GridSession(bounds: screen)
    _ = grid.handle(.char("o"))
    save(
        "grid",
        overlay({ m in
            m.scene = .grid(rect: grid.rect, cells: grid.cells, keys: grid.keys, dragFrom: nil)
            m.hud = HUDState(mode: .grid, query: "", detail: nil, keys: ["keys narrow", "⏎ click", "␣ move", "⌫ back", "esc"])
        }))
    save(
        "palette",
        overlay({ m in
            let rows = [
                ("Export as PDF…", "File", "⌘⇧E"), ("Export Playlist…", "File › Library", nil), ("Expand All", "View", "⌥⌘→"),
                ("Export Song", "File › Convert", nil),
            ]
            .enumerated().map {
                PaletteRow(
                    id: $0.offset, label: "", typed: 0, title: $0.element.0, path: $0.element.1, shortcut: $0.element.2,
                    focused: $0.offset == 0)
            }
            m.scene = .palette(query: "exp", rows: rows, total: 4, placeholder: "Search menus…")
            m.hud = HUDState(mode: .menu, query: "exp", detail: "4 matches", keys: ["↑↓ select", "⏎ run", "esc"])
        }))
    save(
        "windows",
        overlay({ m in
            let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/Music.app")
            let safari = NSWorkspace.shared.icon(forFile: "/Applications/Safari.app")
            m.scene = .hints(
                badges: [
                    HintBadge(
                        id: 0, label: "a", typed: 0, frame: Rect(x: 40, y: 60, width: 520, height: 560), focused: true, dragSource: false,
                        title: "Music — Midnight Drive", icon: icon),
                    HintBadge(
                        id: 1, label: "s", typed: 0, frame: Rect(x: 520, y: 60, width: 440, height: 560), focused: false, dragSource: false,
                        title: "Safari — Pounce docs", icon: safari),
                ], focusedFrame: nil, tutor: nil, large: true)
            m.hud = HUDState(mode: .windows, query: "", detail: "2 windows", keys: ["type label", "⌥←→ halves", "⌥↑ max", "esc"])
        }))
    if let tiff = renderIcon(size: 1024).tiffRepresentation,
        let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    {
        try? png.write(to: out.appendingPathComponent("icon.png"))
        written.append("icon")
    }

    // Real windows, built by the same factory the app uses. A CLI process can't activate itself
    // (macOS 14 cooperative activation), so windows are told to draw as active.
    PounceWindow.drawsAsKey = true
    let controller = AppController(persist: false)
    SnapshotHooks.installIfMissing()
    controller.store.config.apps["com.apple.Safari"] = Config.AppOverride(labelsOnly: true)
    func saveWindow(_ name: String, _ w: NSWindow, _ appearance: NSAppearance.Name) {
        do {
            try renderWindow(w, to: out.appendingPathComponent(name + ".png"), appearance: appearance)
            written.append(name)
        } catch {
            print("✗ \(name): \(error)")
        }
    }
    for (suffix, appearance) in [("", NSAppearance.Name.darkAqua), ("-light", .aqua)] {
        for pane in SettingsPane.allCases {
            saveWindow("settings-\(pane.rawValue)\(suffix)", WindowManager.settingsWindow(controller, pane: pane), appearance)
        }
        for step in OnboardingView.Step.allCases {
            let name = step == .allow ? "onboarding" : "onboarding-\(step.title.lowercased())"
            let w = WindowManager.makeWindow(
                title: "Welcome to Pounce", size: CGSize(width: 560, height: 600), resizable: false, chrome: .plain
            ) {
                OnboardingView(store: controller.store, initialStep: step, onDone: {}).environmentObject(controller)
            }
            saveWindow(name + suffix, w, appearance)
        }
        saveWindow("cheatsheet\(suffix)", WindowManager.cheatSheetWindow(controller), appearance)
    }
    // States that only show up sometimes: shortcut conflicts and Secure Input.
    let (conflicts, secure) = (UIHooks.shortcutConflicts, UIHooks.secureInputApp)
    UIHooks.shortcutConflicts = { $0 == controller.store.config.shortcuts.menu ? ["VS Code (Parameter Hints)"] : [] }
    UIHooks.secureInputApp = { "Terminal" }
    saveWindow("settings-shortcuts-conflict", WindowManager.settingsWindow(controller, pane: .shortcuts), .darkAqua)
    saveWindow("settings-general-secure-light", WindowManager.settingsWindow(controller, pane: .general), .aqua)
    (UIHooks.shortcutConflicts, UIHooks.secureInputApp) = (conflicts, secure)

    print("Wrote \(written.count) PNGs to \(out.path)")
    exit(0)
}

/// Stand-ins so snapshots show surfaces whose backing code may not be wired yet. Real hooks win.
@MainActor
enum SnapshotHooks {
    static func installIfMissing() {
        if UIHooks.preset == nil {
            nonisolated(unsafe) var current = ""
            UIHooks.preset = ConfigChoice(
                options: [.init(tag: "", title: "Pounce (default)")] + UIHooks.tools,
                get: { _ in current }, set: { _, v in current = v })
        }
        if UIHooks.importSettings == nil { UIHooks.importSettings = { "Imported settings from \($0)." } }
        if UIHooks.updater == nil { UIHooks.updater = StubUpdater() }
    }

    final class StubUpdater: UpdateChecking {
        var automaticallyChecks = true
        var isChecking = false
        var availableVersion: String?
        var lastChecked: Date? = Date().addingTimeInterval(-3600)
        func check(manual: Bool) {}
        func openUpdate() {}
    }
}
