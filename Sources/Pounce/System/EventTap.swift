import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics
import PounceCore
import os

/// A keyboard event seen by the global tap.
struct KeyEvent {
    enum Kind { case down, up, flags }
    let kind: Kind
    let keyCode: UInt16
    let modifiers: Modifiers
    let characters: String?
    let charactersIgnoringModifiers: String?
    let isRepeat: Bool
    let cgEvent: CGEvent
    /// Hyper + shortcut match, precomputed once on the tap thread (nil for injected events).
    var routed: Routed? = nil

    struct Routed {
        var hyperSwallow: Bool
        var modifiers: Modifiers
        var match: ModeKind?
    }

    /// Translates to mode input (hint-search policy). nil for keys modes don't understand (e.g. ⌘-chords).
    var input: KeyInput? { input(for: .search) }

    /// Translates to mode input. Case follows Shift, not Caps Lock; on non-Latin layouts letters are
    /// translated through the ASCII-capable layout per `purpose` (see `KeyText`).
    func input(for purpose: KeyText.Purpose) -> KeyInput? {
        switch keyCode {
        case KeyCodes.escape: return .escape
        case KeyCodes.returnKey, KeyCodes.keypadEnter: return .returnKey(modifiers)
        // ⌘Tab / ⌘⇧Tab is the app switcher: never a mode key.
        case KeyCodes.tab: return modifiers.contains(.command) ? nil : .tab(backward: modifiers.contains(.shift))
        case KeyCodes.space: return .space(modifiers)
        case KeyCodes.delete: return .backspace
        case KeyCodes.left: return .arrow(.left, modifiers)
        case KeyCodes.right: return .arrow(.right, modifiers)
        case KeyCodes.up: return .arrow(.up, modifiers)
        case KeyCodes.down: return .arrow(.down, modifiers)
        default: break
        }
        if modifiers.contains(.command) { return nil }
        if modifiers.contains(.control) {
            guard let c = charactersIgnoringModifiers?.lowercased().first, c.isLetter else { return nil }
            return .control(resolve(c, shift: false, capsLock: false, purpose: .labels))
        }
        // Option produces dead keys / symbols; use the base character instead.
        let chars = modifiers.contains(.option) ? charactersIgnoringModifiers : characters
        guard let c = chars?.first, !c.isNewline, c.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return nil }
        let shift = modifiers.contains(.shift)
        return .char(resolve(c, shift: shift, capsLock: cgEvent.flags.contains(.maskAlphaShift), purpose: purpose))
    }

    private func resolve(_ c: Character, shift: Bool, capsLock: Bool, purpose: KeyText.Purpose) -> Character {
        let ascii =
            purpose != .literal && KeyText.needsTranslation(c)
            ? KeyboardLayout.shared.asciiCharacter(keyCode: keyCode, shift: shift) : nil
        return KeyText.resolve(actual: c, ascii: ascii, shift: shift, capsLock: capsLock, purpose: purpose)
    }
}

/// Session-level CGEventTap for key events, serviced on a dedicated high-priority thread so main-thread
/// work (AX, rendering) never delays or drops system-wide typing.
///
/// Routing: the tap thread runs Hyper + shortcut matching itself (`HotkeyMatcher.route`). While no mode
/// is active, ordinary keys are passed straight through without touching the main thread. Everything
/// else (mode keys, matched shortcuts) is handed to `handler` on main; the tap waits briefly for its
/// swallow decision and, if main is busy, falls back to a predicted decision instead of stalling input.
final class EventTap: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    /// Main-actor handler; returns true to swallow the event.
    var handler: ((KeyEvent) -> Bool)?

    private struct Gate {
        var attached = false
        var modeActive = false
        var pendingMain = 0
    }
    private let gate = OSAllocatedUnfairLock(initialState: Gate())
    private var matcher: HotkeyMatcher?
    private var modeSub: AnyCancellable?

    /// How long the tap waits for main before using its predicted decision.
    static let mainTimeout: DispatchTimeInterval = .milliseconds(150)

    var isInstalled: Bool { tap != nil }

    /// Lets the tap thread route events itself. Call once from main (AppController.init).
    func attach(_ matcher: HotkeyMatcher, activeMode: Published<ModeKind?>.Publisher) {
        self.matcher = matcher
        modeSub = activeMode.sink { [gate] m in gate.withLockUnchecked { $0.modeActive = m != nil } }
        gate.withLockUnchecked { $0.attached = true }
    }

    func install() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard
            let t = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, type, event, ref in
                    let me = Unmanaged<EventTap>.fromOpaque(ref!).takeUnretainedValue()
                    return me.handle(type: type, event: event)
                }, userInfo: ref)
        else { return false }
        KeyboardLayout.shared.start()
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        tap = t
        source = src
        let ready = DispatchSemaphore(value: 0)
        let th = Thread { [weak self] in
            let rl = CFRunLoopGetCurrent()
            self?.runLoop = rl
            CFRunLoopAddSource(rl, src, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        th.name = "pounce.event-tap"
        th.qualityOfService = .userInteractive
        th.stackSize = 1 << 18
        thread = th
        th.start()
        ready.wait()
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func uninstall() {
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            CFMachPortInvalidate(t)
        }
        if let rl = runLoop {
            if let s = source { CFRunLoopRemoveSource(rl, s, .commonModes) }
            CFRunLoopStop(rl)
        }
        tap = nil
        source = nil
        runLoop = nil
        thread = nil
    }

    // MARK: - Tap thread

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return pass
        }
        // Ignore events we synthesised ourselves.
        if event.getIntegerValueField(.eventSourceUserData) == EventTap.syntheticMarker { return pass }
        let kind: KeyEvent.Kind =
            switch type {
            case .keyDown: .down
            case .keyUp: .up
            default: .flags
            }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let isRepeat = kind == .down && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        var e = KeyEvent(
            kind: kind, keyCode: keyCode, modifiers: Self.modifiers(flags), characters: nil,
            charactersIgnoringModifiers: nil, isRepeat: isRepeat, cgEvent: event)

        let g = gate.withLockUnchecked { $0 }
        guard g.attached, let matcher else {
            // Not wired up: main decides everything.
            return dispatch(withCharacters(e), predicted: false) ? nil : pass
        }
        let r = matcher.route(e)
        e.routed = r
        if r.match != nil { log.debug("tap matched shortcut \(keyCode) modeActive \(g.modeActive)") }
        if r.hyperSwallow { return nil }

        let predicted: Bool
        if g.modeActive {
            // Mirrors AppController.handle: shortcuts and mode keys are swallowed; modifiers and ⌘-chords pass.
            if r.match != nil {
                predicted = true
            } else {
                switch kind {
                case .flags: predicted = false
                case .up: predicted = true
                case .down:
                    e = withCharacters(e)
                    predicted = !(e.input == nil && r.modifiers.contains(.command))
                }
            }
            if kind == .flags && r.match == nil { return pass }  // main ignores these during a mode
        } else if r.match != nil {
            predicted = true
        } else {
            return pass  // the common case: plain typing, never touches main
        }
        if e.characters == nil && kind != .flags { e = withCharacters(e) }
        return dispatch(e, predicted: predicted) ? nil : pass
    }

    private func withCharacters(_ e: KeyEvent) -> KeyEvent {
        guard e.kind != .flags, e.characters == nil else { return e }
        let (chars, ignoring) = KeyboardLayout.shared.characters(e.cgEvent, keyCode: e.keyCode, shift: e.modifiers.contains(.shift))
        var out = KeyEvent(
            kind: e.kind, keyCode: e.keyCode, modifiers: e.modifiers, characters: chars,
            charactersIgnoringModifiers: ignoring, isRepeat: e.isRepeat, cgEvent: e.cgEvent)
        out.routed = e.routed
        return out
    }

    /// Runs `handler` on main and returns its decision, or `predicted` if main doesn't answer in time
    /// (the handler still runs later, in order).
    private func dispatch(_ e: KeyEvent, predicted: Bool) -> Bool {
        let busy = gate.withLockUnchecked { g -> Bool in
            g.pendingMain += 1
            return g.pendingMain > 1
        }
        let box = ResultBox(predicted)
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { [self] in
            let r = MainActor.assumeIsolated { handler?(e) ?? false }
            gate.withLockUnchecked { $0.pendingMain -= 1 }
            box.value.withLockUnchecked { $0 = r }
            sem.signal()
        }
        // Main is still working through earlier events: don't stack waits on top of it.
        if busy { return predicted }
        if sem.wait(timeout: .now() + Self.mainTimeout) == .timedOut { return predicted }
        return box.value.withLockUnchecked { $0 }
    }

    private final class ResultBox: @unchecked Sendable {
        let value: OSAllocatedUnfairLock<Bool>
        init(_ v: Bool) { value = OSAllocatedUnfairLock(initialState: v) }
    }

    // MARK: - Shared helpers

    static let syntheticMarker: Int64 = 0x506F_756E  // "Poun"

    /// Monotonic nanoseconds.
    @inline(__always) static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// Kept for callers; out-of-mode keys are never hijacked after a click (Return passes through untouched).
    static func noteClick() {}

    static func modifiers(_ f: CGEventFlags) -> Modifiers {
        var m: Modifiers = []
        if f.contains(.maskCommand) { m.insert(.command) }
        if f.contains(.maskShift) { m.insert(.shift) }
        if f.contains(.maskAlternate) { m.insert(.option) }
        if f.contains(.maskControl) { m.insert(.control) }
        return m
    }

    static func flags(_ m: Modifiers) -> CGEventFlags {
        var f: CGEventFlags = []
        if m.contains(.command) { f.insert(.maskCommand) }
        if m.contains(.shift) { f.insert(.maskShift) }
        if m.contains(.option) { f.insert(.maskAlternate) }
        if m.contains(.control) { f.insert(.maskControl) }
        return f
    }

    private static let keySource = CGEventSource(stateID: .hidSystemState)

    /// Posts a key press that our own tap ignores. Thread-safe.
    static func postKey(_ code: UInt16, flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: keySource, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            e.post(tap: .cghidEventTap)
        }
    }
}

/// Character translation without NSEvent: the event's own Unicode string, plus UCKeyTranslate against a
/// cached keyboard layout for "ignoring modifiers". TIS must be queried on main, so the layouts are
/// captured there and refreshed when the input source changes; translation itself runs on any thread.
/// Also caches the ASCII-capable layout (`TISCopyCurrentASCIICapableKeyboardLayoutInputSource`: the user's
/// last Latin layout, e.g. US or Dvorak) so non-Latin layouts can still type labels by physical key.
final class KeyboardLayout: @unchecked Sendable {
    static let shared = KeyboardLayout()
    private struct Layouts {
        var current: CFData?
        var ascii: CFData?
        var kbdType: UInt32 = 0
        var loaded = false
    }
    private let layouts = OSAllocatedUnfairLock<Layouts>(initialState: Layouts())
    private var observing = false

    /// Call on main.
    func start() {
        guard !observing else { return }
        observing = true
        refresh()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        func data(_ src: TISInputSource?) -> CFData? {
            guard let src, let p = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            return Unmanaged<CFData>.fromOpaque(p).takeUnretainedValue()
        }
        let ascii = data(TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue())
        let d = data(TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()) ?? ascii
        let kt = UInt32(LMGetKbdType())
        layouts.withLockUnchecked { $0 = Layouts(current: d, ascii: ascii, kbdType: kt, loaded: true) }
    }

    /// (characters, charactersIgnoringModifiers) — the latter keeps Shift, like NSEvent.
    func characters(_ e: CGEvent, keyCode: UInt16, shift: Bool) -> (String?, String?) {
        var buf = (UInt16(0), UInt16(0), UInt16(0), UInt16(0), UInt16(0), UInt16(0), UInt16(0), UInt16(0))
        let chars: String? = withUnsafeMutableBytes(of: &buf) { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: UniChar.self)
            var n = 0
            e.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &n, unicodeString: p)
            return String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF16.self)
        }
        let ignoring = layouts.withLockUnchecked { l in Self.translate(l.current, l.kbdType, keyCode, shift: shift) }
        return (chars, ignoring ?? chars)
    }

    /// The character this physical key makes on the ASCII-capable layout (Shift only, no Caps Lock).
    /// Loads the layouts on first use from main if the tap hasn't started (self-test).
    func asciiCharacter(keyCode: UInt16, shift: Bool) -> Character? {
        if !layouts.withLockUnchecked({ $0.loaded }), Thread.isMainThread { refresh() }
        let s = layouts.withLockUnchecked { l in Self.translate(l.ascii, l.kbdType, keyCode, shift: shift) }
        return s?.count == 1 ? s?.first : nil
    }

    private static func translate(_ d: CFData?, _ kbdType: UInt32, _ keyCode: UInt16, shift: Bool) -> String? {
        guard let d, let bytes = CFDataGetBytePtr(d) else { return nil }
        let modState: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
        var buf = (UInt16(0), UInt16(0), UInt16(0), UInt16(0), UInt16(0), UInt16(0), UInt16(0), UInt16(0))
        return withUnsafeMutableBytes(of: &buf) { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: UniChar.self)
            var dead: UInt32 = 0
            var n = 0
            let s = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { kl in
                UCKeyTranslate(
                    kl, keyCode, UInt16(kUCKeyActionDown), modState, kbdType,
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 8, &n, p)
            }
            return s == noErr ? String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF16.self) : nil
        }
    }
}
