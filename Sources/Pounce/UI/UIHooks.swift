import AppKit
import Combine
import Foundation
import PounceCore

/// A config value shown as a picker. `get`/`set` map it onto `Config`.
struct ConfigChoice {
    struct Option: Hashable {
        let tag: String
        let title: String
        /// One line shown under the picker while this option is selected.
        var detail: String = ""
    }
    let options: [Option]
    let get: (Config) -> String
    let set: (inout Config, String) -> Void

    func detail(_ c: Config) -> String { options.first { $0.tag == get(c) }?.detail ?? "" }
}

/// Seams for features other parts of the app provide. UI that depends on a hook is hidden while
/// the hook is nil, so these screens work before (and without) the backing code.
/// TODO(merge): wire each `nil` below in `UIHooks.install()`.
@MainActor
enum UIHooks {
    // MARK: Switching from other apps

    /// Tools Pounce can mimic / import from. Tags match `preset = "…"` and `pounce import <tool>`.
    static let tools: [ConfigChoice.Option] = [
        .init(tag: "homerow", title: "Homerow", detail: "Search by name, Shift for labels, ⌘⇧Space."),
        .init(tag: "shortcat", title: "Shortcat", detail: "Search by name and press Return, ⌘⇧Space."),
        .init(tag: "vimium", title: "Vimium", detail: "Type labels directly, no search. Space clicks."),
        .init(tag: "mouseless", title: "Mouseless", detail: "Two-key grid and keyboard pointer."),
        .init(tag: "scoot", title: "Scoot", detail: "Labels and a fine grid for anywhere on screen."),
    ]

    /// TODO(merge): config agent, `[general] preset`. Expected:
    /// `ConfigChoice(options: [.init(tag: "", title: "None")] + tools, get: { $0.general.preset ?? "" }, set: { c, v in c.applyPreset(v) })`
    static var preset: ConfigChoice?

    /// TODO(merge): config agent, `pounce import <tool>`. Imports the tool's settings into the
    /// config and returns a one-line summary ("Imported 4 settings from Homerow."). Throws a
    /// readable error when the tool isn't installed.
    static var importSettings: ((_ tool: String) throws -> String)?
    /// Tools `importSettings` supports (subset of `tools`).
    static var importableTools: [String] = ["homerow", "shortcat", "vimium"]

    // MARK: Input

    /// TODO(merge): input agent. `{ raw in guard let s = Shortcut.parse(raw) else { return [] }; return Conflicts.for(s) + SystemHotkeys.conflicts(s, in: cachedSystemEntries) }`
    /// (cache `SystemHotkeys.current()` once; this runs per row on every redraw).
    /// Returns names like "VS Code (Parameter Hints)".
    static var shortcutConflicts: ((_ raw: String) -> [String])?

    /// TODO(merge): input agent. `{ SecureInput.isEnabled ? (SecureInput.holderName ?? "") : nil }`. Polled once a second.
    /// Returns nil when Secure Input is off, "" when on but the app is unknown.
    static var secureInputApp: (() -> String?)?

    // MARK: Modes

    /// TODO(merge): modes agent, `hints.after_click` (exit | stay | scroll). Until then this maps
    /// exit/stay onto `click_chain`.
    static var afterClick: ConfigChoice = ConfigChoice(
        options: [
            .init(tag: "exit", title: "Close", detail: "Pounce closes after each click."),
            .init(tag: "stay", title: "Stay open", detail: "Click several things in a row. Press Esc when done."),
        ],
        get: { $0.hints.clickChain ? "stay" : "exit" },
        set: { c, v in c.hints.clickChain = v == "stay" })
    static let afterClickScroll = ConfigChoice.Option(tag: "scroll", title: "Switch to Scroll", detail: "Scroll the area you just clicked.")

    /// TODO(merge): modes agent, `grid.style`. Options e.g. "nine" (3×3 zoom) / "two_key" (type column, then row).
    static var gridStyle: ConfigChoice?

    /// TODO(merge): modes agent, `\.repeat` (shortcuts.repeat).
    static var repeatShortcut: WritableKeyPath<Config.Shortcuts, String>?
    /// TODO(merge): modes agent, `{ app in app.repeatLast() }`.
    static var repeatLast: ((AppController) -> Void)?

    // MARK: Windows

    /// TODO(merge): windows agent, `hints.scope` (window | screen | all).
    static var hintScope: ConfigChoice?
    static let scopeOptions: [ConfigChoice.Option] = [
        .init(tag: "window", title: "Front window", detail: "Fastest."),
        .init(tag: "screen", title: "Every window on this screen"),
        .init(tag: "all", title: "Every window on every screen", detail: "Slowest in busy setups."),
    ]

    // MARK: Updates

    /// TODO(merge): dist agent, `Updater.shared`.
    static var updater: UpdateChecking?

    /// Third-party conflicts only matter if that app is installed; macOS ones always do.
    private static let conflictApps: [(prefix: String, bundles: [String])] = [
        ("VS Code", ["com.microsoft.VSCode", "com.todesktop.230313mxl4gc48ra"]),
        ("1Password", ["com.1password.1password", "com.agilebits.onepassword7"]),
        ("Chrome", ["com.google.Chrome"]), ("Firefox", ["org.mozilla.firefox"]),
        ("ChatGPT", ["com.openai.chat"]), ("Raycast", ["com.raycast.macos"]),
        ("Rectangle", ["com.knollsoft.Rectangle", "com.crowdcafe.windowmagnet"]),
        ("Browser developer tools", ["com.google.Chrome", "org.mozilla.firefox", "com.brave.Browser", "com.microsoft.edgemac"]),
    ]
    private static var installedCache: [String: Bool] = [:]
    private static func installedOrSystem(_ who: String) -> Bool {
        if who.contains("(macOS)") { return true }
        if who.contains("(some setups)") { return false }
        guard let entry = conflictApps.first(where: { who.hasPrefix($0.prefix) }) else { return true }
        if let c = installedCache[who] { return c }
        let ok = entry.bundles.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        installedCache[who] = ok
        return ok
    }

    /// Called once at launch: wires the hooks to the features behind them.
    static func install() {
        var system: [SystemHotkeys.Entry]?
        shortcutConflicts = { raw in
            guard let s = Shortcut.parse(raw) else { return [] }
            if system == nil { system = SystemHotkeys.current() }
            return Conflicts.for(s).filter(installedOrSystem) + SystemHotkeys.conflicts(s, in: system)
        }
        secureInputApp = { SecureInput.isEnabled ? (SecureInput.holderName ?? "") : nil }
        hintScope = ConfigChoice(
            options: scopeOptions, get: { $0.hints.scope.rawValue },
            set: { c, v in c.hints.scope = HintScopeKind(rawValue: v) ?? .window })
        preset = ConfigChoice(
            options: tools.filter { Preset(rawValue: $0.tag) != nil },
            get: { $0.general.preset.rawValue },
            set: { c, v in if let p = Preset(rawValue: v) { c = c.withPreset(p) } })
        importableTools = ImportSource.allCases.map(\.rawValue)
        importSettings = { tool in try ImportFlow.run(tool) }
        if Updater.shared.disabledReason == nil { updater = UpdaterBridge.shared }
        afterClick = ConfigChoice(
            options: afterClick.options + [afterClickScroll], get: { $0.hints.afterClick.rawValue },
            set: { c, v in c.hints.afterClick = AfterClick(rawValue: v) ?? .exit })
        gridStyle = ConfigChoice(
            options: [
                .init(tag: "recursive", title: "Zoom in 3×3", detail: "Each key zooms into a ninth of the area."),
                .init(tag: "twokey", title: "Two-letter cells", detail: "Type a cell's two letters, then zoom if needed."),
            ],
            get: { $0.grid.style.rawValue }, set: { c, v in c.grid.style = GridStyle(rawValue: v) ?? .recursive })
        repeatShortcut = \.repeat
        repeatLast = { $0.repeatLast() }
    }
}

/// What the UI needs from the updater. Post `Notification.Name.pounceUpdateStatus` when
/// `availableVersion` or `isChecking` changes.
@MainActor
protocol UpdateChecking: AnyObject {
    var automaticallyChecks: Bool { get set }
    var isChecking: Bool { get }
    /// Newer version found by the last check, e.g. "1.3".
    var availableVersion: String? { get }
    var lastChecked: Date? { get }
    func check(manual: Bool)
    /// Opens the release / download page for `availableVersion`.
    func openUpdate()
}

extension Notification.Name {
    /// Posted by the updater when its state changes.
    static let pounceUpdateStatus = Notification.Name("PounceUpdateStatusChanged")
}

/// Same string the config agent posts when `paused` changes (also from `pounce pause`).
let pouncePausedChangedName = "PouncePausedChanged"

/// Adapts `Updater` to what the Settings / menu UI expects.
@MainActor
final class UpdaterBridge: UpdateChecking {
    static let shared = UpdaterBridge()
    private var sub: AnyCancellable?

    private init() {
        sub = Updater.shared.objectWillChange.sink { _ in
            DispatchQueue.main.async { NotificationCenter.default.post(name: .pounceUpdateStatus, object: nil) }
        }
    }

    var automaticallyChecks: Bool {
        get { Updater.shared.automaticChecks }
        set { Updater.shared.automaticChecks = newValue }
    }
    var isChecking: Bool { Updater.shared.checking }
    var availableVersion: String? { Updater.shared.available?.version }
    var lastChecked: Date? { Updater.shared.lastCheck }
    func check(manual: Bool) { Task { _ = await Updater.shared.check(manual: manual) } }
    func openUpdate() { if let i = Updater.shared.available { Updater.shared.open(i, download: true) } }
}
