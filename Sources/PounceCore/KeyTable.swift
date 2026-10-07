/// O(1) lookup of global shortcuts by (keyCode, modifiers) or modifier key. First binding wins.
public struct ShortcutTable<Value> {
    private var chords: [UInt32: Value] = [:]
    private var taps: [ModifierKey: Value] = [:]
    private var doubleTaps: [ModifierKey: Value] = [:]

    public init() {}

    public init(_ bindings: [(Shortcut, Value)]) {
        for (s, v) in bindings {
            switch s {
            case .chord(let c): if chords[Self.key(c.keyCode, c.modifiers)] == nil { chords[Self.key(c.keyCode, c.modifiers)] = v }
            case .tap(let k): if taps[k] == nil { taps[k] = v }
            case .doubleTap(let k): if doubleTaps[k] == nil { doubleTaps[k] = v }
            }
        }
    }

    @inline(__always) static func key(_ code: UInt16, _ m: Modifiers) -> UInt32 { UInt32(code) << 8 | UInt32(m.rawValue) }

    public func chord(keyCode: UInt16, modifiers: Modifiers) -> Value? {
        chords.isEmpty ? nil : chords[Self.key(keyCode, modifiers)]
    }
    public func tap(_ k: ModifierKey) -> Value? { taps[k] }
    public func doubleTap(_ k: ModifierKey) -> Value? { doubleTaps[k] }
    public var hasModifierTriggers: Bool { !taps.isEmpty || !doubleTaps.isEmpty }
}

/// Recognises lone-modifier taps and double-taps from a stream of key / flags-changed events.
/// Times are monotonic nanoseconds (caller supplies them, so this is deterministic and testable).
public struct ModifierTapTracker {
    public var tapWindow: UInt64 = 350_000_000
    public var doubleTapWindow: UInt64 = 400_000_000
    private var down: (key: ModifierKey, at: UInt64, clean: Bool)?
    private var lastTap: (key: ModifierKey, at: UInt64)?

    public init() {}

    /// Any non-modifier key press makes a held modifier a chord, not a tap.
    public mutating func keyDown() { down?.clean = false }

    /// A modifier changed state. `alone`: no other modifier was held when it went down.
    /// Returns `.tap(k)` / `.doubleTap(k)` when the release completes one. A completed single tap is
    /// reported as `.tap` only if `hasTap(k)`; otherwise it is remembered as the first half of a double-tap.
    public mutating func modifier(
        _ key: ModifierKey, pressed: Bool, alone: Bool, at now: UInt64,
        hasTap: (ModifierKey) -> Bool
    ) -> Shortcut? {
        if pressed {
            down = (key, now, alone)
            return nil
        }
        defer { down = nil }
        guard let d = down, d.key == key, d.clean, now &- d.at < tapWindow else {
            lastTap = nil
            return nil
        }
        if hasTap(key) { return .tap(key) }
        if let last = lastTap, last.key == key, now &- last.at < doubleTapWindow {
            lastTap = nil
            return .doubleTap(key)
        }
        lastTap = (key, now)
        return nil
    }
}
extension ShortcutTable: Sendable where Value: Sendable {}
