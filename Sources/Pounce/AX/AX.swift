import AppKit
import ApplicationServices
import PounceCore

/// Thin, typed helpers over the AXUIElement C API.
extension AXUIElement {
    static func app(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }
    static let systemWide = AXUIElementCreateSystemWide()

    func value(_ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, attr as CFString, &v) == .success ? v : nil
    }

    func string(_ attr: String) -> String? { value(attr) as? String }
    func bool(_ attr: String) -> Bool? { (value(attr) as? NSNumber)?.boolValue }
    func element(_ attr: String) -> AXUIElement? {
        guard let v = value(attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    func elements(_ attr: String) -> [AXUIElement] { (value(attr) as? [AXUIElement]) ?? [] }

    /// Fetches several attributes in one IPC round trip. Missing attributes come back nil.
    func values(_ attrs: [String]) -> [CFTypeRef?] {
        var out: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(self, attrs as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out)
        guard err == .success, let arr = out as? [AnyObject], arr.count == attrs.count else {
            return Array(repeating: nil, count: attrs.count)
        }
        return arr.map { v in
            // Per-attribute failures are returned as AXValue(.axError).
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
            return v
        }
    }

    @discardableResult
    func set(_ attr: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, attr as CFString, value) == .success
    }

    var actions: [String] {
        var names: CFArray?
        return AXUIElementCopyActionNames(self, &names) == .success ? (names as? [String]) ?? [] : []
    }

    @discardableResult
    func perform(_ action: String) -> Bool { AXUIElementPerformAction(self, action as CFString) == .success }

    var pid: pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(self, &p)
        return p
    }

    var frame: Rect? { AX.frame(position: value("AXPosition"), size: value("AXSize")) }

    /// Frame via AXFrame (one cheap attribute), falling back to AXPosition + AXSize.
    var fastFrame: Rect? {
        if let r = AX.rect(value("AXFrame")) { return r }
        return frame
    }

    func setTimeout(_ seconds: Float) { AXUIElementSetMessagingTimeout(self, seconds) }

    func setFrame(_ r: Rect) {
        var p = CGPoint(x: r.x, y: r.y)
        var s = CGSize(width: r.width, height: r.height)
        // Size, position, size: works around apps that clamp size to the old screen.
        if let sv = AXValueCreate(.cgSize, &s) { set("AXSize", sv) }
        if let pv = AXValueCreate(.cgPoint, &p) { set("AXPosition", pv) }
        if let sv = AXValueCreate(.cgSize, &s) { set("AXSize", sv) }
    }
}

enum AX {
    static func frame(position: CFTypeRef?, size: CFTypeRef?) -> Rect? {
        guard let p = position, let s = size,
            CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
        else { return nil }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return Rect(x: pt.x, y: pt.y, width: sz.width, height: sz.height)
    }

    /// Parses an AXFrame value (CGRect, global top-left coordinates).
    static func rect(_ v: CFTypeRef?) -> Rect? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &r) else { return nil }
        return Rect(x: r.origin.x, y: r.origin.y, width: r.width, height: r.height)
    }

    static func string(_ v: CFTypeRef?) -> String? {
        if let s = v as? String { return s }
        if let u = v as? URL { return u.absoluteString }
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
        return nil
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        // Literal of kAXTrustedCheckOptionPrompt; the global is not concurrency-safe in Swift 6.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

/// Global top-left screen geometry helpers bridging AppKit (bottom-left) and AX (top-left).
enum Screens {
    static var primaryHeight: Double { Double(NSScreen.screens.first?.frame.height ?? 0) }

    static func topLeft(_ s: NSScreen) -> Rect { topLeft(cocoa: s.frame) }
    static func topLeftVisible(_ s: NSScreen) -> Rect { topLeft(cocoa: s.visibleFrame) }

    static func topLeft(cocoa f: CGRect) -> Rect {
        Geometry.topLeftFrame(
            ofCocoa: Rect(x: f.minX, y: f.minY, width: f.width, height: f.height), primaryHeight: primaryHeight)
    }

    /// Screen containing the point (global top-left), else main.
    static func screen(containing x: Double, _ y: Double) -> NSScreen {
        NSScreen.screens.first { topLeft($0).contains(x: x, y: y) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func screen(for r: Rect) -> NSScreen {
        NSScreen.screens.max { topLeft($0).intersection(r).area < topLeft($1).intersection(r).area }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Mouse location in global top-left coordinates.
    static var mouse: Point {
        let m = NSEvent.mouseLocation
        return Point(x: m.x, y: primaryHeight - m.y)
    }

    static var union: Rect {
        NSScreen.screens.map(topLeft).reduce(Rect.zero) { acc, r in
            acc.isEmpty
                ? r
                : Rect(
                    x: min(acc.x, r.x), y: min(acc.y, r.y),
                    width: max(acc.maxX, r.maxX) - min(acc.x, r.x),
                    height: max(acc.maxY, r.maxY) - min(acc.y, r.y))
        }
    }
}

extension Rect {
    var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension Point {
    var cg: CGPoint { CGPoint(x: x, y: y) }
}
