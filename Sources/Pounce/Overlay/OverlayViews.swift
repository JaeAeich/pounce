import PounceCore
import SwiftUI

/// SwiftUI layer of one per-screen overlay panel: HUD, toasts, tutor card, palette. `screen` is that screen's
/// global top-left frame. Hints, grid and scroll areas are Core Animation layers underneath (OverlayCanvas).
struct OverlayRoot: View {
    @ObservedObject var model: OverlayModel
    let screen: Rect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let t = model.tutor, intersects(t.frame) { TutorCard(info: t).offset(tutorOffset(t.frame)) }
            if let p = model.palette, screen == model.activeScreen {
                PaletteView(query: p.query, rows: p.rows, total: p.total, placeholder: p.placeholder, style: model.style)
                    .frame(width: min(640, screen.width - 40))
                    .position(x: screen.width / 2, y: screen.height * 0.3)
            }
            if screen == model.activeScreen {
                hudLayer
            }
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        .environment(\.colorScheme, model.style.resolvedTheme == .light ? .light : .dark)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var hudLayer: some View {
        if let y = model.hudY {
            // Moved off labels: HUD at that band, toast just below it.
            VStack(spacing: 8) {
                if let h = model.hud { HUDView(state: h) }
                if let t = model.toast { ToastView(text: t).transition(.opacity.combined(with: .scale(scale: 0.96))) }
                Spacer(minLength: 0)
            }
            .padding(.top, y)
            .frame(width: screen.width, height: screen.height)
            .animation(.easeOut(duration: 0.12), value: model.toast)
        } else {
            VStack(spacing: 8) {
                Spacer()
                if let t = model.toast { ToastView(text: t).transition(.opacity.combined(with: .scale(scale: 0.96))) }
                if let h = model.hud { HUDView(state: h) }
            }
            .frame(width: screen.width, height: screen.height - OverlayModel.hudBottomInset)
            .animation(.easeOut(duration: 0.12), value: model.toast)
        }
    }

    private func local(_ r: Rect) -> Rect { Geometry.local(r, inScreenTopLeft: screen) }
    private func intersects(_ r: Rect) -> Bool { !r.intersection(screen).isEmpty }
    private func tutorOffset(_ f: Rect) -> CGSize {
        let l = local(f)
        let below = l.maxY + 8 + 150 < screen.height
        return CGSize(width: min(max(l.x, 8), screen.width - 300), height: below ? l.maxY + 8 : max(l.y - 158, 8))
    }
}

// MARK: - Pieces

/// A hint pill for SwiftUI surfaces (settings preview, palette): the exact bitmap the overlay uses.
struct HintPill: View {
    let badge: HintBadge
    let style: OverlayStyle
    @Environment(\.displayScale) private var scale

    var body: some View {
        let s = max(1, min(4, scale.rounded()))
        let key = PillKey(
            label: badge.label, typed: UInt8(min(badge.typed, 255)), focused: badge.focused, drag: badge.dragSource, scale: UInt8(s))
        if let img = OverlayArt(style: style, space: OverlayArt.sRGB).pill(key) {
            Image(decorative: img, scale: s).fixedSize()
        }
    }
}

// MARK: - Glass

/// Liquid Glass on macOS 26, a system material elsewhere. Snapshots force the material (glass needs a live backdrop).
enum OverlayGlass {
    nonisolated(unsafe) static var enabled = true
}

extension View {
    @ViewBuilder func overlayGlass<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26, *), OverlayGlass.enabled {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        }
    }
}

struct TutorCard: View {
    let info: TutorInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Searchable as", systemImage: "text.magnifyingglass")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(Array(info.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.0).font(.system(size: 11)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(row.1).font(.system(size: 11.5, weight: .medium)).lineLimit(2)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 290, alignment: .leading)
        .overlayGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Spotlight-style command palette.
struct PaletteView: View {
    let query: String
    let rows: [PaletteRow]
    let total: Int
    let placeholder: String
    let style: OverlayStyle

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .regular)).foregroundStyle(.secondary)
                Group {
                    if query.isEmpty {
                        Text(placeholder).foregroundStyle(.tertiary)
                    } else {
                        Text(query) + Text("|").foregroundColor(.accentColor).fontWeight(.light)
                    }
                }
                .font(.system(size: 22, weight: .regular))
                .lineLimit(1)
                Spacer(minLength: 8)
                if !query.isEmpty {
                    Text("\(total)").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 58)
            if !query.isEmpty || !rows.isEmpty {
                Divider().opacity(0.5).padding(.horizontal, 14)
                if rows.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.circle")
                        Text("No matches")
                    }
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 22)
                } else {
                    VStack(spacing: 2) {
                        ForEach(rows) { r in row(r) }
                    }
                    .padding(8)
                }
            }
        }
        .overlayGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func row(_ r: PaletteRow) -> some View {
        HStack(spacing: 12) {
            if !r.label.isEmpty {
                HintPill(
                    badge: HintBadge(id: r.id, label: r.label, typed: r.typed, frame: .zero, focused: false, dragSource: false),
                    style: style)
            } else {
                Image(systemName: "filemenu.and.selection").font(.system(size: 14)).frame(width: 20)
                    .foregroundStyle(r.focused ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
            if let icon = r.icon { Image(nsImage: icon).resizable().interpolation(.high).frame(width: 24, height: 24) }
            VStack(alignment: .leading, spacing: 1) {
                Text(r.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if !r.path.isEmpty {
                    Text(r.path).font(.system(size: 11.5)).lineLimit(1)
                        .foregroundStyle(r.focused ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            Spacer(minLength: 8)
            if let s = r.shortcut {
                Text(s).font(.system(size: 12.5)).foregroundStyle(
                    r.focused ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
        }
        .foregroundStyle(r.focused ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(r.focused ? Color.accentColor : .clear))
    }
}

/// Bottom-centre status capsule: mode, query, live count (or a spinner while scanning), key hints.
struct HUDView: View {
    let state: HUDState

    private var busy: Bool { state.detail?.hasSuffix("…") == true }
    private var noMatch: Bool { state.detail?.hasPrefix("No ") == true || state.detail?.hasPrefix("0 ") == true }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.mode.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor)
            Text(state.mode.title).font(.system(size: 13, weight: .semibold))
            if !state.query.isEmpty {
                Text(state.query).font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            if busy {
                ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 14, height: 14)
            }
            if let d = state.detail {
                if noMatch {
                    Label(d, systemImage: "exclamationmark.magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(
                        .orange)
                } else {
                    Text(d).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if !state.keys.isEmpty {
                Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 0.5, height: 16).padding(.horizontal, 2)
                HStack(spacing: 10) {
                    ForEach(Array(state.keys.enumerated()), id: \.offset) { _, k in KeyHint(text: k) }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .overlayGlass(Capsule())
        .fixedSize()
    }
}

/// "⏎ click" → keycap + action; plain phrases stay plain.
private struct KeyHint: View {
    let text: String
    var body: some View {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        let key = parts.first ?? text
        let isKey = key.count <= 4 && (key.contains { !$0.isLetter } || key.count <= 3)
        HStack(spacing: 4) {
            if isKey {
                Text(key).font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.09)))
                if parts.count > 1 { Text(parts[1]) }
            } else {
                Text(text)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
    }
}

struct ToastView: View {
    let text: String
    private var symbol: String {
        let t = text.lowercased()
        if t.hasPrefix("copied") { return "checkmark.circle.fill" }
        if t.contains("permission") { return "lock.fill" }
        if t.hasPrefix("no ") || t.hasPrefix("nothing") || t.hasPrefix("unknown") || t.contains("has no") {
            return "exclamationmark.circle"
        }
        return "info.circle"
    }
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16)
            .frame(height: 36)
            .overlayGlass(Capsule())
            .fixedSize()
    }
}
