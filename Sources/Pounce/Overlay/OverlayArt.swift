import AppKit
import CoreText
import PounceCore
import QuartzCore
import SwiftUI

/// Pre-rendered bitmaps for everything the layer renderer draws. Immutable per style, so it's safe to
/// rasterise from any thread (pure CoreGraphics + CoreText, no AppKit drawing state).
final class OverlayArt: @unchecked Sendable {
    let style: OverlayStyle
    let theme: Theme  // resolved (never .system)
    let bg, text, typed, border, accent, focusText, focusTyped, shadow: CGColor
    let gradient: CGGradient?
    let font: CTFont
    let focusFont: CTFont
    let capHeight: CGFloat
    let focusCapHeight: CGFloat

    /// Focused pills are drawn this much larger (no transform → stays crisp).
    static let focusScale = 1.12
    /// Transparent border baked around pills for the drop shadow.
    static let margin = 4.0
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Bitmaps are rendered in the display's colour space: CA then uploads them as-is instead of colour-matching
    /// every pixel at commit (that conversion was ~2/3 of first-show time).
    let space: CGColorSpace

    init(style: OverlayStyle, space: CGColorSpace) {
        self.style = style
        self.space = space
        theme = style.resolvedTheme
        let p = style.palette
        func cg(_ c: Color) -> CGColor { NSColor(c).usingColorSpace(.sRGB)?.cgColor ?? NSColor(c).cgColor }
        bg = cg(p.background)
        text = cg(p.text)
        typed = cg(p.typedText)
        border = cg(p.border)
        accent = cg(p.accent)
        focusText = cg(p.focusText)
        focusTyped = focusText.copy(alpha: 0.5) ?? focusText
        shadow = CGColor(gray: 0, alpha: theme == .light ? 0.28 : 0.32)
        gradient = p.gradient.map { cs in
            CGGradient(colorsSpace: Self.sRGB, colors: cs.map { cg($0) } as CFArray, locations: nil)!
        }
        // SF Pro (SF Pro Rounded for the playful vimium theme), semibold: legible at 10–12 pt without shouting.
        font = Self.labelFont(style.size, rounded: theme == .vimium)
        focusFont = Self.labelFont(style.size * Self.focusScale, rounded: theme == .vimium)
        capHeight = CTFontGetCapHeight(font)
        focusCapHeight = CTFontGetCapHeight(focusFont)
    }

    @MainActor static func displaySpace(_ screen: NSScreen? = NSScreen.main) -> CGColorSpace {
        screen?.colorSpace?.cgColorSpace ?? sRGB
    }

    static func labelFont(_ size: Double, rounded: Bool) -> CTFont {
        rounded ? Self.rounded(size, .bold) : NSFont.systemFont(ofSize: size, weight: .semibold) as CTFont
    }

    static func rounded(_ size: Double, _ weight: NSFont.Weight) -> CTFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let d = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        return (NSFont(descriptor: d, size: size) ?? base) as CTFont
    }

    // MARK: Pills

    /// Point size of a pill's visible body (without shadow margin).
    func pillSize(_ label: String, focused: Bool) -> CGSize {
        let s = style.labelSize(label)
        let k = focused ? Self.focusScale : 1
        return CGSize(width: s.w * k, height: s.h * k)
    }

    /// Pixel size of a pill sprite including its shadow margin.
    func pillPixels(_ key: PillKey) -> (w: Int, h: Int) {
        let b = pillSize(key.label, focused: key.focused)
        let s = CGFloat(key.scale), m = Self.margin
        return (Int(ceil((b.width + 2 * m) * s)), Int(ceil((b.height + 2 * m) * s)))
    }

    /// Body + shadow + border for a pill of `chars` characters; shared by every label of that length.
    func chrome(chars: Int, focused: Bool, drag: Bool, scale: CGFloat) -> CGImage? {
        let label = String(repeating: "x", count: max(chars, 1))
        let body = pillSize(label, focused: focused)
        let m = Self.margin
        guard let ctx = context(CGSize(width: body.width + 2 * m, height: body.height + 2 * m), scale: scale) else { return nil }
        let k = focused ? Self.focusScale : 1
        let rect = CGRect(x: m, y: m, width: body.width, height: body.height)
        let r = min(style.size * 0.42 * k, body.height / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        // Soft drop shadow (shadow params are in device pixels).
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -0.5 * scale), blur: (focused ? 5 : 3) * scale,
            color: focused ? accent.copy(alpha: 0.4) : shadow)
        ctx.addPath(path)
        ctx.setFillColor(focused ? accent : bg)
        ctx.fillPath()
        ctx.restoreGState()
        if !focused, let g = gradient {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
            ctx.restoreGState()
        }
        let lw: CGFloat = drag ? 2 : 0.5
        let inner = rect.insetBy(dx: lw / 2, dy: lw / 2)
        ctx.addPath(CGPath(roundedRect: inner, cornerWidth: r - lw / 2, cornerHeight: r - lw / 2, transform: nil))
        ctx.setStrokeColor(drag ? (focused ? focusText : accent) : (focused ? CGColor(gray: 1, alpha: 0.25) : border))
        ctx.setLineWidth(lw)
        ctx.strokePath()
        return ctx.makeImage()
    }

    /// Draws a whole pill into `ctx` (already scaled to points, sized to the sprite).
    func drawPill(_ key: PillKey, chrome: CGImage?, in ctx: CGContext) {
        let body = pillSize(key.label, focused: key.focused)
        let m = Self.margin
        let scale = CGFloat(key.scale)
        let rect = CGRect(x: m, y: m, width: body.width, height: body.height)
        if let chrome {
            ctx.draw(chrome, in: CGRect(x: 0, y: 0, width: CGFloat(chrome.width) / scale, height: CGFloat(chrome.height) / scale))
        }
        // Label: typed prefix dimmed, optically centred on cap height.
        let k = key.focused ? Self.focusScale : 1
        let label = key.label.uppercased()
        let n = min(Int(key.typed), label.count)
        let f = key.focused ? focusFont : font
        let kern = (theme == .vimium ? 0.6 : 0.35) * k
        let cap = key.focused ? focusCapHeight : capHeight
        let baseline = (rect.midY - cap / 2).rounded(toPixel: scale)
        let typedColor = key.focused ? focusTyped : typed, restColor = key.focused ? focusText : text
        // Fast path: direct glyph drawing (no attributed string / CTLine; scales across threads).
        let units = Array(label.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        if units.count == label.count, CTFontGetGlyphsForCharacters(f, units, &glyphs, units.count) {
            var adv = [CGSize](repeating: .zero, count: glyphs.count)
            CTFontGetAdvancesForGlyphs(f, .horizontal, glyphs, &adv, glyphs.count)
            let w = adv.reduce(0) { $0 + $1.width } + kern * CGFloat(max(glyphs.count - 1, 0))
            var x = rect.midX - w / 2
            var pos = [CGPoint](repeating: .zero, count: glyphs.count)
            for i in glyphs.indices {
                pos[i] = CGPoint(x: x, y: baseline)
                x += adv[i].width + kern
            }
            if n > 0 {
                ctx.setFillColor(typedColor)
                CTFontDrawGlyphs(f, glyphs, pos, n, ctx)
            }
            if n < glyphs.count {
                ctx.setFillColor(restColor)
                glyphs.withUnsafeBufferPointer { g in
                    pos.withUnsafeBufferPointer { p in CTFontDrawGlyphs(f, g.baseAddress! + n, p.baseAddress! + n, glyphs.count - n, ctx) }
                }
            }
            return
        }
        let s = NSMutableAttributedString()
        s.append(
            NSAttributedString(
                string: String(label.prefix(n)),
                attributes: [
                    .init(kCTFontAttributeName as String): f, .init(kCTForegroundColorAttributeName as String): typedColor,
                    .init(kCTKernAttributeName as String): kern,
                ]))
        s.append(
            NSAttributedString(
                string: String(label.dropFirst(n)),
                attributes: [
                    .init(kCTFontAttributeName as String): f, .init(kCTForegroundColorAttributeName as String): restColor,
                    .init(kCTKernAttributeName as String): kern,
                ]))
        let line = CTLineCreateWithAttributedString(s)
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - kern
        ctx.textPosition = CGPoint(x: rect.midX - w / 2, y: baseline)
        CTLineDraw(line, ctx)
    }

    /// A standalone pill image (SwiftUI previews).
    func pill(_ key: PillKey) -> CGImage? {
        let px = pillPixels(key)
        let s = CGFloat(key.scale)
        guard let ctx = context(CGSize(width: CGFloat(px.w) / s, height: CGFloat(px.h) / s), scale: s) else { return nil }
        drawPill(key, chrome: chrome(chars: key.label.count, focused: key.focused, drag: key.drag, scale: s), in: ctx)
        return ctx.makeImage()
    }

    /// Rasterises many pills into one shared atlas image (one texture upload instead of one per pill), in parallel:
    /// each worker draws through its own CGContext aimed at a disjoint region of the same buffer.
    func atlas(_ keys: [PillKey], chromes: [ChromeKey: CGImage]) -> [PillKey: PillSprite] {
        guard !keys.isEmpty else { return [:] }
        let pageW = 2048
        var slots: [(x: Int, y: Int, w: Int, h: Int)] = []
        slots.reserveCapacity(keys.count)
        var rows: [(y: Int, h: Int, items: Range<Int>)] = []  // shelf rows
        var x = 0, y = 0, rowH = 0, rowStart = 0
        for (i, k) in keys.enumerated() {
            let p = pillPixels(k)
            if x + p.w > pageW {
                rows.append((y, rowH, rowStart..<i))
                x = 0
                y += rowH
                rowH = 0
                rowStart = i
            }
            slots.append((x, y, p.w, p.h))
            x += p.w
            rowH = max(rowH, p.h)
        }
        rows.append((y, rowH, rowStart..<keys.count))
        let pageH = y + rowH
        let rowBytes = pageW * 4
        let bytes = rowBytes * pageH
        guard let base = calloc(bytes, 1) else { return [:] }
        // Chrome pixels are blitted with memcpy; drawing one shared CGImage from many threads serialises on its lock.
        var raw: [ChromeKey: (data: CFData, rowBytes: Int, w: Int, h: Int)] = [:]
        for (ck, img) in chromes where img.bitsPerPixel == 32 {
            if let d = img.dataProvider?.data { raw[ck] = (d, img.bytesPerRow, img.width, img.height) }
        }
        // Workers each own a band of whole shelf rows with a single CGContext (context creation doesn't scale).
        let bandCount = min(rows.count, max(1, ProcessInfo.processInfo.activeProcessorCount))
        let perBand = (rows.count + bandCount - 1) / bandCount
        nonisolated(unsafe) let mem = base
        let ks = keys, sl = slots, rw = raw, ch = chromes, rs = rows
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        DispatchQueue.concurrentPerform(iterations: bandCount) { band in
            let r0 = band * perBand, r1 = min(rs.count, r0 + perBand)
            guard r0 < r1 else { return }
            let y0 = rs[r0].y, y1 = rs[r1 - 1].y + rs[r1 - 1].h
            let bandH = y1 - y0
            guard bandH > 0,
                let ctx = CGContext(
                    data: mem + y0 * rowBytes, width: pageW, height: bandH, bitsPerComponent: 8,
                    bytesPerRow: rowBytes, space: space, bitmapInfo: info)
            else { return }
            ctx.setShouldSmoothFonts(false)
            ctx.setAllowsFontSubpixelPositioning(true)
            ctx.setShouldSubpixelPositionFonts(true)
            ctx.textMatrix = .identity
            for row in rs[r0..<r1] {
                for i in row.items {
                    let k = ks[i], r = sl[i]
                    let s = CGFloat(k.scale)
                    var chrome = ch[ChromeKey(k)]
                    if let c = rw[ChromeKey(k)], c.w == r.w, c.h == r.h, let src = CFDataGetBytePtr(c.data) {
                        let dst = mem + r.y * rowBytes + r.x * 4
                        for line in 0..<r.h { memcpy(dst + line * rowBytes, src + line * c.rowBytes, r.w * 4) }
                        chrome = nil
                    }
                    ctx.saveGState()
                    // Band context is y-up from its bottom edge.
                    ctx.translateBy(x: CGFloat(r.x), y: CGFloat(y1 - r.y - r.h))
                    ctx.clip(to: CGRect(x: 0, y: 0, width: r.w, height: r.h))
                    ctx.scaleBy(x: s, y: s)
                    drawPill(k, chrome: chrome, in: ctx)
                    ctx.restoreGState()
                }
            }
        }
        let data = Data(bytesNoCopy: base, count: bytes, deallocator: .free)
        guard let provider = CGDataProvider(data: data as CFData),
            let page = CGImage(
                width: pageW, height: pageH, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return [:] }
        var out: [PillKey: PillSprite] = [:]
        out.reserveCapacity(keys.count)
        for (i, k) in keys.enumerated() {
            let r = slots[i], s = CGFloat(k.scale)
            // CGImage crop rects are in pixels from the top-left: unambiguous.
            guard let img = page.cropping(to: CGRect(x: r.x, y: r.y, width: r.w, height: r.h)) else { continue }
            out[k] = PillSprite(page: page, image: img, size: CGSize(width: CGFloat(r.w) / s, height: CGFloat(r.h) / s))
        }
        return out
    }

    // MARK: Window badges

    func windowBadge(label: String, typed n: Int, focused: Bool, title: String?, icon: NSImage?, scale: CGFloat) -> CGImage? {
        let pad = CGSize(width: 16, height: 14), m = 18.0, iconSide = 36.0, radius = 22.0
        let labelFont = theme == .vimium ? Self.rounded(26, .heavy) : NSFont.systemFont(ofSize: 24, weight: .bold) as CTFont
        let titleFont = NSFont.systemFont(ofSize: 12, weight: .regular) as CTFont
        let up = label.uppercased()
        let k = min(n, up.count)
        let ls = NSMutableAttributedString(string: String(up.prefix(k)), attributes: attrs(labelFont, focused ? focusTyped : typed))
        ls.append(NSAttributedString(string: String(up.dropFirst(k)), attributes: attrs(labelFont, focused ? focusText : text)))
        let labelLine = CTLineCreateWithAttributedString(ls)
        let labelW = CGFloat(CTLineGetTypographicBounds(labelLine, nil, nil, nil))
        var titleLine: CTLine?
        if let title, !title.isEmpty {
            let c = (focused ? focusText : text).copy(alpha: focused ? 0.75 : 0.62)!
            let full = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: attrs(titleFont, c)))
            let ell = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs(titleFont, c)))
            titleLine = CTLineCreateTruncatedLine(full, 260, .end, ell) ?? full
        }
        let titleW = titleLine.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) } ?? 0
        let rowW = (icon != nil ? iconSide + 10 : 0) + labelW
        let rowH = iconSide, titleH = titleLine != nil ? 15.0 : 0
        let body = CGSize(
            width: ceil(max(rowW, titleW) + pad.width * 2), height: ceil(pad.height * 2 + rowH + (titleLine != nil ? 8 + titleH : 0)))
        guard let ctx = context(CGSize(width: body.width + 2 * m, height: body.height + 2 * m), scale: scale) else { return nil }
        let rect = CGRect(x: m, y: m, width: body.width, height: body.height)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3 * scale), blur: 14 * scale, color: CGColor(gray: 0, alpha: 0.22))
        ctx.addPath(path)
        ctx.setFillColor(focused ? accent : (bg.alpha < 0.95 ? bg.copy(alpha: 0.95)! : bg))
        ctx.fillPath()
        ctx.restoreGState()
        if !focused, let g = gradient {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
            ctx.restoreGState()
        }
        ctx.addPath(
            CGPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), cornerWidth: radius - 0.25, cornerHeight: radius - 0.25, transform: nil))
        ctx.setStrokeColor(focused ? CGColor(gray: 1, alpha: 0.25) : border)
        ctx.setLineWidth(0.5)
        ctx.strokePath()
        // Row (top) — CG is y-up, so the row sits at the top edge.
        let rowY = rect.maxY - pad.height - rowH
        var x = rect.midX - rowW / 2
        if let icon, let cgi = icon.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: AffineTransform(scale: scale)]) {
            ctx.interpolationQuality = .high
            ctx.draw(cgi, in: CGRect(x: x, y: rowY, width: iconSide, height: iconSide))
            x += iconSide + 10
        }
        ctx.textPosition = CGPoint(x: x, y: rowY + (rowH - CTFontGetCapHeight(labelFont)) / 2)
        CTLineDraw(labelLine, ctx)
        if let t = titleLine {
            ctx.textPosition = CGPoint(x: rect.midX - titleW / 2, y: rect.minY + pad.height + 3.5)
            CTLineDraw(t, ctx)
        }
        return ctx.makeImage()
    }

    // MARK: Plain text (grid keys, scroll-area numbers)

    /// Text image, tightly fit to the line's typographic box. Returns the image and its point size.
    func textImage(_ string: String, font: CTFont, color: CGColor, scale: CGFloat) -> (CGImage, CGSize)? {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: string,
                attributes: [
                    .init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): color,
                ]))
        var asc: CGFloat = 0, desc: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, nil))
        let cap = CTFontGetCapHeight(font)
        // Box = cap height plus a little room; baseline placed so caps are centred.
        let size = CGSize(width: ceil(w + 2), height: ceil(asc + desc + 2))
        guard let ctx = context(size, scale: scale) else { return nil }
        ctx.textPosition = CGPoint(x: 1, y: (size.height / 2 - cap / 2).rounded(toPixel: scale))
        CTLineDraw(line, ctx)
        return ctx.makeImage().map { ($0, size) }
    }

    private func attrs(_ f: CTFont, _ c: CGColor) -> [NSAttributedString.Key: Any] {
        [.init(kCTFontAttributeName as String): f, .init(kCTForegroundColorAttributeName as String): c]
    }

    func context(_ size: CGSize, scale: CGFloat) -> CGContext? {
        let ctx = CGContext(
            data: nil, width: max(1, Int(ceil(size.width * scale))), height: max(1, Int(ceil(size.height * scale))),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.scaleBy(x: scale, y: scale)
        ctx?.setShouldSmoothFonts(false)
        ctx?.setAllowsFontSubpixelPositioning(true)
        ctx?.setShouldSubpixelPositionFonts(true)
        ctx?.textMatrix = .identity
        return ctx
    }
}

struct PillKey: Hashable, Sendable {
    var label: String
    var typed: UInt8
    var focused: Bool
    var drag: Bool
    var scale: UInt8
}

struct ChromeKey: Hashable, Sendable {
    var chars: Int, focused: Bool, drag: Bool, scale: UInt8
    init(_ k: PillKey) {
        chars = k.label.count
        focused = k.focused
        drag = k.drag
        scale = k.scale
    }
}

/// A pill inside an atlas page. `image` is a crop of the page (shares its pixels, no copy), set as
/// layer.contents directly: a contentsRect into the page is interpreted bottom-up by the window server
/// but top-down by `CALayer.render(in:)`, which drew the wrong pills on screen.
struct PillSprite {
    let page: CGImage
    let image: CGImage
    let size: CGSize  // points, including shadow margin
}

/// Main-thread sprite cache. Misses are rasterised in parallel into a fresh atlas page;
/// `prewarm` does the same in the background at launch.
@MainActor
final class OverlayImageCache {
    private(set) var art: OverlayArt
    private var pills: [PillKey: PillSprite] = [:]
    private var chromes: [ChromeKey: CGImage] = [:]
    private var misc: [String: (CGImage, CGSize)] = [:]
    private var generation = 0
    /// Bytes of atlas pages referenced by `pills` (approximate; pages are freed when unreferenced).
    private var atlasBytes = 0

    init(style: OverlayStyle) { art = OverlayArt(style: style, space: OverlayArt.displaySpace()) }

    /// Swaps art when the style (or the system appearance behind `.system`) changes.
    func use(_ style: OverlayStyle, space: CGColorSpace, force: Bool = false) {
        if !force && style == art.style && style.resolvedTheme == art.theme && space == art.space { return }
        art = OverlayArt(style: style, space: space)
        removeAll()
    }

    func removeAll() {
        pills.removeAll(keepingCapacity: true)
        chromes.removeAll()
        misc.removeAll()
        atlasBytes = 0
        generation += 1
    }

    var count: Int { pills.count }

    func sprite(_ k: PillKey) -> PillSprite? { pills[k] }

    /// Makes sure every key has a sprite (one new atlas page for all misses).
    func fill(_ keys: [PillKey]) {
        var seen = Set<PillKey>()
        let missing = keys.filter { pills[$0] == nil && seen.insert($0).inserted }
        guard !missing.isEmpty else { return }
        if atlasBytes > 96 << 20 {
            pills.removeAll(keepingCapacity: true)
            atlasBytes = 0
        }  // cap memory; re-render on demand
        let sprites = art.atlas(missing, chromes: chromes(for: missing))
        insert(sprites)
    }

    private func chromes(for keys: [PillKey]) -> [ChromeKey: CGImage] {
        for k in keys {
            let c = ChromeKey(k)
            if chromes[c] == nil, let img = art.chrome(chars: c.chars, focused: c.focused, drag: c.drag, scale: CGFloat(c.scale)) {
                chromes[c] = img
            }
        }
        return chromes
    }

    private func insert(_ sprites: [PillKey: PillSprite]) {
        guard let page = sprites.first?.value.page else { return }
        atlasBytes += page.bytesPerRow * page.height
        pills.merge(sprites) { old, _ in old }
    }

    /// Background-renders resting pills for the first `count` labels of `alphabet`.
    func prewarm(alphabet: String, count: Int = 1600, scales: [CGFloat]) {
        let art = self.art, gen = generation
        var keys: [PillKey] = []
        for s in Set(scales.map { UInt8(max(1, min(4, $0.rounded()))) }) {
            for l in Labels.generate(count: count, alphabet: alphabet) {
                let k = PillKey(label: l, typed: 0, focused: false, drag: false, scale: s)
                if pills[k] == nil { keys.append(k) }
            }
        }
        guard !keys.isEmpty else { return }
        let ch = chromes(for: keys)
        let ks = keys
        DispatchQueue.global(qos: .userInitiated).async {
            let sprites = art.atlas(ks, chromes: ch)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard gen == self.generation else { return }
                    self.insert(sprites)
                }
            }
        }
    }

    func text(_ s: String, font: CTFont, size: Double, color: CGColor, tag: String, scale: CGFloat) -> (CGImage, CGSize)? {
        let key = "\(tag)|\(s)|\(size)|\(scale)"
        if let v = misc[key] { return v }
        let v = art.textImage(s, font: font, color: color, scale: scale)
        misc[key] = v
        return v
    }

    func window(_ b: HintBadge, scale: CGFloat) -> CGImage? {
        let key = "win|\(b.label)|\(b.typed)|\(b.focused)|\(b.title ?? "")|\(b.icon.map { ObjectIdentifier($0).hashValue } ?? 0)|\(scale)"
        if let v = misc[key] { return v.0 }
        guard let i = art.windowBadge(label: b.label, typed: b.typed, focused: b.focused, title: b.title, icon: b.icon, scale: scale) else {
            return nil
        }
        misc[key] = (i, .zero)
        return i
    }
}

extension CGFloat {
    func rounded(toPixel scale: CGFloat) -> CGFloat { (self * scale).rounded() / scale }
}
