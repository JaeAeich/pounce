public enum GridEffect: Sendable, Equatable {
    case update
    case click(Point, HintAction)
    case move(Point)
    case drag(from: Point, to: Point)
    case nextScreen
    case exit
    case warn
}

public enum GridStyle: String, Sendable, CaseIterable {
    /// Split the screen 3×3 again and again.
    case recursive
    /// Mouseless style: two letters pick one of ~26×17 cells, then 3×3 keys refine.
    case twokey
}

/// A cell of the two-key grid and its label (row letter + column letter).
public struct GridLabelCell: Sendable, Equatable, Hashable {
    public var rect: Rect
    public var label: String
}

/// Grid mode: recursively split the screen 3×3 to reach any point without accessibility data.
/// `.twokey` style first picks a labelled cell with two letters, then refines 3×3 the same way.
public struct GridSession: Sendable {
    public private(set) var rect: Rect
    public private(set) var history: [Rect] = []
    public private(set) var dragFrom: Point?
    public let keys: [Character]
    public static let minCell = 6.0
    public let style: GridStyle
    /// Two-key labels: letters for rows (first key) and columns (second key).
    public let labelKeys: [Character]
    public private(set) var bounds: Rect
    /// Two-key style: still choosing the labelled cell (3×3 keys not active yet).
    public private(set) var picking: Bool
    /// Two-key style: the row letter typed so far.
    public private(set) var firstKey: Character?

    public static let defaultLabelKeys = "abcdefghijklmnopqrstuvwxyz"

    public init(bounds: Rect, keys: String = "uiojklm,.", style: GridStyle = .recursive, labelKeys: String = GridSession.defaultLabelKeys) {
        rect = bounds
        self.bounds = bounds
        let k = Labels.uniqueChars(keys)
        self.keys = k.count == 9 ? k : Labels.uniqueChars("uiojklm,.")
        self.style = style
        let l = Labels.uniqueChars(labelKeys)
        self.labelKeys = l.count >= 2 ? l : Labels.uniqueChars(Self.defaultLabelKeys)
        picking = style == .twokey
    }

    /// Rows × columns of the two-key grid: the long screen side gets one cell per letter,
    /// the short side as many as keep cells roughly square.
    public var labelGrid: (rows: Int, cols: Int) {
        let n = labelKeys.count
        guard bounds.width > 0, bounds.height > 0 else { return (n, n) }
        if bounds.width >= bounds.height {
            return (min(n, max(1, Int((Double(n) * bounds.height / bounds.width).rounded()))), n)
        }
        return (n, min(n, max(1, Int((Double(n) * bounds.width / bounds.height).rounded()))))
    }

    public func labelCell(row: Int, col: Int) -> Rect {
        let (r, c) = labelGrid
        let w = bounds.width / Double(c), h = bounds.height / Double(r)
        return Rect(x: bounds.x + Double(col) * w, y: bounds.y + Double(row) * h, width: w, height: h)
    }

    /// Two-key cells, row-major (all of them; the renderer dims rows not matching `firstKey`).
    public var labelCells: [GridLabelCell] {
        let (r, c) = labelGrid
        var out: [GridLabelCell] = []
        out.reserveCapacity(r * c)
        for i in 0..<r {
            for j in 0..<c { out.append(GridLabelCell(rect: labelCell(row: i, col: j), label: String([labelKeys[i], labelKeys[j]]))) }
        }
        return out
    }

    public var center: Point { Point(x: rect.midX, y: rect.midY) }

    /// Sub-cells of the current rect, row-major.
    public var cells: [Rect] {
        let w = rect.width / 3, h = rect.height / 3
        return (0..<9).map { i in Rect(x: rect.x + Double(i % 3) * w, y: rect.y + Double(i / 3) * h, width: w, height: h) }
    }

    public mutating func reset(bounds: Rect) {
        self.bounds = bounds
        rect = bounds
        history = []
        picking = style == .twokey
        firstKey = nil
    }

    private mutating func pick(_ input: KeyInput) -> [GridEffect] {
        switch input {
        case .char(let c):
            let (rows, cols) = labelGrid
            guard let i = labelKeys.firstIndex(of: Character(c.lowercased())) else { return [] }
            guard let r = firstKey.flatMap({ labelKeys.firstIndex(of: $0) }) else {
                guard i < rows else { return [.warn] }
                firstKey = labelKeys[i]
                return [.update]
            }
            guard i < cols else { return [.warn] }
            rect = labelCell(row: r, col: i)
            picking = false
            firstKey = nil
            return [.update]
        case .backspace:
            guard firstKey != nil else { return [] }
            firstKey = nil
            return [.update]
        case .escape where firstKey != nil:
            firstKey = nil
            return [.update]
        case .returnKey, .space, .arrow: return [.warn]
        default: return []
        }
    }

    public mutating func handle(_ input: KeyInput) -> [GridEffect] {
        if picking {
            switch input {
            case .escape where firstKey == nil, .tab, .control: break
            default: return pick(input)
            }
        }
        switch input {
        case .escape:
            if dragFrom != nil {
                dragFrom = nil
                return [.update]
            }
            return [.exit]
        case .char(let c):
            guard let i = keys.firstIndex(of: Character(c.lowercased())) else { return [] }
            guard rect.width / 3 >= Self.minCell, rect.height / 3 >= Self.minCell else { return [.warn] }
            history.append(rect)
            rect = cells[i]
            return [.update]
        case .backspace:
            guard let prev = history.popLast() else {
                guard style == .twokey, !picking else { return [] }
                rect = bounds
                picking = true
                return [.update]
            }
            rect = prev
            return [.update]
        case .arrow(let a, _):
            // Nudge by half a cell.
            let dx = rect.width / 2, dy = rect.height / 2
            switch a {
            case .left: rect.x -= dx
            case .right: rect.x += dx
            case .up: rect.y -= dy
            case .down: rect.y += dy
            }
            return [.update]
        case .tab: return [.nextScreen]
        case .space: return [.move(center)]
        case .control("d"):
            dragFrom = center
            if style == .twokey {
                rect = bounds
                picking = true
                firstKey = nil
            } else if let first = history.first {
                rect = first
            }
            history = []
            return [.update]
        case .returnKey(let mods):
            if let from = dragFrom {
                dragFrom = nil
                return [.drag(from: from, to: center)]
            }
            let a: HintAction =
                mods.contains(.shift)
                ? .rightClick
                : mods.contains(.command)
                    ? .commandClick
                    : mods.contains(.option)
                        ? .optionClick
                        : mods.contains(.control) ? .doubleClick : .click
            return [.click(center, a)]
        default: return []
        }
    }
}
