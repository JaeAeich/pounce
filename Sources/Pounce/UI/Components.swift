import AppKit
import PounceCore
import SwiftUI

// MARK: - Brand

/// The Pounce mark: a macOS-style rounded square with one glyph, the "click" cursor.
/// `size` is the squircle itself; app-icon renders add the standard margin around it.
struct AppIconView: View {
    var size: CGFloat = 128
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        ZStack {
            shape.fill(
                LinearGradient(
                    colors: [Color(red: 0.33, green: 0.60, blue: 1.0), Color(red: 0.10, green: 0.36, blue: 0.93)],
                    startPoint: .top, endPoint: .bottom))
            // Soft light from above, like Tahoe's layered icons.
            shape.fill(
                RadialGradient(
                    colors: [.white.opacity(0.28), .clear], center: UnitPoint(x: 0.5, y: 0.0), startRadius: 0, endRadius: size * 0.75))
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                lineWidth: max(size * 0.012, 0.5))
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: Color(red: 0.0, green: 0.12, blue: 0.45).opacity(0.45), radius: size * 0.03, y: size * 0.02)
                .offset(x: size * 0.02, y: size * 0.01)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Buttons

extension View {
    /// Liquid Glass prominent on macOS 26, bordered-prominent before.
    @ViewBuilder func prominentButton() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }

    /// Liquid Glass on macOS 26, bordered before.
    @ViewBuilder func glassButton() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glass) } else { buttonStyle(.bordered) }
    }
}

// MARK: - Shortcuts

/// Human text for a shortcut string from the config ("Off" when disabled/invalid).
func shortcutDisplay(_ raw: String) -> String { Shortcut.parse(raw)?.display ?? "Off" }

/// A shortcut recorder in the style of System Settings › Keyboard Shortcuts:
/// click it, press keys. The menu offers lone-modifier taps, the default and "Off".
struct ShortcutField: View {
    @Binding var value: String
    var defaultValue: String?
    @EnvironmentObject var app: AppController
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Text(recording ? "Type Shortcut" : display)
                    .foregroundStyle(recording || Shortcut.parse(value) == nil ? .secondary : .primary)
                    .monospacedDigit()
                    .frame(minWidth: 104)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(recording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: recording ? 2 : 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(recording ? "Press a key combination. Esc cancels, Delete turns the shortcut off." : "Click to record a new shortcut")
            .accessibilityLabel(recording ? "Recording shortcut" : "Shortcut, \(display)")
            .accessibilityHint("Click, then press the new key combination")

            Menu {
                Section("Single Modifier Key") {
                    ForEach(
                        [
                            "tap:rcmd", "tap:ropt", "tap:rshift", "tap:rctrl", "doubletap:lshift", "doubletap:lcmd", "doubletap:lctrl",
                            "doubletap:lopt",
                        ], id: \.self
                    ) { s in
                        Button(shortcutDisplay(s)) { value = s }
                    }
                }
                Divider()
                if let d = defaultValue, d != value {
                    Button("Restore Default (\(shortcutDisplay(d)))") { value = d }
                }
                Button("Turn Off") { value = "none" }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More options")
        }
        .onDisappear(perform: stopRecording)
    }

    private var display: String { shortcutDisplay(value) }

    private func toggle() { recording ? stopRecording() : startRecording() }

    private func startRecording() {
        recording = true
        app.recordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { e in
            if e.keyCode == KeyCodes.escape {
                stopRecording()
                return nil
            }
            if e.keyCode == KeyCodes.delete && e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                value = "none"
                stopRecording()
                return nil
            }
            var m: Modifiers = []
            let f = e.modifierFlags
            if f.contains(.command) { m.insert(.command) }
            if f.contains(.shift) { m.insert(.shift) }
            if f.contains(.option) { m.insert(.option) }
            if f.contains(.control) { m.insert(.control) }
            guard !m.isEmpty else {
                NSSound.beep()
                return nil
            }  // require a modifier for chords
            value = KeyChord(keyCode: e.keyCode, modifiers: m).description
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        app.recordingShortcut = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

/// Key glyphs on a quiet rounded background.
struct KeyCap: View {
    let text: String
    var large = false
    var body: some View {
        Text(text)
            .font(large ? .system(size: 20, weight: .medium) : .system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, large ? 12 : 6)
            .padding(.vertical, large ? 5 : 1.5)
            .background(RoundedRectangle(cornerRadius: large ? 9 : 5, style: .continuous).fill(.quaternary))
            .accessibilityLabel(text)
    }
}

/// "Allowed" with a green check, or nothing fancy. Matches System Settings' quiet status text.
struct StatusText: View {
    let ok: Bool
    var okText = "Allowed"
    var badText = "Not Allowed"
    var body: some View {
        Label {
            Text(ok ? okText : badText).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
        }
    }
}

// MARK: - Preview

/// A miniature window with hint labels on it, drawn with the real `HintPill`,
/// so theme, size and letter changes are visible instantly.
struct HintPreview: View {
    let hints: Config.Hints

    private static let buttons: [(String, CGRect)] = [
        ("Back", CGRect(x: 16, y: 16, width: 52, height: 22)),
        ("Search", CGRect(x: 80, y: 16, width: 150, height: 22)),
        ("Share", CGRect(x: 242, y: 16, width: 58, height: 22)),
        ("Library", CGRect(x: 16, y: 58, width: 92, height: 20)),
        ("Playlists", CGRect(x: 16, y: 84, width: 92, height: 20)),
        ("Play", CGRect(x: 128, y: 74, width: 76, height: 28)),
        ("Shuffle", CGRect(x: 214, y: 74, width: 86, height: 28)),
    ]

    var body: some View {
        let style = OverlayStyle(theme: hints.theme, size: hints.size)
        let labels = Labels.generate(count: Self.buttons.count, alphabet: hints.alphabet)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor))
            ForEach(Array(Self.buttons.enumerated()), id: \.offset) { _, b in
                Capsule()
                    .fill(.quaternary)
                    .overlay(Text(b.0).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1))
                    .frame(width: b.1.width, height: b.1.height)
                    .offset(x: b.1.minX, y: b.1.minY)
            }
            ForEach(Array(Self.buttons.enumerated()), id: \.offset) { i, b in
                if i < labels.count {
                    let l = labels[i]
                    let s = style.labelSize(l)
                    HintPill(
                        badge: HintBadge(id: i, label: l, typed: 0, frame: .zero, focused: i == 5 && !hints.labelsOnly, dragSource: false),
                        style: style
                    )
                    .frame(width: s.w, height: s.h)
                    .offset(x: b.1.minX - s.w * 0.6, y: b.1.midY - s.h / 2)
                }
            }
        }
        .frame(width: 316, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the hint labels")
    }
}

// MARK: - Permissions

/// Opens a Privacy & Security list in System Settings without triggering the system prompt.
func openPrivacyPane(_ anchor: String) {
    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(u) }
}

/// Polls permissions once a second so the UI updates the moment the user grants them.
@MainActor
final class PermissionWatcher: ObservableObject {
    @Published var accessibility = Permissions.accessibility
    @Published var screenRecording = Permissions.screenRecording
    /// App holding Secure Input ("" if unknown), nil when off. Needs `UIHooks.secureInputApp`.
    @Published var secureInput: String? = UIHooks.secureInputApp?()
    private var timer: Timer?

    init() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.accessibility != Permissions.accessibility { self.accessibility = Permissions.accessibility }
                if self.screenRecording != Permissions.screenRecording { self.screenRecording = Permissions.screenRecording }
                let secure = UIHooks.secureInputApp?()
                if self.secureInput != secure { self.secureInput = secure }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }
}

/// Kept for the self-test window; same look as `StatusText`.
struct StatusPill: View {
    let ok: Bool
    var okText = "Allowed"
    var badText = "Not Allowed"
    var body: some View { StatusText(ok: ok, okText: okText, badText: badText) }
}
