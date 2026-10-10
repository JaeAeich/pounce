import AppKit
import PounceCore

/// Smooth keyboard scrolling of the selected scroll area.
@MainActor
final class ScrollMode: Mode {
    let kind = ModeKind.scroll
    private unowned let app: AppController
    private var areas: [ScrollArea] = []
    private var session: ScrollSession?
    private var held: [ScrollDirection: Bool] = [:]  // direction → dash
    private var timer: Timer?
    private var lastTick = Date()
    private var animations: [(remaining: Double, perTick: Double)] = []
    /// Select the area containing this point instead of the one under the mouse (after-click scroll).
    private let near: CGPoint?

    init(app: AppController, near: CGPoint? = nil) {
        self.app = app
        self.near = near
        app.overlay.model.hud = HUDState(mode: .scroll, query: "", detail: "Finding scroll areas…", keys: [])
    }

    func load(_ areas: [ScrollArea]) {
        self.areas = areas
        let mouse = near.map { Point(x: $0.x, y: $0.y) } ?? Screens.mouse
        let underMouse = areas.lastIndex { $0.frame.contains(x: mouse.x, y: mouse.y) } ?? 0
        session = ScrollSession(areaCount: areas.count, selected: underMouse, keys: app.store.config.scroll.keys)
        pointAtSelection()
        render()
    }

    func keyDown(_ e: KeyEvent, input: KeyInput?) -> Bool {
        guard var s = session, let input else { return true }
        if e.isRepeat, case .char = input { return true }  // held keys are driven by the timer
        let fx = s.keyDown(input)
        session = s
        for f in fx { run(f) }
        return true
    }

    func keyUp(_ e: KeyEvent, input: KeyInput?) {
        guard var s = session, let input else { return }
        let fx = s.keyUp(input)
        session = s
        for f in fx { run(f) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private var target: CGPoint? {
        guard let s = session, s.selected < areas.count else { return Screens.mouse.cg }
        return areas[s.selected].frame.center
    }

    private func run(_ fx: ScrollEffect) {
        switch fx {
        case .start(let d, let dash):
            held[d] = dash
            startTimer()
        case .stop(let d):
            held[d] = nil
        case .halfPage(let down):
            let h = (session.flatMap { $0.selected < areas.count ? areas[$0.selected].frame.height : nil } ?? 600) / 2
            animate(down ? h : -h)
        case .edge(let top):
            if let s = session, s.selected < areas.count, let bar = areas[s.selected].verticalBar,
                bar.set("AXValue", NSNumber(value: top ? 0.0 : 1.0))
            {
                return
            }
            for _ in 0..<40 { Mouse.scroll(dx: 0, dy: top ? -5000 : 5000, at: target) }
        case .select:
            pointAtSelection()
            render()
        case .exit:
            app.stopMode()
        case .warn:
            Sound.playWarn()
        }
    }

    /// Scroll events go to the view under the cursor, so park it inside the chosen area.
    private func pointAtSelection() {
        guard let s = session, s.selected < areas.count else { return }
        let f = areas[s.selected].frame
        let m = Screens.mouse
        if !f.contains(x: m.x, y: m.y) { Mouse.move(to: f.center) }
    }

    private func animate(_ dy: Double) {
        let ticks = 14.0
        animations.append((abs(dy), dy / ticks))
        startTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = Date()
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), 0.05)
        lastTick = now
        let cfg = app.store.config.scroll
        var dx = 0.0, dy = 0.0
        for (d, dash) in held {
            let v = d.vector
            let speed = dash ? cfg.dashSpeed : cfg.speed
            dx += v.dx * speed * dt
            dy += v.dy * speed * dt
        }
        animations = animations.compactMap { a in
            dy += a.perTick
            let r = a.remaining - abs(a.perTick)
            return r > 0.5 ? (r, a.perTick) : nil
        }
        if dx != 0 || dy != 0 { Mouse.scroll(dx: dx, dy: dy, at: target) }
        if held.isEmpty && animations.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func render() {
        guard let s = session else { return }
        let k = app.store.config.scroll.keys.map(String.init).joined()
        app.overlay.model.scene = .scroll(areas: areas.map(\.frame), selected: s.selected)
        app.overlay.model.hud = HUDState(
            mode: .scroll, query: "",
            detail: areas.isEmpty ? "No scroll areas – scrolling under cursor" : "Area \(s.selected + 1) of \(areas.count)",
            keys: ["\(k) scroll", "⇧ dash", "d/u half page", "gg/G top/bottom", "⇥ / 1-9 area", "esc"])
    }
}

/// 3×3 recursive grid to reach any point on screen.
@MainActor
final class GridMode: Mode {
    let kind = ModeKind.grid
    private unowned let app: AppController
    private var session: GridSession
    private var screenIndex: Int

    init(app: AppController) {
        self.app = app
        let m = Screens.mouse
        let screen = Screens.screen(containing: m.x, m.y)
        screenIndex = NSScreen.screens.firstIndex(of: screen) ?? 0
        let g = app.store.config.grid
        session = GridSession(bounds: Screens.topLeft(screen), keys: g.keys, style: g.style, labelKeys: g.labels)
        app.overlay.model.activeScreen = Screens.topLeft(screen)
        render()
    }

    func keyDown(_ e: KeyEvent, input: KeyInput?) -> Bool {
        guard let input else { return true }
        for fx in session.handle(input) {
            switch fx {
            case .update: render()
            case .warn: Sound.playWarn()
            case .exit: app.stopMode()
            case .nextScreen:
                let screens = NSScreen.screens
                screenIndex = (screenIndex + 1) % screens.count
                let r = Screens.topLeft(screens[screenIndex])
                session.reset(bounds: r)
                app.overlay.model.activeScreen = r
                render()
            case .move(let p):
                app.stopMode()
                Mouse.move(to: p.cg)
            case .click(let p, let a):
                app.stopMode(keepToast: true)
                Sound.playClick()
                app.overlay.pulse(at: p.cg)
                Clicker.perform(a, at: p.cg, element: nil, method: .mouse, restoreCursor: app.store.config.hints.restoreCursor)
                app.noteClick(at: p.cg)
                app.lastActivation = .init(action: a, point: p.cg)
            case .drag(let a, let b):
                app.stopMode()
                Mouse.drag(from: a.cg, to: b.cg)
                app.lastActivation = .init(action: .drag(from: -1), point: b.cg, dragFrom: a.cg)
            }
        }
        return true
    }

    func keyUp(_ e: KeyEvent, input: KeyInput?) {}
    func stop() {}

    private func render() {
        let drag = session.dragFrom != nil ? "Drag: pick the drop point · ⏎" : nil
        if session.picking {
            app.overlay.model.scene = .gridLabels(
                rect: session.rect, cells: session.labelCells, typed: session.firstKey.map(String.init) ?? "", dragFrom: session.dragFrom)
            app.overlay.model.hud = HUDState(
                mode: .grid, query: session.firstKey.map { String($0).uppercased() } ?? "", detail: drag,
                keys: ["type 2 letters", "⌫ back", "⌃D drag", "⇥ screen", "esc"])
            return
        }
        app.overlay.model.scene = .grid(rect: session.rect, cells: session.cells, keys: session.keys, dragFrom: session.dragFrom)
        app.overlay.model.hud = HUDState(
            mode: .grid, query: "", detail: drag,
            keys: ["keys narrow", "⏎ click", "␣ move", "⌫ back", "⌃D drag", "⇥ screen", "esc"])
    }
}
