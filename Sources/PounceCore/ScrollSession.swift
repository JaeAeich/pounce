public enum ScrollDirection: Sendable, Equatable, CaseIterable {
    case left, down, up, right

    public var vector: (dx: Double, dy: Double) {
        switch self {
        case .left: (-1, 0)
        case .right: (1, 0)
        case .up: (0, -1)
        case .down: (0, 1)
        }
    }
}

public enum ScrollEffect: Sendable, Equatable {
    case start(ScrollDirection, dash: Bool)
    case stop(ScrollDirection)
    case halfPage(down: Bool)
    case edge(top: Bool)
    case select(Int)
    case exit
    case warn
}

/// Scroll mode: hjkl to scroll (Shift = dash), d/u half page, gg/G edges,
/// Tab / digits to pick a scroll area.
public struct ScrollSession: Sendable {
    public private(set) var areaCount: Int
    public private(set) var selected: Int
    private let keys: [Character]  // left, down, up, right
    private var pendingG = false
    private var held: [Character: ScrollDirection] = [:]

    public init(areaCount: Int, selected: Int = 0, keys: String = "hjkl") {
        self.areaCount = areaCount
        self.selected = min(max(selected, 0), max(areaCount - 1, 0))
        let k = Array(keys.lowercased())
        self.keys = k.count == 4 ? k : Array("hjkl")
    }

    public mutating func keyDown(_ input: KeyInput) -> [ScrollEffect] {
        let wasG = pendingG
        pendingG = false
        switch input {
        case .escape: return [.exit]
        case .tab(let back): return cycle(back ? -1 : 1)
        case .arrow(.down, _), .control("n"): return cycle(1)
        case .arrow(.up, _), .control("p"): return cycle(-1)
        case .control("d"): return [.halfPage(down: true)]
        case .control("u"): return [.halfPage(down: false)]
        case .char(let c):
            let lower = Character(c.lowercased())
            if let i = keys.firstIndex(of: lower) {
                let dir = ScrollDirection.allCases[i]
                held[lower] = dir
                return [.start(dir, dash: c.isUppercase)]
            }
            switch c {
            case "d": return [.halfPage(down: true)]
            case "u": return [.halfPage(down: false)]
            case "G": return [.edge(top: false)]
            case "g":
                if wasG { return [.edge(top: true)] }
                pendingG = true
                return []
            default:
                if let n = c.wholeNumberValue {
                    let idx = n == 0 ? 9 : n - 1
                    guard idx < areaCount else { return [.warn] }
                    selected = idx
                    return [.select(idx)]
                }
                return []
            }
        default: return []
        }
    }

    public mutating func keyUp(_ input: KeyInput) -> [ScrollEffect] {
        guard case .char(let c) = input, let dir = held.removeValue(forKey: Character(c.lowercased())) else { return [] }
        return [.stop(dir)]
    }

    private mutating func cycle(_ d: Int) -> [ScrollEffect] {
        guard areaCount > 1 else { return [.warn] }
        selected = (selected + d + areaCount) % areaCount
        return [.select(selected)]
    }
}
