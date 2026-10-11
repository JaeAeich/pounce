import AppKit
import Combine
import PounceCore
import SwiftUI

/// Opens the app's real windows (Settings, Welcome, Cheat Sheet, Self-Test). Pounce is a menu-bar
/// agent, so it temporarily becomes a regular app while one is visible.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]

    enum Chrome {
        /// Unified toolbar with title (Settings, Cheat Sheet).
        case toolbar
        /// Title bar only, title hidden (Welcome).
        case plain
    }

    func showSettings(_ app: AppController, pane: SettingsPane = .general) {
        if let w = windows["settings"] {
            // Re-showing replaces the content so the requested pane is selected.
            (w.contentViewController as? NSHostingController<AnyView>)?.rootView = AnyView(Self.settingsView(app, pane: pane))
            activate(w)
            return
        }
        show("settings") { Self.settingsWindow(app, pane: pane) }
    }

    func showOnboarding(_ app: AppController) {
        show("onboarding") {
            Self.makeWindow(title: "Welcome to Pounce", size: CGSize(width: 560, height: 600), resizable: false, chrome: .plain) {
                OnboardingView(
                    store: app.store,
                    onDone: {
                        UserDefaults.standard.set(true, forKey: "onboarded")
                        self.windows["onboarding"]?.close()
                    }
                )
                .environmentObject(app)
            }
        }
    }

    func showCheatSheet(_ app: AppController) {
        show("cheatsheet") { Self.cheatSheetWindow(app) }
    }

    func showSelfTest(_ app: AppController) {
        let runner = SelfTest(app: app)
        windows["selftest"]?.close()
        show("selftest") {
            Self.makeWindow(title: "Pounce Self-Test", size: CGSize(width: 560, height: 560), resizable: true, chrome: .plain) {
                SelfTestView(runner: runner)
            }
        }
        runner.run()
    }

    // MARK: Window factory (also used by `pounce snapshot`)

    static func settingsView(_ app: AppController, pane: SettingsPane) -> some View {
        SettingsView(store: app.store, pane: pane).environmentObject(app)
    }

    static func settingsWindow(_ app: AppController, pane: SettingsPane) -> NSWindow {
        makeWindow(title: "Pounce Settings", size: CGSize(width: 760, height: 600), resizable: true, chrome: .toolbar) {
            settingsView(app, pane: pane)
        }
    }

    static func cheatSheetWindow(_ app: AppController) -> NSWindow {
        makeWindow(title: "Cheat Sheet", size: CGSize(width: 900, height: 680), resizable: true, chrome: .toolbar) {
            CheatSheetWindow(store: app.store).environmentObject(app)
        }
    }

    static func makeWindow<V: View>(title: String, size: CGSize, resizable: Bool, chrome: Chrome, content: () -> V) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let w: NSWindow =
            Quiet.enabled
            ? Quiet.Panel(
                contentRect: CGRect(origin: .zero, size: size), styleMask: style.union(.nonactivatingPanel), backing: .buffered,
                defer: false)
            : PounceWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        var root = AnyView(content())
        if PounceWindow.drawsAsKey {
            root = AnyView(root.environment(\.controlActiveState, .key).environment(\.appearsActive, true))
        }
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []  // the window keeps its size; content scrolls
        w.contentMinSize = CGSize(width: min(size.width, 700), height: min(size.height, 440))
        switch chrome {
        case .toolbar:
            // Lets SwiftUI's .toolbar / .searchable / .navigationTitle drive the real window toolbar.
            host.sceneBridgingOptions = [.toolbars, .title]
            w.toolbarStyle = .unified
        case .plain:
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
        }
        w.contentViewController = host
        w.setContentSize(size)
        w.center()
        return w
    }

    private func show(_ id: String, make: () -> NSWindow) {
        if let w = windows[id] {
            activate(w)
            return
        }
        let w = make()
        w.delegate = self
        w.identifier = NSUserInterfaceItemIdentifier(id)
        windows[id] = w
        activate(w)
    }

    private func activate(_ w: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, let id = w.identifier?.rawValue else { return }
        windows[id] = nil
        // Closing Welcome (red button or Esc) counts as finishing it, so it doesn't reopen every launch.
        if id == "onboarding" { UserDefaults.standard.set(true, forKey: "onboarded") }
        if windows.isEmpty {
            // Back to a pure menu-bar agent (no Dock icon).
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

/// Esc closes Pounce's windows (sheets, menus and text fields get it first).
final class PounceWindow: NSWindow {
    /// Snapshots only: draw as the key window even though a CLI process can't activate itself.
    static var drawsAsKey = false
    override var isKeyWindow: Bool { Self.drawsAsKey || super.isKeyWindow }
    override var isMainWindow: Bool { Self.drawsAsKey || super.isMainWindow }
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// The menu-bar icon and its menu.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    static let symbol = "cursorarrow.rays"
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private unowned let app: AppController
    private var cancellables: Set<AnyCancellable> = []

    init(app: AppController) {
        self.app = app
        super.init()
        UIHooks.install()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.toolTip = "Pounce"
        refreshIcon()
        // Pause can change from the CLI (`pounce pause`), the URL scheme or Settings.
        app.$paused.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshIcon() }
        }.store(in: &cancellables)
        let name = Notification.Name(pouncePausedChangedName)
        for center in [NotificationCenter.default, DistributedNotificationCenter.default()] {
            center.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshIcon() }
            }.store(in: &cancellables)
        }
    }

    func refreshIcon() {
        let name = !AX.isTrusted ? "exclamationmark.triangle" : app.paused ? "pause.circle" : Self.symbol
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Pounce")
        img?.isTemplate = true
        item.button?.image = img
        item.button?.appearsDisabled = app.paused
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshIcon()
        menu.removeAllItems()
        let shortcuts = app.store.config.shortcuts

        if !AX.isTrusted {
            let i = add(menu, "Allow Accessibility…", #selector(grant), symbol: "exclamationmark.triangle.fill")
            i.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
            i.toolTip = "Pounce can't click anything until Accessibility is allowed."
            menu.addItem(.separator())
        } else if app.paused {
            menu.addItem(.sectionHeader(title: "Pounce Is Paused"))
        } else if let owner = UIHooks.secureInputApp?() {
            // Secure Input (password fields, some terminals) blocks every global shortcut.
            let i = add(
                menu, owner.isEmpty ? "Secure Input is on. Shortcuts paused." : "Secure Input is on. Shortcuts paused by \(owner).",
                #selector(noop), symbol: "lock.fill")
            i.isEnabled = false
            i.toolTip = "macOS stops shortcuts from reaching Pounce while a password field or secure app has focus."
            menu.addItem(.separator())
        }
        if let u = UIHooks.updater, let v = u.availableVersion {
            add(menu, "Update to \(v)…", #selector(openUpdate), symbol: "arrow.down.circle")
            menu.addItem(.separator())
        }

        for m in ModeKind.allCases {
            let i = add(menu, m.title, #selector(startMode(_:)), symbol: m.symbol)
            i.representedObject = m.rawValue
            i.toolTip = m.blurb
            applyShortcut(m.shortcut(in: shortcuts), to: i)
        }
        if UIHooks.repeatLast != nil {
            let i = add(menu, "Repeat Last", #selector(repeatLast), symbol: "arrow.clockwise")
            i.toolTip = "Do the last click or scroll again."
            i.isEnabled = !app.paused
            if let kp = UIHooks.repeatShortcut { applyShortcut(shortcuts[keyPath: kp], to: i) }
        }
        menu.addItem(.separator())
        add(menu, app.paused ? "Resume" : "Pause", #selector(togglePause), symbol: app.paused ? "play" : "pause")
        add(menu, "Cheat Sheet", #selector(openCheatSheet), key: "/", symbol: "keyboard")
        add(menu, "Settings…", #selector(openSettings), key: ",", symbol: "gearshape")
        if !LoginItem.managedByLaunchd {
            add(menu, "Open at Login", #selector(toggleLogin)).state = LoginItem.isEnabled ? .on : .off
        }
        menu.addItem(.separator())
        add(menu, "Quit Pounce", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let i = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        i.target = self
        if let s = symbol { i.image = NSImage(systemSymbolName: s, accessibilityDescription: nil) }
        return i
    }

    /// Shows the global shortcut the native way (right-aligned key equivalent). Modifier taps,
    /// which menus can't express, go in the subtitle-style trailing text instead.
    private func applyShortcut(_ raw: String, to i: NSMenuItem) {
        guard let s = Shortcut.parse(raw) else { return }
        if case .chord(let c) = s, let key = Self.keyEquivalent(c.keyCode) {
            i.keyEquivalent = key
            var mask: NSEvent.ModifierFlags = []
            if c.modifiers.contains(.command) { mask.insert(.command) }
            if c.modifiers.contains(.shift) { mask.insert(.shift) }
            if c.modifiers.contains(.option) { mask.insert(.option) }
            if c.modifiers.contains(.control) { mask.insert(.control) }
            i.keyEquivalentModifierMask = mask
            // Global shortcut: shown for reference, not triggered from the open menu.
            i.allowsKeyEquivalentWhenHidden = false
        } else {
            let p = NSMutableParagraphStyle()
            p.tabStops = [NSTextTab(textAlignment: .right, location: 210)]
            let font = NSFont.menuFont(ofSize: 0)
            let t = NSMutableAttributedString(string: i.title, attributes: [.font: font, .paragraphStyle: p])
            t.append(
                NSAttributedString(
                    string: "\t" + s.display, attributes: [.font: font, .paragraphStyle: p, .foregroundColor: NSColor.secondaryLabelColor]))
            i.attributedTitle = t
        }
    }

    private static func keyEquivalent(_ code: UInt16) -> String? {
        switch code {
        case KeyCodes.space: return " "
        case KeyCodes.returnKey: return "\r"
        case KeyCodes.tab: return "\t"
        case KeyCodes.escape: return "\u{1b}"
        default:
            let n = KeyCodes.name(for: code)
            return n.count == 1 ? n.lowercased() : nil
        }
    }

    @objc private func grant() {
        Permissions.openAccessibilitySettings()
        WindowManager.shared.showOnboarding(app)
    }
    @objc private func startMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = ModeKind(rawValue: raw) else { return }
        // Wait for the menu to close and focus to return to the previous app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.app.start(m) }
    }
    @objc private func noop() {}
    @objc private func openUpdate() { UIHooks.updater?.openUpdate() }
    @objc private func repeatLast() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { UIHooks.repeatLast?(self.app) }
    }
    @objc private func togglePause() {
        app.paused.toggle()
        refreshIcon()
    }
    @objc private func openSettings() { WindowManager.shared.showSettings(app) }
    @objc private func toggleLogin() {
        do { try LoginItem.set(!LoginItem.isEnabled) } catch {
            app.overlay.model.flash("Couldn't change login item: \(error.localizedDescription)")
        }
    }
    @objc private func openCheatSheet() { WindowManager.shared.showCheatSheet(app) }
    @objc private func quit() { NSApp.terminate(nil) }
}
