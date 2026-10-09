import AppKit
import PounceCore
import QuartzCore

/// Measures overlay latency: scene set → layers committed, for N badges and per keystroke.
@MainActor
enum OverlayBench {
    struct Result {
        var show: [Int: Double] = [:]  // N → ms (cold: hidden → shown)
        var warmShow: [Int: Double] = [:]  // N → ms (cached images)
        var keyPrefix: Double = 0  // 1500 badges → type first char
        var keyFocus: Double = 0  // 1500 badges → focus moves (all stay visible)
        var hide: Double = 0
        var hudOnly: Double = 0  // SwiftUI HUD text change alone
        var summary: String {
            let s = show.keys.sorted().map { "\($0): \(fmt(show[$0]!))/\(fmt(warmShow[$0] ?? 0))" }.joined(separator: ", ")
            return
                "show cold/warm ms \(s); keystroke@1500 prefix \(fmt(keyPrefix)), focus \(fmt(keyFocus)) (HUD alone \(fmt(hudOnly))); hide \(fmt(hide))"
        }
        var worstKeystroke: Double { max(keyPrefix, keyFocus) }
        private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
    }

    static func run(_ overlay: OverlayController) -> Result {
        let screen = Screens.topLeft(NSScreen.main ?? NSScreen.screens[0])
        overlay.model.activeScreen = screen
        var r = Result()
        drain()
        let idle = median((0..<5).map { _ in time {} })
        for n in [100, 500, 1500] {
            let (badges, session) = make(n, in: screen)
            overlay.hideNow()
            drain()
            overlay.flushRendererCachesForBench()
            r.show[n] = max(0, time { overlay.model.scene = scene(badges, session) } - idle)
            overlay.hideNow()
            drain()
            r.warmShow[n] = max(
                0,
                median(
                    (0..<3).map { _ in
                        let t = time { overlay.model.scene = scene(badges, session) } - idle
                        overlay.hideNow()
                        drain()
                        return t
                    }))
            if n == 1500 {
                overlay.model.scene = scene(badges, session)
                drain()
                var prefix: [Double] = []
                var focus: [Double] = []
                for k in 0..<5 {
                    var s = session
                    _ = s.handle(.char(Character(String(Array("asdfg")[k]).uppercased())))
                    prefix.append(
                        time {
                            overlay.model.scene = scene(badges, s)
                            overlay.model.hud = HUDState(mode: .hint, query: "", detail: "\(s.visible.count) matches \(k)", keys: ["esc"])
                        } - idle)
                    overlay.model.scene = scene(badges, session)
                    drain()
                    var f = session
                    for _ in 0...k { _ = f.handle(.tab(backward: false)) }
                    focus.append(
                        time {
                            overlay.model.scene = scene(badges, f)
                            overlay.model.hud = HUDState(mode: .hint, query: "", detail: "focus \(k)", keys: ["esc"])
                        } - idle)
                }
                r.keyPrefix = max(0, median(prefix))
                r.keyFocus = max(0, median(focus))
                r.hudOnly = max(
                    0,
                    median(
                        (0..<5).map { k in
                            time { overlay.model.hud = HUDState(mode: .hint, query: "", detail: "hud \(k)", keys: ["esc"]) } - idle
                        }))
                r.hide = max(0, time { overlay.hideNow() } - idle)
            }
        }
        overlay.hideNow()
        drain()
        return r
    }

    private static func make(_ n: Int, in s: Rect) -> ([Rect], HintSession) {
        let cols = 50
        let frames = (0..<n).map { i in
            Rect(x: s.x + 10 + Double(i % cols) * (s.width - 20) / Double(cols), y: s.y + 30 + Double(i / cols) * 26, width: 22, height: 18)
        }
        let items = (0..<n).map { HintItem(text: "item \($0)", key: "\($0)", category: .button) }
        return (frames, HintSession(items: items, alphabet: "asdfghjkl"))
    }

    private static func scene(_ frames: [Rect], _ s: HintSession) -> OverlayScene {
        var badges: [HintBadge] = []
        badges.reserveCapacity(frames.count)
        for i in s.visible {
            guard let l = s.labels[i], s.typed.isEmpty || l.hasPrefix(s.typed) else { continue }
            badges.append(HintBadge(id: i, label: l, typed: s.typed.count, frame: frames[i], focused: s.focused == i, dragSource: false))
        }
        return .hints(badges: badges, focusedFrame: s.focused.map { frames[$0] }, tutor: nil, large: false)
    }

    /// Wall time for `body` plus everything needed to get its result to the render server.
    private static func time(_ body: () -> Void) -> Double {
        let t0 = CACurrentMediaTime()
        body()
        drain()
        return (CACurrentMediaTime() - t0) * 1000
    }

    /// Runs one run-loop pass (SwiftUI/AppKit updates + CA commit happen before waiting), then forces display + commit.
    private static func drain() {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.0005))
        for w in NSApp.windows where w is NSPanel && w.isVisible {
            w.contentView?.layoutSubtreeIfNeeded()
            w.contentView?.displayIfNeeded()
        }
        CATransaction.flush()
    }

    private static func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
}
