import AppKit
import PounceCore
import QuartzCore
import SwiftUI

/// Transparent, click-through, non-activating panels (one per screen), created up front and kept ordered in,
/// so showing hints is just a layer commit. Hints / grid / scroll areas are Core Animation layers
/// (OverlayCanvas); HUD, toasts, tutor card and palette are SwiftUI on top.
@MainActor
final class OverlayController {
    let model = OverlayModel()
    private struct Screen {
        let id: CGDirectDisplayID
        let panel: NSPanel
        let canvas: OverlayCanvas
        let host: NSHostingView<OverlayRoot>
    }
    private var screens: [Screen] = []
    private let cache: OverlayImageCache
    private var observers: [Any] = []
    private var alphabet: String?
    /// Main display's colour space; art is rendered in it so CA needn't colour-match at commit.
    private var space = OverlayArt.sRGB

    init() {
        cache = OverlayImageCache(style: model.style)
        model.onSceneChange = { [weak self] in self?.render() }
        let nc = NotificationCenter.default
        observers.append(
            nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            })
        // `.system` theme follows the appearance; re-resolve art when it flips.
        observers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: .init("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.render() }
            })
        // System accent colour changed → rebuild art.
        observers.append(
            nc.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.cache.use(self.model.style, space: self.space, force: true)
                    self.render()
                    if let a = self.alphabet { self.prewarm(alphabet: a) }
                }
            })
        rebuild()
    }

    /// Creates / repositions / drops panels to match the current screens.
    private func rebuild() {
        var old = screens
        var next: [Screen] = []
        for ns in NSScreen.screens {
            let id = (ns.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let frame = Screens.topLeft(ns)
            if let i = old.firstIndex(where: { $0.id == id }) {
                let s = old.remove(at: i)
                s.panel.setFrame(Self.physical(ns.frame), display: false)
                s.host.rootView = OverlayRoot(model: model, screen: frame)
                s.host.frame = CGRect(origin: .zero, size: ns.frame.size)
                s.canvas.relayout(screen: frame, scale: ns.backingScaleFactor)
                next.append(s)
            } else {
                next.append(makeScreen(ns, id: id))
            }
        }
        old.forEach { $0.panel.orderOut(nil) }
        screens = next
        space = OverlayArt.displaySpace()
        // Allocate pill layers once the run loop is idle, not on the first activation.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.screens.forEach { $0.canvas.reserve(1600) } }
        }
        render()
        if let a = alphabet { prewarm(alphabet: a) }
    }

    private func makeScreen(_ ns: NSScreen, id: CGDirectDisplayID) -> Screen {
        let p = NSPanel(contentRect: ns.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let frame = Screens.topLeft(ns)
        let size = ns.frame.size
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.wantsLayer = true
        let canvas = OverlayCanvas(screen: frame, scale: ns.backingScaleFactor)
        canvas.autoresizingMask = [.width, .height]
        let host = NSHostingView(rootView: OverlayRoot(model: model, screen: frame))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(canvas)
        container.addSubview(host)
        if Quiet.enabled {
            // Near-invisible corner pixels: an unbounded capture of this off-screen panel then spans all of it.
            for o in [CGPoint.zero, CGPoint(x: size.width - 1, y: size.height - 1)] {
                let m = NSView(frame: CGRect(origin: o, size: CGSize(width: 1, height: 1)))
                m.wantsLayer = true
                m.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.01).cgColor
                container.addSubview(m)
            }
        }
        p.contentView = container
        p.setFrame(Self.physical(ns.frame), display: false)
        // Ordered in once, permanently: empty layers cost nothing to composite, and showing is then free.
        p.orderFrontRegardless()
        return Screen(id: id, panel: p, canvas: canvas, host: host)
    }

    /// Panels sit on their screen, or far off-screen in quiet mode (self-test): same layout, still capturable.
    private static func physical(_ f: CGRect) -> CGRect {
        Quiet.enabled ? f.offsetBy(dx: Quiet.offscreen.x, dy: Quiet.offscreen.y) : f
    }

    private func render() {
        cache.use(model.style, space: space)
        for s in screens { s.canvas.apply(model.scene, cache: cache) }
    }

    /// Synchronously clears everything (before synthesising clicks / screenshots).
    func hideNow() {
        model.scene = .none
        model.hud = nil
        CATransaction.flush()
    }

    /// Pre-renders resting pills for `alphabet` in the background, so the first activation is a pure layer commit.
    func prewarm(alphabet: String) {
        self.alphabet = alphabet
        cache.use(model.style, space: space)
        cache.prewarm(alphabet: alphabet, scales: screens.map(\.canvas.scale))
    }

    /// Click confirmation: a short accent pulse at `point` (global top-left). Survives hideNow().
    func pulse(at point: CGPoint) {
        cache.use(model.style, space: space)
        for s in screens { s.canvas.pulse(at: point, accent: cache.art.accent) }
    }

    /// Diagnostics: compares what the window server actually shows for each pill with the image
    /// its layer holds. Catches pills drawn from the wrong sprite or not at all.
    func verifyPills() -> (checked: Int, matched: Int) {
        var checked = 0, matched = 0
        for s in screens {
            guard let shot = windowImage(s.panel, full: true), s.panel.frame.width > 0 else { continue }
            let k = CGFloat(shot.width) / s.panel.frame.width
            for p in s.canvas.pillSnapshots(cache) {
                let r = CGRect(x: p.frame.minX * k, y: p.frame.minY * k, width: p.frame.width * k, height: p.frame.height * k).integral
                guard let crop = shot.cropping(to: r) else { continue }
                checked += 1
                if Self.similar(crop, p.image) {
                    matched += 1
                } else if FileManager.default.fileExists(atPath: "/tmp/pounce-debug") {
                    for (n, img) in [("shot", crop), ("want", p.image)] {
                        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: "/tmp/pv-\(checked)-\(n)-\(Int(p.frame.minX)),\(Int(p.frame.minY)).png"))
                    }
                }
            }
        }
        return (checked, matched)
    }

    /// Compares both images at the sprite's own resolution: the share of clearly different pixels
    /// must be small (allows for 1 px edge offsets, not a different label).
    static func similar(_ a: CGImage, _ b: CGImage) -> Bool {
        let w = b.width, h = b.height
        func px(_ img: CGImage) -> [UInt8]? {
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let ok = buf.withUnsafeMutableBytes { m -> Bool in
                guard
                    let ctx = CGContext(
                        data: m.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            return ok ? buf : nil
        }
        guard w > 0, h > 0, let x = px(a), let y = px(b) else { return false }
        var differing = 0
        for i in stride(from: 0, to: x.count, by: 4) {
            let d =
                abs(Int(x[i]) - Int(y[i])) + abs(Int(x[i + 1]) - Int(y[i + 1])) + abs(Int(x[i + 2]) - Int(y[i + 2]))
                + abs(Int(x[i + 3]) - Int(y[i + 3]))
            if d > 120 { differing += 1 }
        }
        return Double(differing) / Double(w * h) < 0.03
    }

    /// Diagnostics: the overlay as the window server composites it, one PNG per screen.
    func capture(to dir: String) -> [String] {
        screens.enumerated().compactMap { i, s in
            guard let cg = windowImage(s.panel, full: true),
                let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            else { return nil }
            let path = "\(dir)/pounce-overlay-\(i).png"
            return (try? png.write(to: URL(fileURLWithPath: path))) != nil ? path : nil
        }
    }

    /// Pills currently on screen, across all panels.
    var visiblePills: Int { screens.reduce(0) { $0 + $1.canvas.visiblePills } }
    var panelsOrderedIn: Bool { !screens.isEmpty && screens.allSatisfy { $0.panel.isVisible } }

    func flushRendererCachesForBench() { cache.removeAll() }
}
