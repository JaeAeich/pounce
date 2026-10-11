import PounceCore
import SwiftUI

/// Setup in three calm pages: allow Accessibility, try it, done.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case allow, practice, done
        var title: String {
            switch self {
            case .allow: "Allow"
            case .practice: "Practice"
            case .done: "Done"
            }
        }
    }

    @EnvironmentObject var app: AppController
    @ObservedObject var store: ConfigStore
    @StateObject private var perms = PermissionWatcher()
    @State private var step: Step
    @State private var loginItem = LoginItem.isEnabled
    @State private var hit: Set<Int> = []
    @State private var importMessage: String?
    var onDone: () -> Void

    /// `initialStep` defaults to Practice when Accessibility is already allowed.
    init(store: ConfigStore, initialStep: Step? = nil, onDone: @escaping () -> Void) {
        self.store = store
        self.onDone = onDone
        _step = State(initialValue: initialStep ?? (Permissions.accessibility ? .practice : .allow))
    }

    private var hintKey: String { shortcutDisplay(store.config.shortcuts.hint) }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .allow: allowPage
                case .practice: practicePage
                case .done: donePage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            .transition(.opacity)
            .id(step)
            footer
        }
        .frame(width: 560, height: 600)
        .animation(.easeInOut(duration: 0.25), value: step)
        .onChange(of: perms.accessibility) { _, ok in
            guard ok else { return }
            app.ensureTap()
            if step == .allow {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { if step == .allow { step = .practice } }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        ZStack {
            HStack(spacing: 7) {
                ForEach(Step.allCases, id: \.self) { s in
                    Circle().fill(s == step ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)).frame(width: 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(step.rawValue + 1) of 3")
            HStack {
                if step != .allow {
                    Button("Back") { step = Step(rawValue: step.rawValue - 1)! }
                        .glassButton()
                }
                Spacer()
                primaryButton
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
    }

    @ViewBuilder private var primaryButton: some View {
        switch step {
        case .allow:
            if perms.accessibility {
                Button("Continue") { step = .practice }.prominentButton().keyboardShortcut(.defaultAction)
            } else {
                Button("Not Now") { step = .practice }.glassButton()
            }
        case .practice:
            if practiceDone {
                Button("Continue") { step = .done }.prominentButton().keyboardShortcut(.defaultAction)
            } else {
                Button("Skip") { step = .done }.glassButton()
            }
        case .done:
            Button("Done") { onDone() }.prominentButton().keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Pages

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.largeTitle.weight(.semibold))
            Text(subtitle).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var allowPage: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            AppIconView(size: 112)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
            heading("Welcome to Pounce", "Click anything on screen by typing.")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility").font(.headline)
                        Text("Lets Pounce find and click buttons.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if perms.accessibility {
                        StatusText(ok: true)
                    } else {
                        Button("Open System Settings") { Permissions.openAccessibilitySettings() }
                            .prominentButton()
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(14)
                .background(groupShape.fill(.quinary))
                HStack(spacing: 6) {
                    if !perms.accessibility {
                        ProgressView().controlSize(.mini)
                        Text("Turn on Pounce in the list, then come back here.")
                    } else {
                        Text("Thanks. Pounce can now click for you.")
                    }
                }
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                if !perms.accessibility {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Already on but not working? Turn Pounce off and on again in the list.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open List") { openPrivacyPane("Privacy_Accessibility") }
                            .buttonStyle(.link)
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: 420)
            Spacer(minLength: 0)
        }
    }

    private static let targets: [(String, String)] = [("Star", "star"), ("Moon", "moon"), ("Heart", "heart")]
    private var practiceDone: Bool { hit.count == Self.targets.count }

    private var practicePage: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Text("Try It").font(.largeTitle.weight(.semibold))
                HStack(spacing: 6) {
                    Text("Press")
                    KeyCap(text: hintKey)
                    Text(store.config.hints.labelsOnly ? "then type a label." : "then type “star” and press Return.")
                }
                .font(.title3).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                ForEach(Array(Self.targets.enumerated()), id: \.offset) { i, t in
                    let done = hit.contains(i)
                    Button {
                        hit.insert(i)
                    } label: {
                        Label(t.0, systemImage: done ? "checkmark.circle.fill" : t.1)
                            .frame(minWidth: 96)
                    }
                    .controlSize(.extraLarge)
                    .glassButton()
                    .tint(done ? .green : nil)
                    .accessibilityLabel(t.0)
                }
            }
            .animation(.snappy, value: hit)
            Group {
                if !perms.accessibility {
                    Label("Pounce needs Accessibility first.", systemImage: "exclamationmark.circle")
                } else if practiceDone {
                    Label("That's it. You can click anything this way.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if app.activeMode == .hint {
                    Text(
                        store.config.hints.labelsOnly ? "Pounce is open. Type a label." : "Pounce is open. Type a name, then press Return.")
                } else if hit.isEmpty {
                    Text("Click all three without touching the mouse.")
                } else {
                    Text("\(hit.count) of \(Self.targets.count). Keep going.")
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            .frame(minHeight: 20)
            Text("Tip: hold Shift and type the small label to jump straight to a button.")
                .font(.footnote).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    private var donePage: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            VStack(spacing: 14) {
                Text("You're All Set").font(.largeTitle.weight(.semibold))
                KeyCap(text: hintKey, large: true)
                Text("Press it anytime. Pounce lives in the menu bar.").font(.title3).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                HStack {
                    Text("Open at login")
                    Spacer()
                    Toggle("Open at login", isOn: $loginItem)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(LoginItem.managedByLaunchd)
                        .onChange(of: loginItem) { _, on in
                            try? LoginItem.set(on)
                            loginItem = LoginItem.isEnabled
                        }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Divider().padding(.leading, 14)
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Text mode")
                        Text("Optional. Needs Screen Recording.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if perms.screenRecording { StatusText(ok: true) } else { Button("Allow…") { Permissions.requestScreenRecording() } }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                if UIHooks.preset != nil || UIHooks.importSettings != nil {
                    SwitchingRows(store: store, message: $importMessage)
                }
            }
            .background(groupShape.fill(.quinary))
            .frame(maxWidth: 420)
            if let m = importMessage {
                Text(m).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            HStack(spacing: 20) {
                Button("Cheat Sheet…") { WindowManager.shared.showCheatSheet(app) }
                Button("Change Shortcuts…") { WindowManager.shared.showSettings(app, pane: .shortcuts) }
            }
            .buttonStyle(.link)
            Spacer(minLength: 0)
        }
    }

    private var groupShape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }
}

/// "Coming from Homerow / Shortcat / Vimium?": a preset picker and an Import menu (both hooks).
struct SwitchingRows: View {
    @ObservedObject var store: ConfigStore
    @Binding var message: String?

    var body: some View {
        if let p = UIHooks.preset {
            Divider().padding(.leading, 14)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Coming from another app?")
                    Text("Use the keys you know.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Works like", selection: Binding(get: { p.get(store.config) }, set: { p.set(&store.config, $0) })) {
                    ForEach(p.options, id: \.tag) { Text($0.title).tag($0.tag) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        if UIHooks.importSettings != nil {
            Divider().padding(.leading, 14)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Import settings")
                    Text("From Homerow, Shortcat or Vimium.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                ImportMenu(message: $message)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }
}

/// "Import from…" menu listing the tools `UIHooks.importSettings` can read.
struct ImportMenu: View {
    @Binding var message: String?
    var title = "Import…"

    var body: some View {
        if let run = UIHooks.importSettings {
            Menu(title) {
                ForEach(UIHooks.tools.filter { UIHooks.importableTools.contains($0.tag) }, id: \.tag) { t in
                    Button(t.title) {
                        do { message = try run(t.tag) } catch { message = "Couldn't import from \(t.title): \(error.localizedDescription)" }
                    }
                }
            }
            .fixedSize()
        }
    }
}
