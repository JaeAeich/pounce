# Pounce — feature status

✅ done · 🟡 partial · ⬜ not yet. **[P]** = Homerow parity, **[+]** = Pounce extra.

## Click mode
- ✅ [P] Labels on actionable AX elements in the focused window, plus open menus/sheets
- ✅ [P] Fuzzy search (spaces/case ignored, `*`/`;` = all); best match focused
- ✅ [P] ⇥/↓/⌃N, ⇧⇥/↑/⌃P; ⇧+label jump; ⏎ / ⌃⏎ / ⇧⏎ / ⌘⏎; esc
- ✅ [P] Labels-only mode (␣ clicks); Tutor (`?`); click chain; fast vs exhaustive scan
- ✅ [P] Chromium/Electron AX enabling, re-asserted on every activation
- ✅ [+] Menu bar items, menu-bar extras, Dock as label sources
- ✅ [+] Filters ⌃I/⌃L/⌃B; ⌥⏎ option-click; ⌃⏎ double; ⌃H hover; ⌃F focus; ⌃Y copy; ⌃R repeat; ⌃U clear
- ✅ [+] Keyboard drag & drop (⌃D source → target ⏎)
- ✅ [+] Stable labels across activations + frequency-weighted short labels
- ✅ [+] Mouse-event or AXPress clicking, optional cursor restore
- ✅ [+] **new** Label scope: front window, every window on the screen, or every screen
- ✅ [+] **new** After click: close, stay open, or switch to Scroll
- ✅ [+] **new** Middle-click, back / forward buttons
- ✅ [+] **new** Repeat Last: global shortcut + menu bar item

## Scroll mode
- ✅ [P] Scroll-area detection, outline, ⇥/digits; smooth `hjkl`, ⇧ dash, d/u, gg/G (via scrollbar, falls back to wheel)
- ✅ [P] Configurable speeds and keys (Vim/Dvorak/Colemak presets)
- ✅ [+] Auto-select the area under the cursor

## Beyond accessibility
- ✅ [+] Grid mode: recursive 3×3, ⏎/⇧⏎/⌘⏎ click, ␣ move, ⌫ back, arrows nudge, ⇥ next screen, ⌃D drag
- ✅ [+] Text mode: OCR (Vision + ScreenCaptureKit), one label per word
- ✅ [+] **new** Mouse mode (⌃⌥C): keyboard pointer, click / right-click / drag / scroll
- ✅ [+] **new** Grid two-key style (column, then row)

## Windows & menus
- ✅ [+] Window switcher (labels + app icons), ⌥←/→ halves, ⌥↑ maximize, ⌥↓ next screen
- ✅ [+] Menu search palette with paths and shortcuts
- 🟡 [P] Mission Control navigation: covered by the window switcher; Mission Control itself isn't labelled

## Config & platform
- ✅ [P] Custom shortcuts, recorder UI, modifier-only (`tap:rcmd`, `doubletap:shift`), shortcut toggles mode
- ✅ [P] Caps Lock → Hyper (+ tap for Escape); themes (system/dark/light/vimium), size, alphabet presets; ignored apps; sounds
- ✅ [P] Multi-monitor overlays; layout-aware key input
- ✅ [+] `~/.config/pounce/config.toml`, hot reload, lenient validation, `pounce config check`
- ✅ [+] Nix: flake package, nix-darwin + home-manager modules with declarative `settings`
- ✅ [+] Per-app overrides (ignore, scan depth, labels-only), **new:** editable in Settings → Apps; add installed apps, not just running ones
- ✅ [+] **new** Presets (`preset = "homerow" | "shortcat" | "vimium" | "mouseless" | "scoot"`) and `pounce import <tool>`, in Settings and the welcome window
- ✅ [+] **new** Shortcut conflict warnings (macOS + known apps); Secure Input status in the menu and Settings
- ✅ [+] **new** Update check (automatic toggle + Check Now; menu bar "Update to …" item)
- ✅ [+] **new** `pounce status`; pause from the CLI updates the menu bar icon
- ✅ [+] CLI + `pounce://` URL scheme; launch at login
- ✅ [+] 3-page onboarding (setup-assistant style): live Accessibility status with auto-advance, in-window "Try It" practice buttons, summary with login item + Screen Recording + preset / import. **New:** closing it counts as done; "turn it off and on again" help on the Allow page
- ✅ [+] Native Settings (NavigationSplitView + grouped Forms): sidebar search, live hint-label preview, shortcut recorder with restore-default + clash warning, per-page Restore Defaults, Reset All, read-only Nix notice
- ✅ [+] Cheat Sheet window with toolbar search (menu bar, Settings toolbar)
- ✅ [+] Menu bar menu: Accessibility fix item / paused header, every mode with its native key equivalent, Pause, Cheat Sheet, Settings, Quit. **New:** Secure Input notice, Update item, Repeat Last
- ✅ [+] macOS 26 look: Liquid Glass buttons (bordered fallback on 14–15), new app icon + matching menu bar glyph
- ✅ [+] Esc closes Pounce windows
- ✅ [+] Built-in self-test; `pounce snapshot` UI renderer
- ⬜ Stable code signing (Accessibility grant survives rebuilds)
- ⬜ Windows on other Spaces
