import AppKit
import PounceCore

/// Keyboard cursor: held direction keys glide the real pointer (ease-in to top speed, ⇧ fast, ⌥ precise),
/// Space/⏎ click, v drags. Stays open after clicks; esc exits.
@MainActor
final class MouseMode: Mode {
    let kind = ModeKind.mouse
    private unowned let app: AppController
    private var session: MouseSession
    private var timer: Timer?
    private var lastTick = Date()
    /// Pointer position we drive (fractional, global top-left). Re-synced if the real pointer moved.
    private(set) var position: CGPoint
    private var lastPosted: CGPoint
    private var scrolling: Set<Bool> = []  // down?
    /// Test hook: speed tier override (the self-test can't hold real modifier keys).
    var speedOverride: MouseSession.Speed?

    init(app: AppController) {
        self.app = app
        let cfg = app.store.config
        session = MouseSession(keys: cfg.mouse.resolvedKeys(scroll: cfg.scroll), tuning: cfg.mouse.tuning)
        position = Mouse.location
        lastPosted = position
        app.overlay.model.activeScreen = Screens.topLeft(Screens.screen(containing: position.x, position.y))
        render()
    }

    var dragging: Bool { session.dragging }

    func keyDown(_ e: KeyEvent, input: KeyInput?) -> Bool {
        guard let input else { return true }
        // Held keys are driven by the timer; only nudges auto-repeat.
        if e.isRepeat {
            if case .arrow = input {} else { return true }
        }
        for fx in session.keyDown(input) { run(fx) }
        return true
    }

    func keyUp(_ e: KeyEvent, input: KeyInput?) {
        guard let input else { return }
        for fx in session.keyUp(input) { run(fx) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if session.dragging { Mouse.release(at: position) }
        session.releaseAll()
        scrolling = []
    }

    private func run(_ fx: MouseEffect) {
        switch fx {
        case .update:
            if session.isMoving { startTimer() }
            render()
        case .nudge(let dx, let dy):
            sync()
            moveTo(CGPoint(x: position.x + dx, y: position.y + dy))
            render()
        case .click(let b, let count, let mods):
            sync()
            click(b, count: count, mods: mods)
        case .dragBegin:
            sync()
            Mouse.press(at: position)
        case .dragEnd:
            Mouse.release(at: position)
        case .scrollStart(let down):
            scrolling.insert(down)
            startTimer()
        case .scrollStop(let down):
            scrolling.remove(down)
        case .exit:
            app.stopMode()
        case .warn:
            Sound.playWarn()
        }
    }

    private func click(_ b: MouseButtonKind, count: Int, mods: Modifiers) {
        let flags = EventTap.flags(mods)
        let action: HintAction
        switch b {
        case .left:
            Mouse.click(at: position, count: count, flags: flags)
            action = count > 1 ? .doubleClick : mods.contains(.command) ? .commandClick : mods.contains(.option) ? .optionClick : .click
        case .right:
            Mouse.click(at: position, button: .right)
            action = .rightClick
        case .middle:
            Mouse.click(at: position, button: .center)
            action = .middleClick
        case .back:
            Mouse.click(at: position, button: Mouse.backButton)
            action = .back
        case .forward:
            Mouse.click(at: position, button: Mouse.forwardButton)
            action = .forward
        }
        Sound.playClick()
        app.overlay.pulse(at: position)
        app.noteClick(at: position)
        app.lastActivation = .init(action: action, point: position)
    }

    /// Picks up real pointer movement (trackpad) made since we last posted.
    private func sync() {
        let real = Mouse.location
        if abs(real.x - lastPosted.x) > 2 || abs(real.y - lastPosted.y) > 2 {
            position = real
            lastPosted = real
        }
    }

    private func moveTo(_ p: CGPoint) {
        position = clamp(p)
        lastPosted = position
        Mouse.move(to: position, dragging: session.dragging)
    }

    /// Keeps the pointer on a display: free movement between screens, clamped at outer edges.
    private func clamp(_ p: CGPoint) -> CGPoint {
        if NSScreen.screens.contains(where: { Screens.topLeft($0).contains(x: p.x, y: p.y) }) { return p }
        let s = Screens.topLeft(Screens.screen(containing: position.x, position.y))
        return CGPoint(x: min(max(p.x, s.x), s.maxX - 1), y: min(max(p.y, s.y), s.maxY - 1))
    }

    private var speed: MouseSession.Speed {
        if let o = speedOverride { return o }
        let f = CGEventSource.flagsState(.combinedSessionState)
        if f.contains(.maskShift) { return .fast }
        if f.contains(.maskAlternate) { return .slow }
        return .normal
    }

    private func startTimer() {
        guard timer == nil else { return }
        sync()
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
        if session.isMoving {
            let d = session.step(dt: dt, speed: speed)
            if d.dx != 0 || d.dy != 0 {
                moveTo(CGPoint(x: position.x + d.dx, y: position.y + d.dy))
                render()
            }
        }
        if !scrolling.isEmpty {
            let v = app.store.config.scroll.speed * dt
            let dy = (scrolling.contains(true) ? v : 0) - (scrolling.contains(false) ? v : 0)
            if dy != 0 { Mouse.scroll(dx: 0, dy: dy, at: position) }
        }
        if !session.isMoving && scrolling.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func render() {
        let k = app.store.config.mouse.resolvedKeys(scroll: app.store.config.scroll).map(String.init).joined()
        app.overlay.model.scene = .pointer(at: Point(x: position.x, y: position.y), dragging: session.dragging)
        app.overlay.model.hud = HUDState(
            mode: .mouse, query: "", detail: session.dragging ? "Dragging · v or ␣ to drop" : nil,
            keys: [
                "\(k) move", "⇧ fast", "⌥ precise", "␣ click", "⇧⏎ right", "m middle", "c double", "v drag", "[ ] back/fwd", "d/u scroll",
                "esc",
            ])
    }
}
