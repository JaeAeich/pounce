import Foundation

public enum HintCategory: String, Sendable, CaseIterable { case button, link, input, other }

public enum RoleFilter: String, Sendable, CaseIterable {
    case all, inputs, links, buttons

    func accepts(_ c: HintCategory) -> Bool {
        switch self {
        case .all: true
        case .inputs: c == .input
        case .links: c == .link
        case .buttons: c == .button
        }
    }
}

public struct HintItem: Sendable, Equatable {
    /// Text searched by the query (title, description, value, role…).
    public var text: String
    /// Stable identity used to remember labels and usage across activations.
    public var key: String
    public var usage: Int
    public var category: HintCategory
    /// 0…1, how recently this target was used (1 = just now). See `UsageStore.recency`.
    public var recency: Double
    /// On-screen frame; equal-scoring matches are ordered top-to-bottom, left-to-right.
    public var frame: Rect?
    public init(
        text: String, key: String, usage: Int = 0, category: HintCategory = .other,
        recency: Double = 0, frame: Rect? = nil
    ) {
        self.text = text
        self.key = key
        self.usage = usage
        self.category = category
        self.recency = recency
        self.frame = frame
    }
}

/// How query matches are ranked: fuzzy score plus per-item boosts.
/// Boosts only reorder matches; they never make a non-match visible.
public struct HintRanking: Sendable, Equatable {
    /// Added per category (actionable controls above static text).
    public var button = 4, input = 3, link = 3, other = 0
    /// Usage boost = min(usageCap, usageWeight * log2(1 + usage)).
    public var usageWeight = 4.0
    public var usageCap = 12
    /// Recency boost = recencyWeight * item.recency.
    public var recencyWeight = 8.0
    public init() {}
    public static let `default` = HintRanking()

    public func boost(_ item: HintItem) -> Int {
        var b: Int
        switch item.category {
        case .button: b = button
        case .input: b = input
        case .link: b = link
        case .other: b = other
        }
        if item.usage > 0 {
            b += min(usageCap, Int((usageWeight * log2(1 + Double(item.usage))).rounded()))
        }
        if item.recency > 0 { b += Int((recencyWeight * min(item.recency, 1)).rounded()) }
        return b
    }
}

public enum WindowOp: String, Sendable, Equatable { case leftHalf, rightHalf, maximize, nextScreen }

public enum HintAction: Sendable, Equatable {
    case click, rightClick, commandClick, optionClick, doubleClick
    /// Middle button; back / forward = mouse buttons 4 / 5.
    case middleClick, back, forward
    case hover, yank, focus
    /// Click & type: focus a text input, then type the text.
    case fill(String)
    case drag(from: Int)
    case window(WindowOp)
}

public enum HintEffect: Sendable, Equatable {
    case update
    case activate(item: Int, HintAction)
    case exit
    case warn
    case toggleTutor
    case repeatLast
}

/// Keyboard state machine for hint-style modes (click, windows, menu search, text).
/// Pure: the caller renders `visible`/`labels`/`focused` and performs effects.
public struct HintSession: Sendable {
    public private(set) var items: [HintItem]
    public let alphabet: String
    public let labelsOnly: Bool
    public let autoClick: Bool

    public private(set) var query = ""
    public private(set) var typed = ""
    public private(set) var filter: RoleFilter = .all
    /// Item indices currently shown, best match first when searching.
    public private(set) var visible: [Int] = []
    /// Item index → label.
    public private(set) var labels: [Int: String] = [:]
    public private(set) var focused: Int?
    public private(set) var dragSource: Int?
    /// Click & type: text typed after `=` while the target is a text input (nil = not filling).
    public private(set) var fill: String?
    public let ranking: HintRanking

    // Precomputed once per session so keystrokes do no string work.
    private let corpus: Fuzzy.Corpus
    private var table: Labels.Table
    /// BFS position (in `table`) of each item's remembered label.
    private let previousPos: [Int32]
    private let boosts: [Int32]
    /// Item index → tie-break rank (on-screen order), and its inverse.
    private let tieRank: [Int32]
    private let byTie: [Int32]
    /// Results per query prefix: typing narrows the last frame, backspace pops.
    private var stack: [Frame] = []

    private struct Frame: Sendable {
        var query: Fuzzy.Query
        var visible: [Int]
        var labels: [Int: String]
    }

    public init(
        items: [HintItem], alphabet: String, labelsOnly: Bool = false, autoClick: Bool = true,
        previousLabels: [String: String] = [:], ranking: HintRanking = .default
    ) {
        self.items = items
        self.alphabet = alphabet
        self.labelsOnly = labelsOnly
        self.autoClick = autoClick
        self.ranking = ranking
        corpus = Fuzzy.Corpus(items.map(\.text))
        let table = Labels.Table(alphabet: alphabet, capacity: items.count)
        self.table = table
        previousPos =
            previousLabels.isEmpty
            ? [Int32](repeating: -1, count: items.count)
            : items.map { previousLabels[$0.key].flatMap(table.position(of:)).map { Int32(clamping: $0) } ?? -1 }
        boosts = items.map { Int32(clamping: ranking.boost($0)) }
        let order = HintSession.screenOrder(items)
        byTie = order
        var rank = [Int32](repeating: 0, count: items.count)
        for (r, i) in order.enumerated() { rank[Int(i)] = Int32(r) }
        tieRank = rank
        recompute()
    }

    /// Item indices sorted top-to-bottom, left-to-right (rows quantized to 4pt);
    /// frameless items follow in item order. No frames at all → item order.
    private static func screenOrder(_ items: [HintItem]) -> [Int32] {
        let idx = (0..<items.count).map { Int32($0) }
        guard items.contains(where: { $0.frame != nil }) else { return idx }
        func key(_ i: Int32) -> (Int, Double, Int32) {
            guard let f = items[Int(i)].frame else { return (Int.max, 0, i) }
            return (Int((f.y / 4).rounded(.down)), f.x, i)
        }
        return idx.sorted { key($0) < key($1) }
    }

    public func label(for item: Int) -> String? { labels[item] }

    /// Labels assigned in this session (key → label), to persist for next time.
    public var assignedLabels: [String: String] {
        Dictionary(labels.map { (items[$0.key].key, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    public mutating func handle(_ input: KeyInput) -> [HintEffect] {
        switch input {
        case .escape:
            if fill != nil {
                fill = nil
                return [.update]
            }
            if !typed.isEmpty || dragSource != nil {
                typed = ""
                dragSource = nil
                return [.update]
            }
            return [.exit]

        case .char(let c):
            if fill != nil {
                fill!.append(c)
                return [.update]
            }
            if c == "=", !labelsOnly, let t = target, items[t].category == .input {
                fill = ""
                typed = ""
                return [.update]
            }
            if c == "?" { return [.toggleTutor] }
            let isUpper = c.isUppercase
            if labelsOnly || isUpper { return typeLabel(Character(c.lowercased())) }
            if c == "*" || c == ";" { return [] }  // "show all" is the default
            query.append(c)
            typed = ""
            recompute(resetFocus: true)
            return [.update]

        case .space(let mods):
            if fill != nil {
                fill!.append(" ")
                return [.update]
            }
            if labelsOnly { return activate(action(for: mods)) }
            return []

        case .backspace:
            if let f = fill {
                fill = f.isEmpty ? nil : String(f.dropLast())
                return [.update]
            }
            if !typed.isEmpty {
                typed.removeLast()
            } else if !query.isEmpty {
                query.removeLast()
                recompute(resetFocus: true)
            } else {
                return []
            }
            return [.update]

        case .tab(let backward): return move(backward ? -1 : 1)
        case .arrow(.down, []): return move(1)
        case .arrow(.up, []): return move(-1)
        case .arrow(let a, let m) where m.contains(.option):
            let op: WindowOp =
                switch a {
                case .left: .leftHalf
                case .right: .rightHalf
                case .up: .maximize
                case .down: .nextScreen
                }
            return activate(.window(op))
        case .arrow: return []

        case .returnKey(let mods):
            if let f = fill { return activate(.fill(f)) }
            return activate(action(for: mods))

        case .control(let c):
            switch c {
            case "n", "j": return move(1)
            case "p", "k": return move(-1)
            case "y": return activate(.yank)
            case "h": return activate(.hover)
            case "f": return activate(.focus)
            case "m": return activate(.middleClick)
            case "o": return activate(.back)
            case "t": return activate(.forward)
            case "r": return [.repeatLast]
            case "u":
                query = ""
                typed = ""
                recompute(resetFocus: true)
                return [.update]
            case "d":
                guard let t = target else { return [.warn] }
                dragSource = dragSource == t ? nil : t
                return [.update]
            case "i": return setFilter(.inputs)
            case "l": return setFilter(.links)
            case "b": return setFilter(.buttons)
            case "a": return setFilter(.all)
            default: return []
            }
        }
    }

    // MARK: - Internals

    private var target: Int? { focused ?? (visible.count == 1 ? visible[0] : nil) }

    private func action(for mods: Modifiers) -> HintAction {
        if mods.contains(.shift) { return .rightClick }
        if mods.contains(.command) { return .commandClick }
        if mods.contains(.option) { return .optionClick }
        if mods.contains(.control) { return .doubleClick }
        return .click
    }

    private mutating func activate(_ a: HintAction) -> [HintEffect] {
        guard let t = target else { return [.warn] }
        if case .click = a, let src = dragSource, src != t {
            dragSource = nil
            return [.activate(item: t, .drag(from: src))]
        }
        return [.activate(item: t, a)]
    }

    private mutating func typeLabel(_ c: Character) -> [HintEffect] {
        let candidate = typed + String(c)
        let m = table.match(candidate, count: visible.count)
        if m == .none {
            typed = ""
            return [.warn, .update]
        }
        typed = candidate
        if m == .exact, let exact = visible.first(where: { labels[$0] == candidate }) {
            focused = exact
            typed = ""
            if autoClick { return activate(.click) }
        }
        return [.update]
    }

    private mutating func move(_ delta: Int) -> [HintEffect] {
        guard !visible.isEmpty else { return [.warn] }
        if let f = focused, let i = visible.firstIndex(of: f) {
            focused = visible[(i + delta + visible.count) % visible.count]
        } else {
            focused = delta > 0 ? visible.first : visible.last
        }
        return [.update]
    }

    private mutating func setFilter(_ f: RoleFilter) -> [HintEffect] {
        filter = (filter == f) ? .all : f
        typed = ""
        stack.removeAll()
        recompute(resetFocus: true)
        // gi-style: ⌃I then ⏎ focuses the first input on screen.
        if filter == .inputs, focused == nil { focused = visible.min { tieRank[$0] < tieRank[$1] } }
        return [.update]
    }

    private mutating func recompute(resetFocus: Bool = false) {
        let q = Fuzzy.Query(labelsOnly ? "" : query)
        // Reuse a cached frame for this exact query (backspace), else narrow the longest
        // cached prefix frame (typing), else start from the filtered base set.
        while let top = stack.last, !top.query.isPrefix(of: q) { stack.removeLast() }
        if stack.last?.query != q {
            let base: [Int]
            if let top = stack.last {
                base = top.visible
            } else {
                base = items.indices.filter { filter.accepts(items[$0].category) }
                if !q.isEmpty { stack.append(Frame(query: Fuzzy.Query(""), visible: base, labels: assignLabels(base))) }
            }
            let vis = q.isEmpty ? base : rank(base, q)
            let lab = (stack.last.map { $0.visible == vis } ?? false) ? stack.last!.labels : assignLabels(vis)
            stack.append(Frame(query: q, visible: vis, labels: lab))
        }
        visible = stack.last!.visible
        labels = stack.last!.labels
        if resetFocus {
            focused = query.isEmpty ? nil : visible.first
        } else if let f = focused, labels[f] == nil {
            focused = nil
        }
        if let d = dragSource, !items.indices.contains(d) { dragSource = nil }
    }

    /// Matches of `q` among `candidates`, best first; ties in on-screen order.
    private func rank(_ candidates: [Int], _ q: Fuzzy.Query) -> [Int] {
        // Pack (descending score, ascending tie rank) into one UInt64 so sorting is a plain integer sort.
        var keys: [UInt64] = []
        keys.reserveCapacity(candidates.count)
        for i in candidates where corpus.mayMatch(q, i) {
            guard let sc = corpus.score(q, i) else { continue }
            let r = UInt64(UInt32(bitPattern: Int32(1 << 30) - Int32(clamping: sc) - boosts[i]))
            keys.append(r << 32 | UInt64(UInt32(bitPattern: tieRank[i])))
        }
        keys.sort()
        return keys.map { Int(byTie[Int(UInt32(truncatingIfNeeded: $0))]) }
    }

    private func assignLabels(_ vis: [Int]) -> [Int: String] {
        let assigned = vis.withUnsafeBufferPointer { v in
            table.assign(
                count: v.count,
                previous: {
                    let p = previousPos[v[$0]]
                    return p >= 0 ? Int(p) : nil
                },
                usage: { items[v[$0]].usage })
        }
        var d = [Int: String](minimumCapacity: vis.count)
        for (i, l) in zip(vis, assigned) { d[i] = l }
        return d
    }
}
