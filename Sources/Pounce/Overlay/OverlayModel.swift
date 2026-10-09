import AppKit
import PounceCore
import SwiftUI

struct HintBadge: Identifiable, Equatable {
    let id: Int
    var label: String
    var typed: Int
    var frame: Rect
    var focused: Bool
    var dragSource: Bool
    /// Windows mode: app icon + title shown with the label.
    var title: String? = nil
    var icon: NSImage? = nil
}

struct TutorInfo: Equatable {
    var frame: Rect
    var rows: [(String, String)]
    static func == (a: TutorInfo, b: TutorInfo) -> Bool { a.frame == b.frame && a.rows.map(\.1) == b.rows.map(\.1) }
}

struct PaletteRow: Identifiable, Equatable {
    let id: Int
    var label: String
    var typed: Int
    var title: String
    var path: String
    var shortcut: String?
    var focused: Bool
    /// Windows list: the app's icon.
    var icon: NSImage? = nil
}

enum OverlayScene: Equatable {
    case none
    case hints(badges: [HintBadge], focusedFrame: Rect?, tutor: TutorInfo?, large: Bool)
    case scroll(areas: [Rect], selected: Int)
    case grid(rect: Rect, cells: [Rect], keys: [Character], dragFrom: Point?)
    /// Two-key grid, first stage: labelled cells; rows not matching `typed` are dimmed.
    case gridLabels(rect: Rect, cells: [GridLabelCell], typed: String, dragFrom: Point?)
    /// Mouse mode: ring around the pointer.
    case pointer(at: Point, dragging: Bool)
    case palette(query: String, rows: [PaletteRow], total: Int, placeholder: String)
}

struct HUDState: Equatable {
    var mode: ModeKind
    var query: String
    var detail: String?
    var keys: [String]
}

struct PaletteScene: Equatable {
    var query: String
    var rows: [PaletteRow]
    var total: Int
    var placeholder: String
}

@MainActor
final class OverlayModel: ObservableObject {
    /// Hints / scroll areas / grid are drawn by the layer renderer synchronously on set (no SwiftUI diffing).
    /// Only the low-frequency SwiftUI surfaces derived from it (tutor card, palette) are published.
    var scene: OverlayScene = .none {
        didSet {
            onSceneChange?()
            var t: TutorInfo?
            var p: PaletteScene?
            switch scene {
            case .hints(_, _, let tutor, _): t = tutor
            case .palette(let q, let rows, let total, let ph): p = PaletteScene(query: q, rows: rows, total: total, placeholder: ph)
            default: break
            }
            if tutor != t { tutor = t }
            if palette != p { palette = p }
            let y = hudSpot(scene)
            if hudY != y { hudY = y }
        }
    }
    @Published private(set) var tutor: TutorInfo?
    @Published private(set) var palette: PaletteScene?
    @Published var hud: HUDState?
    /// HUD top edge in the active screen's local points; nil = default bottom spot. Moves up to the
    /// first band without labels underneath it.
    @Published private(set) var hudY: Double?
    @Published var toast: String?
    @Published var style = OverlayStyle(theme: .system, size: 12) { didSet { if style != oldValue { onSceneChange?() } } }
    /// Screen (global top-left) where the HUD / palette are anchored.
    @Published var activeScreen: Rect = .zero

    /// Set by OverlayController: renders `scene` into the per-screen layer trees.
    var onSceneChange: (() -> Void)?

    private var toastWork: DispatchWorkItem?

    func flash(_ message: String) {
        toast = message
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: w)
    }

    var isEmpty: Bool { scene == .none && hud == nil && toast == nil }

    static let hudHeight = 52.0, hudWidth = 1120.0, hudBottomInset = 28.0

    /// Where the HUD goes: the default bottom spot unless labels are under it, then the lowest
    /// band (bottom → middle, then top) that covers no labels, else the one covering fewest.
    private func hudSpot(_ scene: OverlayScene) -> Double? {
        guard case .hints(let badges, _, _, _) = scene, activeScreen.width > 0, !badges.isEmpty else { return nil }
        let s = activeScreen, w = min(Self.hudWidth, s.width), h = Self.hudHeight + 8
        let bottom = s.height - Self.hudBottomInset - Self.hudHeight
        let frames = badges.map { Geometry.local($0.frame, inScreenTopLeft: s) }
        func covered(_ y: Double) -> Int {
            let band = Rect(x: (s.width - w) / 2, y: y - 4, width: w, height: h)
            return frames.reduce(0) { $0 + ($1.intersection(band).isEmpty ? 0 : 1) }
        }
        var spots = stride(from: bottom, through: s.height * 0.5, by: -64).map { $0 }
        spots.append(44)  // below the menu bar
        var best = (y: bottom, n: Int.max)
        for y in spots {
            let n = covered(y)
            if n == 0 { return y == bottom ? nil : y }
            if n < best.n { best = (y, n) }
        }
        return best.y == bottom ? nil : best.y
    }
}

struct OverlayStyle: Equatable {
    var theme: Theme
    var size: Double

    /// Resolved for the current system appearance.
    var palette: Palette {
        switch resolvedTheme {
        case .light: .light
        case .vimium: .vimium
        default: .dark
        }
    }

    /// `.system` mapped to `.dark` / `.light` for the current appearance.
    var resolvedTheme: Theme {
        guard theme == .system else { return theme }
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    func labelSize(_ label: String) -> (w: Double, h: Double) {
        (Double(max(label.count, 1)) * size * 0.68 + size * 0.9, size + size * 0.62)
    }
}

struct Palette {
    var background: Color
    var gradient: [Color]?
    var text: Color
    var typedText: Color
    var border: Color
    var accent: Color
    var focusText: Color

    /// The user's system accent colour (System Settings › Appearance), resolved when art is built.
    static var systemAccent: Color { Color(nsColor: .controlAccentColor) }

    // Neutral, native-looking pills; the accent only marks the focused one.
    static var dark: Palette {
        Palette(
            background: Color(white: 0.15).opacity(0.94), gradient: nil, text: .white, typedText: .white.opacity(0.38),
            border: .white.opacity(0.16), accent: systemAccent, focusText: .white)
    }
    static var light: Palette {
        Palette(
            background: Color(white: 0.995).opacity(0.97), gradient: nil, text: Color(white: 0.1), typedText: .black.opacity(0.32),
            border: .black.opacity(0.22), accent: systemAccent, focusText: .white)
    }
    static let vimium = Palette(
        background: Color(red: 1, green: 0.93, blue: 0.45),
        gradient: [Color(red: 1, green: 0.97, blue: 0.52), Color(red: 1, green: 0.77, blue: 0.26)],
        text: Color(red: 0.18, green: 0.14, blue: 0.02), typedText: Color(red: 0.6, green: 0.45, blue: 0.1),
        border: Color(red: 0.77, green: 0.54, blue: 0.13), accent: Color(red: 0.86, green: 0.18, blue: 0.24), focusText: .white)
}
