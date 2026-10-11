import PounceCore
import SwiftUI

/// Every key Pounce understands, grouped by mode, laid out like grouped Form sections.
struct CheatSheet: View {
    let config: Config
    var filter = ""
    var columns = 2

    struct Row: Hashable {
        let action: String
        let keys: String
    }

    struct ModeKeys: Identifiable {
        let id: String
        let title: String
        let symbol: String
        /// Raw shortcut that opens the section ("" for none).
        let shortcut: String
        let rows: [Row]
    }

    /// Rows per section, keyed by `ModeKind.rawValue`. Edit strings here; sections for modes
    /// that don't exist (yet) are skipped.
    func table() -> [(String, [Row])] {
        let s = Array(config.scroll.keys.count == 4 ? config.scroll.keys : "hjkl").map { String($0).uppercased() }
        let g = config.grid.keys.uppercased().map(String.init).joined(separator: " ")
        let labelsOnly = config.hints.labelsOnly
        var click: [Row] = [
            labelsOnly ? Row(action: "Click a label", keys: "label") : Row(action: "Search by name", keys: "type"),
            labelsOnly ? Row(action: "Click focused", keys: "Space") : Row(action: "Jump to a label", keys: "⇧ label"),
            Row(action: "Click", keys: "↩"), Row(action: "Double-click", keys: "⌃↩"),
            Row(action: "Right-click", keys: "⇧↩"), Row(action: "⌘-click (new tab)", keys: "⌘↩"), Row(action: "⌥-click", keys: "⌥↩"),
        ]
        click += [
            Row(action: "Middle-click", keys: "⌃M"), Row(action: "Back / forward button", keys: "⌃O  ⌃T"),
            Row(action: "Type into the focused field", keys: "= text ↩"),
            Row(action: "Next / previous", keys: "⇥  ⇧⇥"),
            Row(action: "Only fields, links, buttons", keys: "⌃I  ⌃L  ⌃B"),
            Row(action: "Go to the first field", keys: "⌃I ↩"),
            Row(action: "Copy link or text", keys: "⌃Y"), Row(action: "Move pointer there", keys: "⌃H"),
            Row(action: "Focus without clicking", keys: "⌃F"), Row(action: "Drag to another element", keys: "⌃D … ↩"),
            Row(action: "Repeat last click", keys: "⌃R"), Row(action: "Clear search", keys: "⌃U"),
            Row(action: "Explain focused element", keys: "?"), Row(action: "Close", keys: "esc"),
        ]
        var grid: [Row] = [Row(action: "Zoom into a cell", keys: g)]
        if config.grid.style == .twokey {
            grid = [Row(action: "Pick a cell: row, then column", keys: "A–Z  A–Z"), Row(action: "Then zoom", keys: g)]
        }
        grid += [
            Row(action: "Click the center", keys: "↩"),
            Row(action: "Move pointer", keys: "Space"), Row(action: "Zoom out", keys: "⌫"),
            Row(action: "Nudge", keys: "← ↑ ↓ →"), Row(action: "Drag", keys: "⌃D … ↩"), Row(action: "Next display", keys: "⇥"),
        ]
        return [
            ("hint", click),
            (
                "scroll",
                [
                    Row(action: "Scroll left, down, up, right", keys: s.joined(separator: " ")),
                    Row(action: "Scroll faster", keys: "⇧ + \(s.joined())"),
                    Row(action: "Half page down / up", keys: "D  U"), Row(action: "Top / bottom", keys: "G G  ⇧G"),
                    Row(action: "Next scroll area", keys: "⇥  1–9"), Row(action: "Close", keys: "esc"),
                ]
            ),
            (
                "mouse",
                [
                    Row(action: "Move the pointer", keys: s.joined(separator: " ")), Row(action: "Move faster / slower", keys: "⇧  ⌥"),
                    Row(action: "Nudge 1 pt (⇧ 10 pt)", keys: "← ↑ ↓ →"),
                    Row(action: "Click", keys: "Space  ↩"), Row(action: "Right-click", keys: "⇧↩  R"),
                    Row(action: "Double-click", keys: "C  ⌃↩"), Row(action: "Middle-click", keys: "M"),
                    Row(action: "⌘-click / ⌥-click", keys: "⌘↩  ⌥↩"), Row(action: "Back / forward button", keys: "[  ]"),
                    Row(action: "Drag: pick up, drop", keys: "V … V"), Row(action: "Scroll down / up", keys: "D  U"),
                    Row(action: "Close", keys: "esc"),
                ]
            ),
            (
                "windows",
                [
                    Row(action: "Bring window forward", keys: "label"),
                    Row(action: "Left / right half", keys: "⌥←  ⌥→"), Row(action: "Maximize", keys: "⌥↑"),
                    Row(action: "Move to next display", keys: "⌥↓"), Row(action: "Close", keys: "esc"),
                ]
            ),
            (
                "menu",
                [
                    Row(action: "Search menu items", keys: "type"), Row(action: "Choose", keys: "↑  ↓"),
                    Row(action: "Run", keys: "↩"), Row(action: "Close", keys: "esc"),
                ]
            ),
            ("grid", grid),
            (
                "text",
                [
                    Row(action: "Click a word", keys: "type or label"), Row(action: "Click", keys: "↩"), Row(action: "Close", keys: "esc"),
                ]
            ),
        ]
    }

    var groups: [ModeKeys] {
        var out = table().compactMap { raw, rows -> ModeKeys? in
            guard let m = ModeKind(rawValue: raw) else { return nil }
            return ModeKeys(id: raw, title: m.title, symbol: m.symbol, shortcut: m.shortcut(in: config.shortcuts), rows: rows)
        }
        if let kp = UIHooks.repeatShortcut {
            out.append(
                ModeKeys(
                    id: "anywhere", title: "Anywhere", symbol: "globe", shortcut: "",
                    rows: [
                        Row(action: "Repeat the last click or scroll", keys: shortcutDisplay(config.shortcuts[keyPath: kp]))
                    ]))
        }
        return out
    }

    var filtered: [ModeKeys] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return groups }
        return groups.compactMap { g in
            if g.title.lowercased().contains(q) { return g }
            let rows = g.rows.filter { $0.action.lowercased().contains(q) || $0.keys.lowercased().contains(q) }
            return rows.isEmpty ? nil : ModeKeys(id: g.id, title: g.title, symbol: g.symbol, shortcut: g.shortcut, rows: rows)
        }
    }

    var body: some View {
        let gs = filtered
        VStack(alignment: .leading, spacing: 22) {
            if gs.isEmpty {
                Text("No Results for “\(filter)”").font(.title3).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 60)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(balanced(gs), id: \.first?.id) { col in
                        VStack(spacing: 22) { ForEach(col) { section($0) } }
                    }
                }
            }
            Text("Press a mode's shortcut again or Esc to close it. Any ⌘ shortcut closes it and goes to the app.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
    }

    /// Splits sections into columns of roughly equal height.
    private func balanced(_ gs: [ModeKeys]) -> [[ModeKeys]] {
        var cols = Array(repeating: [ModeKeys](), count: max(columns, 1))
        var heights = Array(repeating: 0, count: cols.count)
        for g in gs {
            let i = heights.indices.min { heights[$0] < heights[$1] }!
            cols[i].append(g)
            heights[i] += g.rows.count + 2
        }
        return cols.filter { !$0.isEmpty }
    }

    private func section(_ g: ModeKeys) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(g.title, systemImage: g.symbol).font(.headline)
                Spacer()
                if !g.shortcut.isEmpty {
                    Text(shortcutDisplay(g.shortcut)).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            VStack(spacing: 0) {
                ForEach(Array(g.rows.enumerated()), id: \.offset) { i, r in
                    if i > 0 { Divider().padding(.leading, 10) }
                    HStack {
                        Text(r.action)
                        Spacer(minLength: 12)
                        KeyCap(text: r.keys)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
        }
        .frame(maxWidth: .infinity)
    }
}

/// The standalone cheat-sheet window, with search in the toolbar.
struct CheatSheetWindow: View {
    @ObservedObject var store: ConfigStore
    @State private var filter = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Press").foregroundStyle(.secondary)
                    KeyCap(text: shortcutDisplay(store.config.shortcuts.hint))
                    Text(store.config.hints.labelsOnly ? "and type a label to click anything." : "and type a button's name to click it.")
                        .foregroundStyle(.secondary)
                }
                .font(.title3)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                CheatSheet(config: store.config, filter: filter, columns: 2)
            }
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .searchable(text: $filter, prompt: "Search Keys")
        .navigationTitle("Cheat Sheet")
        .frame(minWidth: 720, minHeight: 440)
    }
}
