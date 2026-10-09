import AppKit
import CoreGraphics
import PounceCore

/// Synthesised mouse input. Coordinates are global top-left (same as AX and CGEvent). Thread-safe.
enum Mouse {
    private static let source: CGEventSource? = {
        let s = CGEventSource(stateID: .hidSystemState)
        // Don't let our synthetic events merge with / be suppressed by the user's real input.
        s?.localEventsSuppressionInterval = 0
        return s
    }()

    private static func post(
        _ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left,
        clickState: Int64 = 0, flags: CGEventFlags = []
    ) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        if button.rawValue >= 2 { e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue)) }
        if clickState > 0 { e.setIntegerValueField(.mouseEventClickState, value: clickState) }
        if !flags.isEmpty { e.flags = flags }
        e.setIntegerValueField(.eventSourceUserData, value: EventTap.syntheticMarker)
        e.post(tap: .cghidEventTap)
    }

    static func move(to p: CGPoint) { post(.mouseMoved, p) }

    /// Mouse buttons 4 / 5 (browser back / forward). CGMouseButton numbers are zero-based.
    static let backButton = CGMouseButton(rawValue: 3)!
    static let forwardButton = CGMouseButton(rawValue: 4)!

    private static func types(_ button: CGMouseButton) -> (down: CGEventType, up: CGEventType, drag: CGEventType) {
        switch button {
        case .left: (.leftMouseDown, .leftMouseUp, .leftMouseDragged)
        case .right: (.rightMouseDown, .rightMouseUp, .rightMouseDragged)
        default: (.otherMouseDown, .otherMouseUp, .otherMouseDragged)
        }
    }

    /// Moves the pointer; while a left drag is held, as a drag so the target app sees it.
    static func move(to p: CGPoint, dragging: Bool) { post(dragging ? .leftMouseDragged : .mouseMoved, p) }

    /// Left button down / up at `p` (keyboard-cursor drags).
    static func press(at p: CGPoint) { post(.leftMouseDown, p, clickState: 1) }
    static func release(at p: CGPoint) { post(.leftMouseUp, p, clickState: 1) }

    static func click(at p: CGPoint, button: CGMouseButton = .left, count: Int = 1, flags: CGEventFlags = []) {
        let (down, up, _) = types(button)
        // Hover first so tracking areas / web content see the pointer before the press. Events are
        // delivered in order, so only a short gap is needed (was 12 ms) for apps that coalesce a
        // move and a press arriving in the same HID batch.
        let cur = location
        if abs(cur.x - p.x) > 0.5 || abs(cur.y - p.y) > 0.5 {
            move(to: p)
            usleep(1_500)
        }
        for n in 1...max(count, 1) {
            post(down, p, button, clickState: Int64(n), flags: flags)
            post(up, p, button, clickState: Int64(n), flags: flags)
        }
    }

    /// Press at `from`, glide to `to`, release — enough steps for apps that need intermediate drags.
    static func drag(from a: CGPoint, to b: CGPoint) {
        move(to: a)
        post(.leftMouseDown, a, clickState: 1)
        let steps = 24
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            usleep(8000)
        }
        post(.leftMouseUp, b, clickState: 1)
    }

    /// Pixel-precise scroll delivered at `point` without moving the cursor.
    static func scroll(dx: Double, dy: Double, at point: CGPoint?) {
        guard
            let e = CGEvent(
                scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                wheel1: Int32(-dy.rounded()), wheel2: Int32(-dx.rounded()), wheel3: 0)
        else { return }
        if let p = point { e.location = p }
        e.setIntegerValueField(.eventSourceUserData, value: EventTap.syntheticMarker)
        e.post(tap: .cghidEventTap)
    }

    static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }
}

/// Synthesised typing (click & type). Our own tap ignores these events.
enum Keyboard {
    private static let source = CGEventSource(stateID: .hidSystemState)

    /// Types `text` as Unicode key events, independent of the keyboard layout.
    static func type(_ text: String) {
        let units = Array(text.utf16)
        var i = 0
        // CGEvent carries at most 20 UTF-16 units per event.
        while i < units.count {
            var chunk = Array(units[i..<min(i + 20, units.count)])
            if chunk.count > 1, UTF16.isLeadSurrogate(chunk.last!) { chunk.removeLast() }
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e.setIntegerValueField(.eventSourceUserData, value: EventTap.syntheticMarker)
                e.post(tap: .cghidEventTap)
            }
            i += chunk.count
            usleep(2_000)
        }
    }
}

/// Performs a HintAction on a point / AX element.
enum Clicker {
    /// AX actions run here so a slow or hung app can't freeze Pounce (AXPress blocks until the
    /// target's handler returns — e.g. a button that opens a modal waits for the modal's messaging timeout).
    private static let axQueue = DispatchQueue(label: "pounce.ax-action", qos: .userInteractive)
    private static let axTimeout: Float = 1.0

    static func perform(_ action: HintAction, at p: CGPoint, element: AXUIElement?, method: ClickMethod, restoreCursor: Bool) {
        EventTap.noteClick()
        let original = Mouse.location
        let restore = restoreCursor && action != .hover
        if let el = element {
            let ax: (String, Bool)? =  // (action, set AXFocused instead)
                switch action {
                case .click where method == .accessibility: ("AXPress", false)
                case .rightClick where method == .accessibility: ("AXShowMenu", false)
                case .focus, .fill: ("AXFocused", true)
                default: nil
                }
            if let (name, isFocus) = ax {
                axQueue.async {
                    el.setTimeout(axTimeout)
                    let start = EventTap.now()
                    let err =
                        isFocus
                        ? AXUIElementSetAttributeValue(el, name as CFString, kCFBooleanTrue)
                        : AXUIElementPerformAction(el, name as CFString)
                    // Timed out: the app is busy but probably got the request — a mouse fallback would double-fire.
                    let timedOut = err == .cannotComplete && EventTap.now() &- start > UInt64(axTimeout * 0.9e9)
                    if err == .success || timedOut {
                        typeFill(action)
                        return
                    }
                    mouse(action, p)
                    if restore { restoreLater(original) }
                    typeFill(action)
                }
                return
            }
        }
        mouse(action, p)
        if restore { restoreLater(original) }
        if case .fill = action { axQueue.async { typeFill(action) } }
    }

    /// Click & type: once the field has focus, type the text (runs on axQueue, after the focus).
    private static func typeFill(_ action: HintAction) {
        guard case .fill(let text) = action, !text.isEmpty else { return }
        usleep(80_000)  // let the app move keyboard focus first
        Keyboard.type(text)
    }

    private static func mouse(_ action: HintAction, _ p: CGPoint) {
        switch action {
        case .click, .focus, .fill: Mouse.click(at: p)
        case .middleClick: Mouse.click(at: p, button: .center)
        case .back: Mouse.click(at: p, button: Mouse.backButton)
        case .forward: Mouse.click(at: p, button: Mouse.forwardButton)
        case .rightClick: Mouse.click(at: p, button: .right)
        case .commandClick: Mouse.click(at: p, flags: .maskCommand)
        case .optionClick: Mouse.click(at: p, flags: .maskAlternate)
        case .doubleClick: Mouse.click(at: p, count: 2)
        case .hover: Mouse.move(to: p)
        case .yank, .drag, .window: break  // handled by the mode
        }
    }

    private static func restoreLater(_ p: CGPoint) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Mouse.move(to: p) }
    }
}
