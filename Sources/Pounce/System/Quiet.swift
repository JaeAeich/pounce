import AppKit

/// Quiet mode for `pounce selftest | snapshot | bench`: nothing appears on screen, nothing takes
/// focus, and tiling window managers (AeroSpace, yabai) leave the windows alone.
/// - Windows are non-activating panels (window managers don't manage panels, and they never activate the app).
/// - Fixtures that are only read through Accessibility are fully transparent: AX doesn't care about alpha.
/// - Windows that are captured as images (snapshots, overlay pixel checks) sit far off-screen:
///   the window server still composites them, so `CGWindowListCreateImage` works.
enum Quiet {
    nonisolated(unsafe) static var enabled =
        ProcessInfo.processInfo.environment["POUNCE_LOUD"] == nil
        && ["selftest", "snapshot", "bench"].contains(CommandLine.arguments.dropFirst().first ?? "")

    /// Where captured windows go: well outside every screen.
    static let offscreen = CGPoint(x: -40_000, y: -40_000)

    /// A panel that behaves like `PounceWindow` (Esc closes, can draw as key for snapshots).
    final class Panel: NSPanel {
        override var isKeyWindow: Bool { PounceWindow.drawsAsKey || super.isKeyWindow }
        override var isMainWindow: Bool { PounceWindow.drawsAsKey || super.isMainWindow }
        override var canBecomeMain: Bool { true }
        override func cancelOperation(_ sender: Any?) { performClose(sender) }
    }

    /// A window for tests: a regular window normally, an invisible non-activating panel when quiet.
    @MainActor
    static func window(contentRect: CGRect, styleMask: NSWindow.StyleMask) -> NSWindow {
        guard enabled else { return NSWindow(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false) }
        let p = Panel(contentRect: contentRect, styleMask: styleMask.union(.nonactivatingPanel), backing: .buffered, defer: false)
        p.hidesOnDeactivate = false
        p.alphaValue = 0
        p.ignoresMouseEvents = true
        p.animationBehavior = .none
        return p
    }

    /// Brings a test window forward without activating Pounce when quiet.
    @MainActor
    static func show(_ w: NSWindow) {
        if enabled { w.orderFrontRegardless() } else { w.makeKeyAndOrderFront(nil) }
    }
}
