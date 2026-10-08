import Foundation

/// When a window counts as "on screen" for Windows mode and all-windows hints.
///
/// Tiling managers (AeroSpace) hide windows of other workspaces by parking them so only
/// ~1 px stays on screen; CGWindowList still reports those as on-screen. A window is
/// visible only if at least `minFraction` of it, and at least `minSide`×`minSide` points,
/// lies on a single screen.
public enum WindowVisibility {
    public static let minFraction = 0.10
    public static let minSide = 40.0

    /// The largest part of `frame` on any one screen (global top-left coordinates).
    public static func visiblePart(_ frame: Rect, screens: [Rect]) -> Rect {
        screens.map { frame.intersection($0) }.max { $0.area < $1.area } ?? .zero
    }

    public static func isVisible(_ frame: Rect, screens: [Rect]) -> Bool {
        guard frame.area > 0 else { return false }
        let v = visiblePart(frame, screens: screens)
        return v.width >= minSide && v.height >= minSide && v.area >= frame.area * minFraction
    }

    /// True if badges of `size` centred on each rect's visible part would overlap one another.
    /// Windows mode switches to a list when this happens (stacked maximized windows).
    public static func badgesCollide(_ frames: [Rect], size: (w: Double, h: Double)) -> Bool {
        let boxes = frames.map { Rect(x: $0.midX - size.w / 2, y: $0.midY - size.h / 2, width: size.w, height: size.h) }
        for i in boxes.indices {
            for j in boxes.indices where j > i && !boxes[i].intersection(boxes[j]).isEmpty { return true }
        }
        return false
    }
}

/// Vision OCR languages from the user's preferred languages.
public enum OCRLanguages {
    /// `preferred` (BCP-47, e.g. "de-CH", "zh-Hans-CN") mapped onto `supported` (Vision's list),
    /// in preference order, plus "en-US" last. Matching: exact, then language+script, then language.
    public static func pick(preferred: [String], supported: [String]) -> [String] {
        func parts(_ s: String) -> [String] { s.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init) }
        func script(_ p: [String]) -> String? { p.dropFirst().first { $0.count == 4 } }
        var out: [String] = []
        for pref in preferred {
            let p = parts(pref)
            guard let lang = p.first?.lowercased() else { continue }
            let match =
                supported.first { $0.caseInsensitiveCompare(pref) == .orderedSame }
                ?? supported.first { s in
                    let q = parts(s)
                    return q.first?.lowercased() == lang && script(q) != nil && script(q) == script(p)
                }
                ?? supported.first { s in
                    let q = parts(s)
                    // Chinese without a script in the preference: guess from the region.
                    if lang == "zh", script(p) == nil, let sc = script(q) {
                        let trad = p.contains { ["TW", "HK", "MO"].contains($0.uppercased()) }
                        return q.first == "zh" && sc == (trad ? "Hant" : "Hans")
                    }
                    return q.first?.lowercased() == lang
                }
            if let m = match, !out.contains(m) { out.append(m) }
        }
        if !out.contains("en-US") { out.append("en-US") }
        return out
    }
}
