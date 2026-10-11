import AppKit
import PounceCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, shortcuts, hints, scrolling, apps, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .hints: "Click"
        case .scrolling: "Scroll & Grid"
        case .apps: "Apps"
        case .about: "About"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "command"
        case .hints: "cursorarrow.click.2"
        case .scrolling: "arrow.up.and.down"
        case .apps: "app.badge.checkmark"
        case .about: "info.circle"
        }
    }
    /// Extra words the sidebar search matches.
    var keywords: String {
        switch self {
        case .general:
            "permission accessibility screen recording login startup launch sound pause preset homerow shortcat vimium mouseless scoot import update secure input"
        case .shortcuts: "hotkey keyboard shortcut record hyper caps lock escape mode conflict repeat mouse"
        case .hints:
            "label hint theme dark light vimium size alphabet letters characters auto click chain after stay search pointer cursor menu bar dock scan preview scope screen windows"
        case .scrolling: "scroll speed fast hjkl vim dvorak colemak grid two-key style"
        case .apps: "ignore exclude game per-app override"
        case .about: "version config file toml reset defaults self-test diagnostics welcome nix"
        }
    }

    var resettable: Bool { [.general, .shortcuts, .hints, .scrolling].contains(self) }

    @MainActor func isDefault(_ c: Config) -> Bool {
        let d = Config()
        switch self {
        case .general: return c.general.sounds == d.general.sounds
        case .shortcuts:
            return c.shortcuts == d.shortcuts && c.general.hyperKey == d.general.hyperKey
                && c.general.capsLockEscape == d.general.capsLockEscape
        case .hints: return c.hints == d.hints
        case .scrolling: return c.scroll == d.scroll && c.grid == d.grid
        default: return true
        }
    }

    @MainActor func reset(_ c: inout Config) {
        let d = Config()
        switch self {
        case .general: c.general.sounds = d.general.sounds
        case .shortcuts:
            c.shortcuts = d.shortcuts
            c.general.hyperKey = d.general.hyperKey
            c.general.capsLockEscape = d.general.capsLockEscape
        case .hints: c.hints = d.hints
        case .scrolling:
            c.scroll = d.scroll
            c.grid = d.grid
        default: break
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppController
    @ObservedObject var store: ConfigStore
    @State private var selection: SettingsPane?
    @State private var search = ""

    init(store: ConfigStore, pane: SettingsPane = .general) {
        self.store = store
        _selection = State(initialValue: pane)
    }

    private var panes: [SettingsPane] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return SettingsPane.allCases }
        return SettingsPane.allCases.filter { ($0.title + " " + $0.keywords).lowercased().contains(q) }
    }

    var body: some View {
        NavigationSplitView {
            List(panes, selection: $selection) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .toolbar(removing: .sidebarToggle)
            .searchable(text: $search, placement: .sidebar, prompt: "Search")
            .onChange(of: search) { _, _ in
                if let s = selection, panes.contains(s) { return }
                selection = panes.first
            }
        } detail: {
            let pane = selection ?? .general
            PaneForm(store: store, pane: pane) { content(pane) }
                .navigationTitle(pane.title)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            WindowManager.shared.showCheatSheet(app)
                        } label: {
                            Label("Cheat Sheet", systemImage: "keyboard")
                        }
                        .help("Show every Pounce key")
                    }
                }
        }
        .frame(minWidth: 700, minHeight: 480)
    }

    @ViewBuilder private func content(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralPane(store: store)
        case .shortcuts: ShortcutsPane(store: store)
        case .hints: HintsPane(store: store)
        case .scrolling: ScrollPane(store: store)
        case .apps: AppsPane(store: store)
        case .about: AboutPane(store: store)
        }
    }
}

/// A grouped Form with the shared bits: config notices on top, Restore Defaults at the bottom,
/// and read-only when the config is managed by Nix.
struct PaneForm<Content: View>: View {
    @ObservedObject var store: ConfigStore
    let pane: SettingsPane
    @ViewBuilder var content: Content
    @State private var confirm = false

    var body: some View {
        Form {
            if store.isManaged {
                Section {
                    Label("These settings are managed by Nix and can't be changed here.", systemImage: "lock.fill")
                } footer: {
                    Text("Edit services.pounce.settings in your nix-darwin or home-manager configuration.")
                }
            }
            if store.error != nil || !store.warnings.isEmpty {
                Section {
                    if let e = store.error {
                        LabeledContent {
                            Button("Open File") { store.openInEditor() }
                        } label: {
                            Label {
                                Text(e)
                            } icon: {
                                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                            }
                        }
                    }
                    ForEach(store.warnings, id: \.self) { w in
                        Label {
                            Text(w)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
            }
            Group { content }
                .disabled(store.isManaged && pane != .about)
            if pane.resettable {
                Section {
                } footer: {
                    HStack {
                        Spacer()
                        Button("Restore Defaults…") { confirm = true }
                            .disabled(store.isManaged || pane.isDefault(store.config))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Restore the default \(pane.title) settings?", isPresented: $confirm) {
            Button("Restore Defaults", role: .destructive) { pane.reset(&store.config) }
        }
    }
}

// MARK: - Panes

struct GeneralPane: View {
    @EnvironmentObject var app: AppController
    @ObservedObject var store: ConfigStore
    @StateObject private var perms = PermissionWatcher()
    @State private var loginItem = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var importMessage: String?
    @State private var updateTick = 0

    var body: some View {
        Section {
            if let owner = perms.secureInput {
                LabeledContent {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                } label: {
                    Text(owner.isEmpty ? "Secure Input is on" : "Secure Input is on in \(owner)")
                    Text(
                        "While a password field or secure app has focus, macOS keeps shortcuts from reaching Pounce. Click elsewhere or quit that app."
                    )
                }
            }
            LabeledContent {
                if perms.accessibility {
                    StatusText(ok: true)
                } else {
                    Button("Open System Settings…") { Permissions.openAccessibilitySettings() }
                }
            } label: {
                Text("Accessibility")
                Text("Required to find and click buttons.")
            }
            LabeledContent {
                if perms.screenRecording {
                    StatusText(ok: true)
                } else {
                    Button("Allow…") { Permissions.requestScreenRecording() }
                }
            } label: {
                Text("Screen Recording")
                Text("Optional. Used only by Text mode.")
            }
        } header: {
            Text("Permissions")
        } footer: {
            if !perms.accessibility {
                Text("Turn on Pounce in Privacy & Security › Accessibility. If it's already on, turn it off and on again.")
            }
        }
        Section {
            Toggle("Open at login", isOn: $loginItem)
                .disabled(LoginItem.managedByLaunchd)
                .onChange(of: loginItem) { _, on in
                    do { try LoginItem.set(on) } catch {
                        loginError = error.localizedDescription
                        loginItem = LoginItem.isEnabled
                    }
                }
            Toggle("Play sounds", isOn: $store.config.general.sounds)
            Toggle(isOn: $app.paused) {
                Text("Pause Pounce")
                Text("Turns off all Pounce shortcuts.")
            }
        } footer: {
            if LoginItem.managedByLaunchd {
                Text("Pounce is started at login by launchd.")
            } else if loginItem && LoginItem.needsApproval {
                HStack(spacing: 4) {
                    Text("Allow Pounce in Login Items to finish turning this on.")
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.link)
                }
            } else if let e = loginError {
                Text(e).foregroundStyle(.red)
            }
        }
        if UIHooks.preset != nil || UIHooks.importSettings != nil {
            Section {
                if let p = UIHooks.preset {
                    Picker(selection: Binding(get: { p.get(store.config) }, set: { p.set(&store.config, $0) })) {
                        ForEach(p.options, id: \.tag) { Text($0.title).tag($0.tag) }
                    } label: {
                        Text("Works like")
                        Text(p.detail(store.config).isEmpty ? "Sets keys and typing style to match another app." : p.detail(store.config))
                    }
                }
                if UIHooks.importSettings != nil {
                    LabeledContent {
                        ImportMenu(message: $importMessage, title: "Import from…")
                    } label: {
                        Text("Import settings")
                        Text(importMessage ?? "Copies your shortcuts and letters from an app you used before.")
                    }
                }
            } header: {
                Text("Switching From Another App")
            }
        }
        if let u = UIHooks.updater {
            Section {
                Toggle(
                    "Check for updates automatically",
                    isOn: Binding(
                        get: { u.automaticallyChecks },
                        set: {
                            u.automaticallyChecks = $0
                            updateTick += 1
                        }))
                LabeledContent {
                    HStack(spacing: 8) {
                        if u.isChecking { ProgressView().controlSize(.small) }
                        if u.availableVersion != nil {
                            Button("Download…") { u.openUpdate() }
                        }
                        Button("Check Now") {
                            u.check(manual: true)
                            updateTick += 1
                        }
                        .disabled(u.isChecking)
                    }
                } label: {
                    if let v = u.availableVersion {
                        Text("Version \(v) is available")
                    } else {
                        Text("Pounce is up to date")
                    }
                    Text(u.lastChecked.map { "Last checked \($0.formatted(.relative(presentation: .named)))." } ?? "Version \(appVersion)")
                }
                .id(updateTick)
            } header: {
                Text("Updates")
            }
            .onReceive(NotificationCenter.default.publisher(for: .pounceUpdateStatus)) { _ in updateTick += 1 }
        }
    }
}

struct ShortcutsPane: View {
    @ObservedObject var store: ConfigStore
    private let defaults = Config.Shortcuts()

    /// Modes sharing the same shortcut (only one of them would work).
    private var clashes: Set<ModeKind> {
        let pairs = ModeKind.allCases.compactMap { m in Shortcut.parse(m.shortcut(in: store.config.shortcuts)).map { ($0.display, m) } }
        return Set(Dictionary(grouping: pairs, by: \.0).values.filter { $0.count > 1 }.flatMap { $0.map(\.1) })
    }

    var body: some View {
        Section {
            ForEach(ModeKind.allCases) { m in
                LabeledContent {
                    HStack(spacing: 6) {
                        if clashes.contains(m) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help("Another mode uses this shortcut")
                        }
                        ShortcutField(
                            value: Binding(
                                get: { store.config.shortcuts[keyPath: ModeKind.keyPath(m)] },
                                set: { store.config.shortcuts[keyPath: ModeKind.keyPath(m)] = $0 }),
                            defaultValue: defaults[keyPath: ModeKind.keyPath(m)])
                    }
                } label: {
                    Text(m.title)
                    shortcutDetail(m.blurb, store.config.shortcuts[keyPath: ModeKind.keyPath(m)])
                }
            }
        } header: {
            Text("Modes")
        } footer: {
            if clashes.isEmpty {
                Text("Click a shortcut and press new keys. Press a mode's shortcut again to close it.")
            } else {
                Text("Two modes use the same shortcut. Only one of them will work.").foregroundStyle(.orange)
            }
        }
        if let kp = UIHooks.repeatShortcut {
            Section {
                LabeledContent {
                    ShortcutField(value: $store.config.shortcuts[dynamicMember: kp], defaultValue: defaults[keyPath: kp])
                } label: {
                    Text("Repeat Last")
                    shortcutDetail("Do the last click or scroll again, in any app.", store.config.shortcuts[keyPath: kp])
                }
            } header: {
                Text("Actions")
            }
        }
        Section {
            Toggle(isOn: $store.config.general.hyperKey) {
                Text("Use Caps Lock as Hyper key")
                Text("Caps Lock acts as ⌃⌥⇧⌘, for shortcuts like “hyper+f” that never clash with apps.")
            }
            Toggle("Press Caps Lock alone for Escape", isOn: $store.config.general.capsLockEscape)
                .disabled(!store.config.general.hyperKey)
        } header: {
            Text("Hyper Key")
        } footer: {
            Text("Caps Lock goes back to normal when Pounce quits.")
        }
    }

    /// The row's subtitle, or which other apps / macOS also use this shortcut.
    @ViewBuilder private func shortcutDetail(_ blurb: String, _ raw: String) -> some View {
        let others = UIHooks.shortcutConflicts?(raw) ?? []
        if others.isEmpty {
            Text(blurb)
        } else {
            Text("\(Image(systemName: "exclamationmark.triangle.fill")) Also used by \(others.formatted(.list(type: .and)))")
                .foregroundStyle(.orange)
                .help(blurb)
        }
    }
}

struct HintsPane: View {
    @ObservedObject var store: ConfigStore
    static let alphabets: [(String, String)] = [
        ("Home Row", "asdfghjkl"), ("Home and Top Rows", "asdfghjklqweruio"), ("Left Hand", "asdfqwerzxcv"),
        ("Colemak", "arstneiogm"), ("Dvorak", "aoeuhtnsid"),
    ]

    private var alphabetOK: Bool { Labels.uniqueChars(store.config.hints.alphabet).count >= 2 }
    private var h: Binding<Config.Hints> { $store.config.hints }
    private var after: ConfigChoice { UIHooks.afterClick }

    var body: some View {
        Section {
            HintPreview(hints: store.config.hints)
            Picker("Style", selection: h.theme) {
                Text("Automatic").tag(Theme.system)
                Text("Dark").tag(Theme.dark)
                Text("Light").tag(Theme.light)
                Text("Vimium").tag(Theme.vimium)
            }
            LabeledContent("Size") {
                HStack(spacing: 8) {
                    Text("A").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: h.size, in: 8...32, step: 1) { Text("Size") }
                        .labelsHidden()
                        .frame(width: 180)
                    Text("A").font(.system(size: 16)).foregroundStyle(.secondary)
                }
            }
            Toggle("Show key reminders at the bottom of the screen", isOn: h.showHUD)
        } header: {
            Text("Appearance")
        }
        Section {
            Picker(selection: h.labelsOnly) {
                Text("Type the button's name").tag(false)
                Text("Type the label").tag(true)
            } label: {
                Text("To choose a button")
                Text(
                    store.config.hints.labelsOnly
                        ? "Letters always pick labels. Space clicks."
                        : "Type part of its name and press Return, or hold Shift and type its label.")
            }
            LabeledContent {
                HStack(spacing: 6) {
                    TextField("Letters", text: h.alphabet)
                        .labelsHidden()
                        .font(.body.monospaced())
                        .frame(width: 160)
                    Menu("Presets") {
                        ForEach(Self.alphabets, id: \.1) { name, a in Button("\(name) (\(a))") { store.config.hints.alphabet = a } }
                    }
                    .fixedSize()
                }
            } label: {
                Text("Label letters")
                if alphabetOK {
                    Text("Home-row keys are the fastest to type.")
                } else {
                    Text("Use at least two different letters.").foregroundStyle(.red)
                }
            }
            Toggle("Click as soon as a label is complete", isOn: h.autoClick)
            Picker(selection: Binding(get: { after.get(store.config) }, set: { after.set(&store.config, $0) })) {
                ForEach(after.options, id: \.tag) { Text($0.title).tag($0.tag) }
            } label: {
                Text("After clicking")
                Text(after.detail(store.config))
            }
        } header: {
            Text("Typing")
        }
        Section {
            if let sc = UIHooks.hintScope {
                Picker(selection: Binding(get: { sc.get(store.config) }, set: { sc.set(&store.config, $0) })) {
                    ForEach(sc.options, id: \.tag) { Text($0.title).tag($0.tag) }
                } label: {
                    Text("Windows")
                    if !sc.detail(store.config).isEmpty { Text(sc.detail(store.config)) }
                }
            }
            ForEach(HintSource.allCases, id: \.self) { s in
                Toggle(
                    sourceName(s),
                    isOn: Binding(
                        get: { store.config.hints.sources.contains(s) },
                        set: { on in
                            store.config.hints.sources.removeAll { $0 == s }
                            if on { store.config.hints.sources.append(s) }
                        }))
            }
            Picker(selection: h.scan) {
                Text("Buttons, links and fields").tag(ScanMode.fast)
                Text("Everything").tag(ScanMode.exhaustive)
            } label: {
                Text("Label these")
                Text(store.config.hints.scan == .fast ? "Fastest." : "Also text, images and list rows. Slower in large apps.")
            }
        } header: {
            Text("Labels Appear On")
        }
        Section {
            Picker(selection: h.click) {
                Text("Mouse click").tag(ClickMethod.mouse)
                Text("Accessibility press").tag(ClickMethod.accessibility)
            } label: {
                Text("Click using")
                Text(store.config.hints.click == .mouse ? "Works in every app." : "Doesn't move the pointer. A few apps ignore it.")
            }
            Toggle("Move the pointer back after clicking", isOn: h.restoreCursor)
                .disabled(store.config.hints.click == .accessibility)
        } header: {
            Text("Clicking")
        }
    }

    private func sourceName(_ s: HintSource) -> String {
        switch s {
        case .window: "Front window"
        case .menubar: "Menu bar"
        case .extras: "Menu bar icons"
        case .dock: "Dock"
        }
    }
}

struct ScrollPane: View {
    @ObservedObject var store: ConfigStore
    var body: some View {
        Section {
            LabeledContent("Speed") { speedSlider($store.config.scroll.speed, 200...3000, step: 50) }
            LabeledContent {
                speedSlider($store.config.scroll.dashSpeed, 200...10000, step: 100)
            } label: {
                Text("Speed with Shift")
            }
            Picker(selection: $store.config.scroll.keys) {
                Text("H J K L (Vim)").tag("hjkl")
                Text("D H T N (Dvorak)").tag("dhtn")
                Text("H N E I (Colemak)").tag("hnei")
                if !["hjkl", "dhtn", "hnei"].contains(store.config.scroll.keys) {
                    Text(store.config.scroll.keys.uppercased()).tag(store.config.scroll.keys)
                }
            } label: {
                Text("Keys")
                Text("Left, down, up, right.")
            }
        } header: {
            Text("Scroll")
        }
        Section {
            if let gs = UIHooks.gridStyle {
                Picker(selection: Binding(get: { gs.get(store.config) }, set: { gs.set(&store.config, $0) })) {
                    ForEach(gs.options, id: \.tag) { Text($0.title).tag($0.tag) }
                } label: {
                    Text("Style")
                    if !gs.detail(store.config).isEmpty { Text(gs.detail(store.config)) }
                }
            }
            Picker(selection: $store.config.grid.keys) {
                Text("U I O · J K L · M , .").tag("uiojklm,.")
                Text("Q W E · A S D · Z X C").tag("qweasdzxc")
                Text("7 8 9 · 4 5 6 · 1 2 3").tag("789456123")
                if !["uiojklm,.", "qweasdzxc", "789456123"].contains(store.config.grid.keys) {
                    Text(store.config.grid.keys.uppercased()).tag(store.config.grid.keys)
                }
            } label: {
                Text("Keys")
                Text("One key per cell, top left first.")
            }
        } header: {
            Text("Grid")
        } footer: {
            Text("Use the grid where there are no real buttons, like games, canvases and remote desktops.")
        }
    }

    private func speedSlider(_ v: Binding<Double>, _ range: ClosedRange<Double>, step: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "tortoise").foregroundStyle(.secondary)
            Slider(value: v, in: range, step: step) { Text("Speed") }.labelsHidden().frame(width: 180)
            Image(systemName: "hare").foregroundStyle(.secondary)
        }
    }
}

struct AppsPane: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Section {
            ForEach(store.config.general.ignoredApps, id: \.self) { id in
                LabeledContent {
                    Button {
                        store.config.general.ignoredApps.removeAll { $0 == id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                    .accessibilityLabel("Remove \(AppInfo.name(id))")
                } label: {
                    AppLabel(id: id)
                }
            }
            if store.config.general.ignoredApps.isEmpty {
                Text("No apps").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                AddAppMenu(title: "Add App…", exclude: Set(store.config.general.ignoredApps)) {
                    store.config.general.ignoredApps.append($0)
                }
            }
        } header: {
            Text("Ignored Apps")
        } footer: {
            Text("Pounce shortcuts go straight to these apps. Useful for games and apps with their own Vim keys.")
        }
        Section {
            ForEach(store.config.apps.keys.sorted(), id: \.self) { id in
                AppOverrideRow(
                    id: id,
                    value: Binding(
                        get: { store.config.apps[id] ?? .init() },
                        set: { store.config.apps[id] = $0 }),
                    onRemove: { store.config.apps[id] = nil })
            }
            if store.config.apps.isEmpty {
                Text("No apps").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                AddAppMenu(title: "Add App…", exclude: Set(store.config.apps.keys)) { store.config.apps[$0] = .init() }
            }
        } header: {
            Text("Per-App Settings")
        } footer: {
            Text("Give one app its own labels or typing style. Anything left on Default follows the Click settings.")
        }
    }
}

/// One app's overrides; collapsed it shows a summary, expanded three pickers.
struct AppOverrideRow: View {
    let id: String
    @Binding var value: Config.AppOverride
    var onRemove: () -> Void

    var body: some View {
        DisclosureGroup {
            Picker("Pounce shortcuts", selection: optional(\.ignore)) {
                Text("Default").tag(Bool?.none)
                Text("On").tag(Bool?.some(false))
                Text("Off in this app").tag(Bool?.some(true))
            }
            Picker("Label these", selection: $value.scan) {
                Text("Default").tag(ScanMode?.none)
                Text("Buttons, links and fields").tag(ScanMode?.some(.fast))
                Text("Everything").tag(ScanMode?.some(.exhaustive))
            }
            Picker("To choose a button", selection: optional(\.labelsOnly)) {
                Text("Default").tag(Bool?.none)
                Text("Type the button's name").tag(Bool?.some(false))
                Text("Type the label").tag(Bool?.some(true))
            }
            HStack {
                Spacer()
                Button("Remove App", role: .destructive, action: onRemove)
            }
        } label: {
            LabeledContent {
                Text(summary).foregroundStyle(.secondary)
            } label: {
                AppLabel(id: id)
            }
        }
    }

    private func optional(_ kp: WritableKeyPath<Config.AppOverride, Bool?>) -> Binding<Bool?> {
        Binding(get: { value[keyPath: kp] }, set: { value[keyPath: kp] = $0 })
    }

    private var summary: String {
        let parts = [
            value.ignore.map { $0 ? "Off" : "On" }, value.scan.map { $0 == .fast ? "Buttons only" : "Everything" },
            value.labelsOnly.map { $0 ? "Type labels" : "Type names" },
        ].compactMap { $0 }
        return parts.isEmpty ? "Default" : parts.joined(separator: ", ")
    }
}

/// Running apps first, then "Other…" for anything installed.
struct AddAppMenu: View {
    let title: String
    var exclude: Set<String> = []
    let add: (String) -> Void

    var body: some View {
        Menu(title) {
            Section("Running") {
                ForEach(AppInfo.running.filter { !exclude.contains($0.bundleIdentifier ?? "") }, id: \.bundleIdentifier) { a in
                    Button {
                        if let id = a.bundleIdentifier { add(id) }
                    } label: {
                        if let icon = a.icon { Image(nsImage: AppInfo.menuIcon(icon)) }
                        Text(a.localizedName ?? a.bundleIdentifier ?? "?")
                    }
                }
            }
            Divider()
            Button("Other…") {
                for id in AppInfo.chooseInstalled() where !exclude.contains(id) { add(id) }
            }
        }
        .fixedSize()
    }
}

struct AppLabel: View {
    let id: String
    var body: some View {
        HStack(spacing: 8) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed").frame(width: 20, height: 20)
            }
            Text(AppInfo.name(id))
        }
    }
}

@MainActor
enum AppInfo {
    static var running: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.processIdentifier != getpid()
        }
        .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    static func name(_ id: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map {
            FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
        } ?? id
    }

    static func menuIcon(_ img: NSImage) -> NSImage {
        let i = img.copy() as! NSImage
        i.size = NSSize(width: 16, height: 16)
        return i
    }

    /// Open panel on /Applications; returns the bundle IDs of the chosen apps.
    static func chooseInstalled() -> [String] {
        let p = NSOpenPanel()
        p.title = "Choose Apps"
        p.prompt = "Add"
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.applicationBundle]
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.treatsFilePackagesAsDirectories = false
        guard p.runModal() == .OK else { return [] }
        return p.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
    }
}

struct AboutPane: View {
    @EnvironmentObject var app: AppController
    @ObservedObject var store: ConfigStore
    @State private var confirmReset = false

    var body: some View {
        Section {
            VStack(spacing: 6) {
                AppIconView(size: 72)
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                    .padding(.bottom, 4)
                Text("Pounce").font(.title2.weight(.semibold))
                Text("Version \(appVersion)").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        Section {
            LabeledContent("Settings file") {
                Text(Paths.configFile.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.callout.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Button("Open in Editor") { store.openInEditor() }
                Button("Show in Finder") { store.revealInFinder() }
            }
        } footer: {
            Text("Settings are saved to this file. Changes to it apply right away.")
        }
        Section {
            LabeledContent("Keyboard access") {
                StatusText(ok: app.tapInstalled, okText: "On", badText: "Waiting for Accessibility")
            }
            HStack {
                Button("Show Welcome…") { WindowManager.shared.showOnboarding(app) }
                Button("Run Self-Test…") { WindowManager.shared.showSelfTest(app) }
            }
        } header: {
            Text("Help")
        }
        Section {
        } footer: {
            HStack {
                Spacer()
                Button("Reset All Settings…", role: .destructive) { confirmReset = true }
                    .disabled(store.isManaged || store.config == Config())
            }
            .confirmationDialog("Reset all Pounce settings?", isPresented: $confirmReset) {
                Button("Reset All Settings", role: .destructive) { store.reset() }
            } message: {
                Text("Shortcuts, labels, scrolling and ignored apps go back to their defaults.")
            }
        }
    }
}

var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
