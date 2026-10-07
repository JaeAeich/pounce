/// Layout-independent key input delivered to mode state machines.
public enum KeyInput: Sendable, Equatable {
    /// A printable character as produced by the active layout (Shift applied, e.g. "A", "?").
    case char(Character)
    case tab(backward: Bool)
    case arrow(Arrow, Modifiers)
    case returnKey(Modifiers)
    case space(Modifiers)
    case backspace
    case escape
    /// Control + letter, lowercase (e.g. ⌃N → "n").
    case control(Character)

    public enum Arrow: Sendable, Equatable { case left, right, up, down }
}

/// Turns a key's layout characters into the character a mode should see.
///
/// Policy:
/// - Case comes from Shift, never Caps Lock: Caps Lock on + Shift off → lowercase (so Caps Lock doesn't
///   turn search typing into "Shift+label" jumps or scroll dashes); Caps Lock + Shift → uppercase.
/// - Non-Latin layouts (Russian, Greek, Hebrew, Arabic…): when the active layout yields a non-ASCII
///   letter, mode keys (labels, scroll hjkl, grid keys) use the same physical key translated through the
///   ASCII-capable layout (`ascii`), so labels stay typeable without switching input source.
///   Search text keeps the real character (searching Cyrillic titles works), except Shift+letter, which is
///   the "Shift+label jump" and so is translated too.
/// - ASCII-producing layouts (US, Dvorak, Colemak, AZERTY letters…) are untouched: layout-aware as before.
public enum KeyText {
    public enum Purpose: Sendable {
        /// Real characters only (menu-search palette).
        case literal
        /// Hint search: real characters; Shift+letter (label jump) uses the ASCII translation.
        case search
        /// Label / mode keys: letters always ASCII-translated when the layout is non-Latin.
        case labels
    }

    public static func resolve(actual: Character, ascii: Character?, shift: Bool, capsLock: Bool, purpose: Purpose) -> Character {
        var c = actual
        if capsLock, !shift, c.isLetter { c = lower(c) }
        guard purpose != .literal, !c.isASCII, c.isLetter, let a = ascii, a.isASCII, a.isLetter else { return c }
        switch purpose {
        case .labels: return shift ? upper(a) : lower(a)
        case .search: return shift ? upper(a) : c
        case .literal: return c
        }
    }

    /// True if `c` is a letter outside ASCII, i.e. an ASCII translation may be needed.
    public static func needsTranslation(_ c: Character) -> Bool { c.isLetter && !c.isASCII }

    private static func lower(_ c: Character) -> Character {
        let s = c.lowercased()
        return s.count == 1 ? Character(s) : c
    }
    private static func upper(_ c: Character) -> Character {
        let s = c.uppercased()
        return s.count == 1 ? Character(s) : c
    }
}

/// Top-left-origin rectangle (same orientation as the Accessibility API).
public struct Rect: Sendable, Equatable, Hashable, CustomStringConvertible {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var area: Double { max(width, 0) * max(height, 0) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func intersection(_ o: Rect) -> Rect {
        let x0 = max(x, o.x), y0 = max(y, o.y)
        let x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
        return x1 > x0 && y1 > y0 ? Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) : .zero
    }

    public func contains(x px: Double, y py: Double) -> Bool { px >= x && px < maxX && py >= y && py < maxY }

    public var description: String { "(\(Int(x)),\(Int(y)) \(Int(width))×\(Int(height)))" }
}

public struct Point: Sendable, Equatable, Hashable {
    public var x, y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum Geometry {
    /// Converts a Cocoa (bottom-left origin) screen frame into global top-left coordinates.
    public static func topLeftFrame(ofCocoa f: Rect, primaryHeight: Double) -> Rect {
        Rect(x: f.x, y: primaryHeight - f.y - f.height, width: f.width, height: f.height)
    }

    /// Converts a global top-left rect into coordinates local to a screen (top-left of that screen = 0,0).
    public static func local(_ r: Rect, inScreenTopLeft s: Rect) -> Rect {
        Rect(x: r.x - s.x, y: r.y - s.y, width: r.width, height: r.height)
    }

    /// Where a label of `size` should sit for an element. Small elements (icons): centred.
    /// Wider ones: straddling the left edge so the element's own text stays readable.
    /// Tall ones: at the top rather than mid-height. Always clamped to the bounds.
    public static func labelOrigin(for element: Rect, size: (w: Double, h: Double), bounds: Rect) -> Point {
        var px = element.width < size.w * 2.5 ? element.midX - size.w / 2 : element.x - size.w / 2
        var py = element.height < size.h * 3 ? element.midY - size.h / 2 : element.y + 2
        px = min(max(px, bounds.x), bounds.maxX - size.w)
        py = min(max(py, bounds.y), bounds.maxY - size.h)
        return Point(x: px, y: py)
    }
}
