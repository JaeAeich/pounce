import AppKit
import PounceCore
import QuartzCore

/// A layer that never animates implicitly.
final class PlainLayer: CALayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

/// Layer-hosting view for one screen: hint pills, target ring, window badges, scroll areas, grid.
/// Updates are diffed per badge id, so a keystroke only touches layers whose state changed.
@MainActor
final class OverlayCanvas: NSView {
    /// That screen's global top-left frame.
    private(set) var screen: Rect
    private(set) var scale: CGFloat
    let root = PlainLayer()
    private let ring = PlainLayer()
    private let pillsRoot = PlainLayer()
    private let extras = PlainLayer()

    private final class Slot {
        let layer = PlainLayer()
        var key: PillKey?
        var winKey: ObjectIdentifier?
        var frame = CGRect.null
        var mark = 0
    }
    private var live: [Int: Slot] = [:]
    private var spare: [Slot] = []
    private var mark = 0
    private var extrasSignature: Int?
    private var lastPlacementKey: Int?
    private var placements: [Int: Point] = [:]

    init(screen: Rect, scale: CGFloat) {
        self.screen = screen
        self.scale = scale
        super.init(frame: CGRect(x: 0, y: 0, width: screen.width, height: screen.height))
        root.frame = bounds
        root.masksToBounds = false
        for l in [extras, ring, pillsRoot] {
            l.frame = root.bounds
            root.addSublayer(l)
        }
        ring.isHidden = true
        ring.cornerRadius = 7
        ring.borderWidth = 2
        ring.cornerCurve = .continuous
        ring.shadowOpacity = 1
        ring.shadowRadius = 4
        ring.shadowOffset = .zero
        layer = root
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        applyScale()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Diagnostics: shown pills as (frame in top-left view points, the sprite expected for its label).
    func pillSnapshots(_ cache: OverlayImageCache) -> [(frame: CGRect, image: CGImage)] {
        live.values.compactMap { s in
            // The image this label *should* show, rendered independently of how the layer displays it.
            guard !s.layer.isHidden, let key = s.key, let expected = cache.sprite(key)?.image else { return nil }
            let f = pillsRoot.convert(s.layer.frame, to: root)
            let y = root.isGeometryFlipped ? f.minY : bounds.height - f.maxY
            return (CGRect(x: f.minX, y: y, width: f.width, height: f.height), expected)
        }
    }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func relayout(screen: Rect, scale: CGFloat) {
        self.screen = screen
        self.scale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
        root.frame = bounds
        for l in [extras, ring, pillsRoot] { l.frame = root.bounds }
        applyScale()
        for s in live.values {
            s.key = nil
            s.winKey = nil
            s.frame = .null
        }
        extrasSignature = nil
        CATransaction.commit()
    }

    private func applyScale() {
        for l in [root, extras, ring, pillsRoot] { l.contentsScale = scale }
    }

    /// Number of pills currently on screen (self-test / bench).
    var visiblePills: Int { live.count }

    // MARK: Apply

    func apply(_ scene: OverlayScene, cache: OverlayImageCache) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch scene {
        case .hints(let badges, let focused, _, let large):
            if large { windows(badges, cache) } else { pills(badges, cache) }
            setRing(large ? nil : focused, cache.art)
            setExtras(nil, nil)
        case .scroll(let areas, let selected):
            clearPills()
            setRing(nil, cache.art)
            var h = Hasher()
            h.combine(areas)
            h.combine(selected)
            setExtras(h.finalize()) { self.buildScroll(areas, selected, cache) }
        case .grid(let rect, let cells, let keys, let dragFrom):
            clearPills()
            setRing(nil, cache.art)
            var h = Hasher()
            h.combine(rect)
            h.combine(cells)
            h.combine(String(keys))
            h.combine(dragFrom)
            setExtras(h.finalize()) { self.buildGrid(rect, cells, keys, dragFrom, cache) }
        case .gridLabels(let rect, let cells, let typed, let dragFrom):
            clearPills()
            setRing(nil, cache.art)
            var h = Hasher()
            h.combine(rect)
            h.combine(cells.count)
            h.combine(cells.first)
            h.combine(typed)
            h.combine(dragFrom)
            setExtras(h.finalize()) { self.buildGridLabels(rect, cells, typed, dragFrom, cache) }
        case .pointer(let p, let dragging):
            clearPills()
            setRing(nil, cache.art)
            var h = Hasher()
            h.combine(p)
            h.combine(dragging)
            setExtras(h.finalize()) { self.buildPointer(p, dragging, cache) }
        case .none, .palette:
            clearPills()
            setRing(nil, cache.art)
            setExtras(nil, nil)
        }
    }

    /// Converts a global top-left rect into this layer tree's (y-up) coordinates.
    private func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX - screen.x, y: screen.height - (r.minY - screen.y) - r.height, width: r.width, height: r.height)
    }

    private func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

    // MARK: Pills

    private func pills(_ badges: [HintBadge], _ cache: OverlayImageCache) {
        mark &+= 1
        let art = cache.art
        let bounds = Rect(x: 0, y: 0, width: screen.width, height: screen.height)
        let sc = UInt8(max(1, min(4, scale.rounded())))
        var todo: [(Int, PillKey, CGRect)] = []
        todo.reserveCapacity(badges.count)
        // Collision-free placement depends only on which pills are shown where; keystrokes that just
        // change typed/focus state reuse it.
        var h = Hasher()
        h.combine(badges.count)
        for b in badges {
            h.combine(b.id)
            h.combine(b.label.count)
            h.combine(b.frame.x)
            h.combine(b.frame.y)
            h.combine(b.frame.width)
            h.combine(b.frame.height)
        }
        h.combine(art.style.size)
        let placementKey = h.finalize()
        let reuse = placementKey == lastPlacementKey
        if !reuse { placements.removeAll(keepingCapacity: true) }
        var placer = PillPlacer(bounds: bounds, capacity: reuse ? 0 : badges.count)
        for b in badges {
            guard b.frame.x < screen.maxX, b.frame.maxX > screen.x, b.frame.y < screen.maxY, b.frame.maxY > screen.y else { continue }
            let size = art.style.labelSize(b.label)
            let o: Point
            if reuse, let p = placements[b.id] {
                o = p
            } else {
                o = placer.place(
                    Geometry.labelOrigin(for: Geometry.local(b.frame, inScreenTopLeft: screen), size: size, bounds: bounds), size: size)
                placements[b.id] = o
            }
            let key = PillKey(label: b.label, typed: UInt8(min(b.typed, 255)), focused: b.focused, drag: b.dragSource, scale: sc)
            let px = art.pillPixels(key)
            let cx = o.x + size.w / 2, cy = o.y + size.h / 2
            let w = CGFloat(px.w) / CGFloat(sc), h = CGFloat(px.h) / CGFloat(sc)
            // Local top-left → y-up, snapped to device pixels.
            let f = CGRect(x: snap(cx - w / 2), y: snap(screen.height - cy - h / 2), width: w, height: h)
            todo.append((b.id, key, f))
        }
        lastPlacementKey = placementKey
        cache.fill(todo.map(\.1))
        for (id, key, f) in todo {
            let slot: Slot
            if let s = live[id] {
                slot = s
            } else {
                slot = spare.popLast() ?? newSlot()
                live[id] = slot
                slot.layer.isHidden = false
            }
            slot.mark = mark
            if slot.key != key {
                slot.key = key
                let sp = cache.sprite(key)
                slot.layer.contents = sp?.image
                slot.layer.zPosition = key.focused ? 2 : key.drag ? 1 : 0
            }
            if slot.frame != f {
                slot.frame = f
                slot.layer.frame = f
            }
        }
        retire { $0.mark != mark }
    }

    private func windows(_ badges: [HintBadge], _ cache: OverlayImageCache) {
        mark &+= 1
        let bounds = CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
        for b in badges {
            guard !b.frame.intersection(screen).isEmpty, let img = cache.window(b, scale: scale) else { continue }
            let vis = flip(b.frame.cg).intersection(bounds)
            let w = CGFloat(img.width) / scale, h = CGFloat(img.height) / scale
            let f = CGRect(x: snap(vis.midX - w / 2), y: snap(vis.midY - h / 2), width: w, height: h)
            let slot: Slot
            if let s = live[b.id] {
                slot = s
            } else {
                slot = spare.popLast() ?? newSlot()
                live[b.id] = slot
                slot.layer.isHidden = false
            }
            slot.mark = mark
            let id = ObjectIdentifier(img)
            if slot.winKey != id {
                slot.winKey = id
                slot.key = nil
                slot.layer.contents = img
                slot.layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                slot.layer.zPosition = b.focused ? 2 : 0
            }
            if slot.frame != f {
                slot.frame = f
                slot.layer.frame = f
            }
        }
        retire { $0.mark != mark }
    }

    /// Pre-creates hidden pill layers so the first big activation doesn't pay for layer allocation.
    func reserve(_ n: Int) {
        guard spare.count + live.count < n else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for _ in 0..<(n - spare.count - live.count) {
            let s = newSlot()
            s.layer.isHidden = true
            spare.append(s)
        }
        CATransaction.commit()
    }

    private func newSlot() -> Slot {
        let s = Slot()
        s.layer.contentsScale = scale
        s.layer.contentsGravity = .resize
        s.layer.isOpaque = false
        pillsRoot.addSublayer(s.layer)
        return s
    }

    private func clearPills() { if !live.isEmpty { retire { _ in true } } }

    private func retire(_ pred: (Slot) -> Bool) {
        for (id, s) in live where pred(s) {
            s.layer.isHidden = true
            s.layer.contents = nil
            s.key = nil
            s.winKey = nil
            s.frame = .null
            live[id] = nil
            spare.append(s)
        }
    }

    // MARK: Ring

    private func setRing(_ target: Rect?, _ art: OverlayArt) {
        guard let t = target, !t.intersection(screen).isEmpty else {
            if !ring.isHidden { ring.isHidden = true }
            return
        }
        let f = flip(t.cg).insetBy(dx: -3, dy: -3)
        ring.frame = CGRect(x: snap(f.minX), y: snap(f.minY), width: snap(f.width), height: snap(f.height))
        ring.borderColor = art.accent
        ring.backgroundColor = art.accent.copy(alpha: 0.08)
        ring.shadowColor = art.accent.copy(alpha: 0.35)
        ring.shadowPath = CGPath(roundedRect: ring.bounds, cornerWidth: 7, cornerHeight: 7, transform: nil)
        ring.isHidden = false
    }

    // MARK: Scroll areas + grid (few layers; rebuilt when their inputs change)

    private func setExtras(_ signature: Int?, _ build: (() -> Void)?) {
        guard signature != extrasSignature else { return }
        extrasSignature = signature
        extras.sublayers = nil
        build?()
    }

    private func box(_ f: CGRect, bg: CGColor? = nil, border: CGColor? = nil, width: CGFloat = 0, radius: CGFloat = 0) -> PlainLayer {
        let l = PlainLayer()
        l.frame = f
        l.contentsScale = scale
        l.backgroundColor = bg
        l.borderColor = border
        l.borderWidth = width
        l.cornerRadius = radius
        l.cornerCurve = .continuous
        return l
    }

    private func image(_ img: (CGImage, CGSize), center: CGPoint) -> PlainLayer {
        let l = PlainLayer()
        l.contentsScale = scale
        l.contents = img.0
        l.frame = CGRect(
            x: snap(center.x - img.1.width / 2), y: snap(center.y - img.1.height / 2), width: img.1.width, height: img.1.height)
        return l
    }

    private func buildScroll(_ areas: [Rect], _ selected: Int, _ cache: OverlayImageCache) {
        let art = cache.art
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold) as CTFont
        for (i, a) in areas.enumerated() where !a.intersection(screen).isEmpty {
            let sel = i == selected
            let f = flip(a.cg)
            extras.addSublayer(
                box(
                    f, bg: sel ? art.accent.copy(alpha: 0.05) : nil, border: art.accent.copy(alpha: sel ? 1 : 0.4), width: sel ? 2.5 : 1,
                    radius: 10))
            let n = i < 9 ? "\(i + 1)" : i == 9 ? "0" : ""
            guard !n.isEmpty else { continue }
            let c = CGRect(x: f.minX + 8, y: f.maxY - 30, width: 22, height: 22)
            extras.addSublayer(box(c, bg: sel ? art.accent : art.bg, border: sel ? nil : art.border, width: sel ? 0 : 0.5, radius: 11))
            if let t = cache.text(n, font: font, size: 12, color: sel ? art.focusText : art.text, tag: "scroll\(sel)", scale: scale) {
                extras.addSublayer(image(t, center: CGPoint(x: c.midX, y: c.midY)))
            }
        }
    }

    private func buildGrid(_ rect: Rect, _ cells: [Rect], _ keys: [Character], _ dragFrom: Point?, _ cache: OverlayImageCache) {
        let art = cache.art
        if !rect.intersection(screen).isEmpty {
            let r = flip(rect.cg)
            extras.addSublayer(box(r, bg: CGColor(gray: 0, alpha: 0.12), border: art.accent.copy(alpha: 0.9), width: 1.5))
            for i in 0..<min(cells.count, keys.count) {
                let f = flip(cells[i].cg)
                extras.addSublayer(box(f, border: CGColor(gray: 1, alpha: 0.35), width: 0.5))
                let size = max(10, min(f.height * 0.22, 22)).rounded()
                let font = NSFont.systemFont(ofSize: size, weight: .semibold) as CTFont
                guard let t = cache.text(String(keys[i]).uppercased(), font: font, size: size, color: art.text, tag: "grid", scale: scale)
                else { continue }
                let c = CGPoint(x: f.midX, y: f.midY)
                if f.height > 22 {
                    let h = t.1.height + size * 0.35, w = max(h, t.1.width + size * 0.9)
                    extras.addSublayer(
                        box(
                            CGRect(x: snap(c.x - w / 2), y: snap(c.y - h / 2), width: w, height: h), bg: art.bg, border: art.border,
                            width: 0.5, radius: min(h / 2, size * 0.6)))
                }
                extras.addSublayer(image(t, center: c))
            }
            extras.addSublayer(
                box(CGRect(x: r.midX - 3, y: r.midY - 3, width: 6, height: 6), bg: art.accent, border: .white, width: 1, radius: 3))
        }
        if let d = dragFrom, screen.contains(x: d.x, y: d.y) {
            let p = flip(CGRect(x: d.x, y: d.y, width: 0, height: 0))
            extras.addSublayer(
                box(CGRect(x: p.minX - 7, y: p.minY - 7, width: 14, height: 14), bg: art.accent, border: .white, width: 2, radius: 7))
        }
    }

    private func buildGridLabels(_ rect: Rect, _ cells: [GridLabelCell], _ typed: String, _ dragFrom: Point?, _ cache: OverlayImageCache) {
        let art = cache.art
        guard !rect.intersection(screen).isEmpty, let first = cells.first else { return }
        extras.addSublayer(box(flip(rect.cg), bg: CGColor(gray: 0, alpha: 0.12), border: art.accent.copy(alpha: 0.9), width: 1.5))
        let size = max(9, min(first.rect.height * 0.3, 15)).rounded()
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold) as CTFont
        let line = CGColor(gray: 1, alpha: 0.18)
        for c in cells {
            let match = typed.isEmpty || c.label.hasPrefix(typed)
            let f = flip(c.rect.cg)
            extras.addSublayer(box(f, bg: !typed.isEmpty && match ? art.accent.copy(alpha: 0.10) : nil, border: line, width: 0.5))
            guard match, let t = cache.text(c.label.uppercased(), font: font, size: size, color: art.text, tag: "grid2", scale: scale)
            else { continue }
            let center = CGPoint(x: f.midX, y: f.midY)
            let h = t.1.height + size * 0.3, w = t.1.width + size * 0.7
            extras.addSublayer(
                box(
                    CGRect(x: snap(center.x - w / 2), y: snap(center.y - h / 2), width: w, height: h), bg: art.bg, border: art.border,
                    width: 0.5, radius: min(h / 2, size * 0.5)))
            extras.addSublayer(image(t, center: center))
        }
        if let d = dragFrom, screen.contains(x: d.x, y: d.y) {
            let p = flip(CGRect(x: d.x, y: d.y, width: 0, height: 0))
            extras.addSublayer(
                box(CGRect(x: p.minX - 7, y: p.minY - 7, width: 14, height: 14), bg: art.accent, border: .white, width: 2, radius: 7))
        }
    }

    /// Mouse mode: a subtle accent ring around the pointer (filled while dragging).
    private func buildPointer(_ p: Point, _ dragging: Bool, _ cache: OverlayImageCache) {
        guard screen.contains(x: p.x, y: p.y) else { return }
        let art = cache.art
        let c = flip(CGRect(x: p.x, y: p.y, width: 0, height: 0)).origin
        let d: CGFloat = 34
        let ring = box(
            CGRect(x: snap(c.x - d / 2), y: snap(c.y - d / 2), width: d, height: d),
            bg: art.accent.copy(alpha: dragging ? 0.22 : 0.06), border: art.accent.copy(alpha: 0.85), width: dragging ? 2.5 : 1.5,
            radius: d / 2)
        ring.shadowColor = art.accent.copy(alpha: 0.35)
        ring.shadowOpacity = 1
        ring.shadowRadius = 4
        ring.shadowOffset = .zero
        extras.addSublayer(ring)
    }

    // MARK: Click feedback

    /// A brief accent ring that expands and fades at `point` (global top-left). Fire-and-forget, never blocks.
    func pulse(at point: CGPoint, accent: CGColor) {
        guard screen.contains(x: point.x, y: point.y) else { return }
        let p = flip(CGRect(x: point.x, y: point.y, width: 0, height: 0)).origin
        let d: CGFloat = 26
        let l = CALayer()
        l.contentsScale = scale
        l.frame = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
        l.cornerRadius = d / 2
        l.borderWidth = 2
        l.borderColor = accent
        l.backgroundColor = accent.copy(alpha: 0.18)
        l.opacity = 0
        root.addSublayer(l)
        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 0.4
        scaleAnim.toValue = 1.6
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 1.0, 0.0]
        fade.keyTimes = [0, 0.2, 1]
        let g = CAAnimationGroup()
        g.animations = [scaleAnim, fade]
        g.duration = 0.32
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        l.add(g, forKey: "pulse")
        CATransaction.commit()
    }
}

/// Nudges pills so they don't cover each other (tab strips, menu bars, dense toolbars).
/// Spatial hash over pill bodies; each pill tries its spot, then right / below / left / above of
/// whatever it collides with, and keeps its spot if nothing fits.
struct PillPlacer {
    let bounds: Rect
    private var cells: [Int: [Rect]] = [:]
    private static let cell = 48.0
    private static let gap = 1.0

    init(bounds: Rect, capacity: Int = 0) {
        self.bounds = bounds
        cells.reserveCapacity(capacity * 2)
    }

    private func hit(_ r: Rect) -> Rect? {
        let c = Self.cell
        for y in Int(r.y / c)...Int(r.maxY / c) {
            for x in Int(r.x / c)...Int(r.maxX / c) {
                guard let list = cells[y &* 4096 &+ x] else { continue }
                for o in list where r.x < o.maxX - 0.5 && o.x < r.maxX - 0.5 && r.y < o.maxY - 0.5 && o.y < r.maxY - 0.5 { return o }
            }
        }
        return nil
    }

    private func fits(_ r: Rect) -> Bool {
        r.x >= bounds.x && r.y >= bounds.y && r.maxX <= bounds.maxX && r.maxY <= bounds.maxY && hit(r) == nil
    }

    mutating func place(_ origin: Point, size: (w: Double, h: Double)) -> Point {
        var r = Rect(x: origin.x, y: origin.y, width: size.w, height: size.h)
        if let o = hit(r) {
            let g = Self.gap
            for t in [
                Rect(x: o.maxX + g, y: r.y, width: r.width, height: r.height),
                Rect(x: r.x, y: o.maxY + g, width: r.width, height: r.height),
                Rect(x: o.x - r.width - g, y: r.y, width: r.width, height: r.height),
                Rect(x: r.x, y: o.y - r.height - g, width: r.width, height: r.height),
            ] where fits(t) {
                r = t
                break
            }
        }
        let c = Self.cell
        for y in Int(r.y / c)...Int(r.maxY / c) {
            for x in Int(r.x / c)...Int(r.maxX / c) { cells[y &* 4096 &+ x, default: []].append(r) }
        }
        return Point(x: r.x, y: r.y)
    }
}
