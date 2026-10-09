import AppKit
import ApplicationServices

/// AXObserver on one application, delivering notification names on the main run loop.
@MainActor
final class AppObserver {
    let pid: pid_t
    private var observer: AXObserver?
    private let app: AXUIElement
    private let box: Box

    /// Retained by the C callback via refcon.
    private final class Box {
        let handler: (String) -> Void
        init(_ h: @escaping (String) -> Void) { handler = h }
    }

    /// Structural changes: cached frames may be wrong, don't show them.
    static let hard: Set<String> = [
        kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowResizedNotification,
        kAXWindowCreatedNotification, kAXWindowMiniaturizedNotification, kAXSheetCreatedNotification,
        kAXDrawerCreatedNotification, kAXMenuOpenedNotification, kAXMenuClosedNotification, "AXLoadComplete",
    ]
    /// Content changes: cache is still worth showing, but rescan.
    static let soft: Set<String> = [
        kAXCreatedNotification, kAXUIElementDestroyedNotification, kAXValueChangedNotification,
        kAXTitleChangedNotification, kAXLayoutChangedNotification, kAXSelectedChildrenChangedNotification,
        kAXSelectedRowsChangedNotification, kAXRowCountChangedNotification, kAXFocusedUIElementChangedNotification,
        kAXRowExpandedNotification, kAXRowCollapsedNotification, kAXElementBusyChangedNotification,
    ]
    /// Window moved: frames shift by a delta, no rescan needed.
    static let moved: Set<String> = [kAXWindowMovedNotification]

    init?(pid: pid_t, handler: @escaping (String) -> Void) {
        self.pid = pid
        app = AXUIElement.app(pid)
        app.setTimeout(0.25)
        box = Box(handler)
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, name, refcon in
            guard let refcon else { return }
            let b = Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue()
            let n = name as String
            MainActor.assumeIsolated { b.handler(n) }
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return nil }
        observer = obs
        let ref = Unmanaged.passUnretained(box).toOpaque()
        var any = false
        for n in Self.hard.union(Self.soft).union(Self.moved) {
            if AXObserverAddNotification(obs, app, n as CFString, ref) == .success { any = true }
        }
        guard any else {
            observer = nil
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
    }

    func invalidate() {
        guard let obs = observer else { return }
        for n in Self.hard.union(Self.soft).union(Self.moved) {
            AXObserverRemoveNotification(obs, app, n as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = nil
    }
}
