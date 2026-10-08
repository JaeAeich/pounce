/// Which physical mouse button a keyboard-cursor click uses.
public enum MouseButtonKind: Sendable, Equatable { case left, right, middle, back, forward }

public enum MouseEffect: Sendable, Equatable {
    /// Pointer movement keys changed (start the motion timer / redraw).
    case update
    case click(MouseButtonKind, count: Int, modifiers: Modifiers)
    case dragBegin
    case dragEnd
    /// Move the pointer by exactly this much (arrow nudges).
    case nudge(dx: Double, dy: Double)
    case scrollStart(down: Bool)
    case scrollStop(down: Bool)
    case exit
    case warn
}

/// Keyboard cursor ("Mouse" mode): held direction keys glide the pointer with ease-in acceleration,
/// Space/⏎ click, v toggles a drag. Pure: the caller runs a timer, calls `step` and posts the events.
public struct MouseSession: Sendable {
    public enum Speed: Sendable, Equatable { case normal, fast, slow }

    public struct Tuning: Sendable, Equatable {
        /// Top speed in pt/s per tier.
        public var speed = 1400.0, fastSpeed = 4200.0, slowSpeed = 260.0
        /// Speed when a key first goes down, as a fraction of the top speed.
        public var startFraction = 0.12
        /// Seconds to reach top speed (ease-in).
        public var ramp = 0.35
        public init() {}
        public init(speed: Double, fastSpeed: Double, slowSpeed: Double, ramp: Double = 0.35) {
            self.speed = speed
            self.fastSpeed = fastSpeed
            self.slowSpeed = slowSpeed
            self.ramp = ramp
        }

        func top(_ s: Speed) -> Double {
            switch s {
            case .normal: speed
            case .fast: fastSpeed
            case .slow: slowSpeed
            }
        }

        /// Speed after holding for `t` seconds: quadratic ease-in from `startFraction` to 1.
        public func speed(after t: Double, _ s: Speed) -> Double {
            let x = ramp > 0 ? min(max(t / ramp, 0), 1) : 1
            return top(s) * (startFraction + (1 - startFraction) * x * x)
        }
    }

    private let keys: [Character]  // left, down, up, right
    public let tuning: Tuning
    /// Direction → seconds held.
    public private(set) var held: [ScrollDirection: Double] = [:]
    public private(set) var dragging = false
    private var heldChar: [Character: ScrollDirection] = [:]
    private var scrolling: [Character: Bool] = [:]

    public init(keys: String = "hjkl", tuning: Tuning = Tuning()) {
        let k = Array(keys.lowercased())
        self.keys = k.count == 4 && Set(k).count == 4 ? k : Array("hjkl")
        self.tuning = tuning
    }

    public var isMoving: Bool { !held.isEmpty }

    public mutating func keyDown(_ input: KeyInput) -> [MouseEffect] {
        switch input {
        case .escape:
            if dragging {
                dragging = false
                return [.dragEnd, .exit]
            }
            return [.exit]
        case .char(let c):
            let lower = Character(c.lowercased())
            if let i = keys.firstIndex(of: lower) {
                let d = ScrollDirection.allCases[i]
                if heldChar[lower] == nil {
                    heldChar[lower] = d
                    if held[d] == nil { held[d] = 0 }
                }
                return [.update]
            }
            switch lower {
            case "r": return click(.right)
            case "m": return click(.middle)
            case "c": return click(.left, count: 2)
            case "[": return click(.back)
            case "]": return click(.forward)
            case "v":
                dragging.toggle()
                return [dragging ? .dragBegin : .dragEnd, .update]
            case "d", "u":
                let down = lower == "d"
                guard scrolling[lower] == nil else { return [] }
                scrolling[lower] = down
                return [.scrollStart(down: down)]
            default: return []
            }
        case .space(let m): return click(.left, modifiers: m.subtracting([.shift, .option]))
        case .returnKey(let m):
            if m.contains(.shift) { return click(.right) }
            if m.contains(.control) { return click(.left, count: 2) }
            return click(.left, modifiers: m.intersection([.command, .option]))
        case .arrow(let a, let m):
            let n = m.contains(.shift) ? 10.0 : 1.0
            let v = Self.vector(a)
            return [.nudge(dx: v.dx * n, dy: v.dy * n)]
        default: return []
        }
    }

    public mutating func keyUp(_ input: KeyInput) -> [MouseEffect] {
        guard case .char(let c) = input else { return [] }
        let lower = Character(c.lowercased())
        if let d = heldChar.removeValue(forKey: lower) {
            if !heldChar.values.contains(d) { held[d] = nil }
            return [.update]
        }
        if let down = scrolling.removeValue(forKey: lower) { return [.scrollStop(down: down)] }
        return []
    }

    /// Releases every held key and ends a drag (mode stop).
    public mutating func releaseAll() {
        dragging = false
        held = [:]
        heldChar = [:]
        scrolling = [:]
    }

    /// Advances held motion by `dt` seconds; returns the pointer delta in points.
    public mutating func step(dt: Double, speed s: Speed = .normal) -> (dx: Double, dy: Double) {
        var dx = 0.0, dy = 0.0
        for (d, t) in held {
            let t1 = t + dt
            // Average of start and end speed over the interval keeps motion frame-rate independent.
            let v = (tuning.speed(after: t, s) + tuning.speed(after: t1, s)) / 2 * dt
            dx += d.vector.dx * v
            dy += d.vector.dy * v
            held[d] = t1
        }
        return (dx, dy)
    }

    private mutating func click(_ b: MouseButtonKind, count: Int = 1, modifiers: Modifiers = []) -> [MouseEffect] {
        // A left click while dragging drops instead.
        if dragging, b == .left, count == 1 {
            dragging = false
            return [.dragEnd, .update]
        }
        var fx: [MouseEffect] = []
        if dragging {
            dragging = false
            fx = [.dragEnd]
        }
        return fx + [.click(b, count: count, modifiers: modifiers)]
    }

    private static func vector(_ a: KeyInput.Arrow) -> (dx: Double, dy: Double) {
        switch a {
        case .left: (-1, 0)
        case .right: (1, 0)
        case .up: (0, -1)
        case .down: (0, 1)
        }
    }
}
