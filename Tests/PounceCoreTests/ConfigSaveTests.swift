import Testing

@testable import PounceCore

@Suite struct TOMLDocumentTests {
    @Test func setInPlaceKeepsComment() throws {
        var d = try TOMLDocument("# top\n[hints]\nalphabet = \"abc\"  # mine\n")
        d.set(["hints", "alphabet"], .string("xyz"))
        #expect(d.text == "# top\n[hints]\nalphabet = \"xyz\"  # mine\n")
    }

    @Test func insertIntoExistingAndNewTable() throws {
        var d = try TOMLDocument("[hints]\nsize = 14\n\n[scroll]\nkeys = \"hjkl\"\n")
        d.set(["hints", "theme"], .string("dark"))
        d.set(["grid", "keys"], .string("qweasdzxc"))
        #expect(d.text == "[hints]\nsize = 14\ntheme = \"dark\"\n\n[scroll]\nkeys = \"hjkl\"\n\n[grid]\nkeys = \"qweasdzxc\"\n")
        #expect(try TOML.parse(d.text)["grid"]?.table?["keys"] == .string("qweasdzxc"))
    }

    @Test func removeDropsEmptyTable() throws {
        var d = try TOMLDocument("[hints]\nsize = 14\n\n[apps.\"com.x\"]\nignore = true\n")
        d.remove(["apps", "com.x", "ignore"])
        #expect(d.text == "[hints]\nsize = 14\n")
        d.remove(["hints", "size"])
        #expect(d.text == "")
    }

    @Test func removeKeepsCommentedTable() throws {
        var d = try TOMLDocument("[hints]  # click mode\nsize = 14\n")
        d.remove(["hints", "size"])
        #expect(d.text == "[hints]  # click mode\n")
    }

    @Test func syntaxErrorThrows() {
        #expect(throws: TOMLError.self) { try TOMLDocument("[hints\n") }
    }

    @Test func equivalence() {
        #expect(TOML.equivalent(.int(20), .double(20)))
        #expect(!TOML.equivalent(.string("a"), .string("A")))
        #expect(TOML.equivalent(.array([.int(1)]), .array([.double(1)])))
    }
}

@Suite struct ConfigSaveTests {
    @Test func newFileHasOnlyOverrides() throws {
        var c = Config()
        c.hints.alphabet = "fjdk"
        let text = try c.savedText(previous: Config(), existing: nil)
        #expect(text.contains("alphabet = \"fjdk\""))
        #expect(!text.contains("auto_click"))
        #expect(!text.contains("[scroll]"))
        #expect(try Config.parse(text).0 == c)
    }

    @Test func defaultsWriteHeaderOnly() throws {
        let text = Config().overridesTOML()
        #expect(try Config.parse(text).0 == Config())
        #expect(try TOMLDocument(text).entries.isEmpty)
    }

    @Test func editPreservesCommentsAndOrdering() throws {
        let file = """
            # My Pounce setup
            [general]
            sounds = false  # quiet please

            # click mode
            [hints]
            size = 14
            alphabet = "fjdk"
            """
        let (prev, _) = try Config.parse(file)
        var c = prev
        c.hints.size = 16
        c.scroll.speed = 1200
        c.hints.alphabet = Config().hints.alphabet  // back to default → line removed
        let out = try c.savedText(previous: prev, existing: file)
        #expect(
            out == """
                # My Pounce setup
                [general]
                sounds = false  # quiet please

                # click mode
                [hints]
                size = 16.0

                [scroll]
                speed = 1200.0

                """)
        #expect(try Config.parse(out).0 == c)
    }

    @Test func untouchedExplicitDefaultsStay() throws {
        let file = "[hints]\nauto_click = true\n"
        let (prev, _) = try Config.parse(file)
        var c = prev
        c.hints.size = 20
        let out = try c.savedText(previous: prev, existing: file)
        #expect(out == "[hints]\nauto_click = true\nsize = 20.0\n")
    }

    @Test func refusesBrokenFile() {
        #expect(throws: TOMLError.self) { try Config().savedText(previous: Config(), existing: "[hints\nsize = ") }
    }

    @Test func appOverrides() throws {
        var c = Config()
        c.apps["com.foo.bar"] = .init(ignore: true)
        let out = try c.savedText(previous: Config(), existing: "# hi\n")
        #expect(out.contains("[apps.\"com.foo.bar\"]\nignore = true"))
        #expect(try Config.parse(out).0 == c)
        var d = c
        d.apps = [:]
        #expect(try d.savedText(previous: c, existing: out) == "# hi\n")
    }

    @Test func presetChangeRewritesAgainstNewBaseline() throws {
        let file = "# keep\n[hints]\nsize = 14\n"
        let (prev, _) = try Config.parse(file)
        let c = prev.withPreset(.vimium)
        #expect(c.hints.labelsOnly && c.hints.size == 14 && c.general.preset == .vimium)
        let out = try c.savedText(previous: prev, existing: file)
        #expect(out == "# keep\n[hints]\nsize = 14\n\n[general]\npreset = \"vimium\"\n")
        #expect(try Config.parse(out).0 == c)
        // And back: preset key goes, overrides stay.
        let h = c.withPreset(.homerow)
        #expect(h.hints.labelsOnly == false && h.hints.size == 14)
        #expect(try h.savedText(previous: c, existing: out) == "# keep\n[hints]\nsize = 14\n")
    }
}

@Suite struct PresetTests {
    @Test func homerowIsDefault() {
        #expect(Preset.homerow.baseline == Config())
    }

    @Test func presetIsBaselineKeysOverride() throws {
        let (c, w) = try Config.parse("[general]\npreset = \"vimium\"\n[hints]\nalphabet = \"qwer\"\n")
        #expect(w.isEmpty)
        #expect(c.hints.labelsOnly)
        #expect(c.hints.theme == .vimium)
        #expect(c.hints.alphabet == "qwer")
    }

    @Test func badPresetWarns() throws {
        let (c, w) = try Config.parse("[general]\npreset = \"nope\"\n")
        #expect(c == Config())
        #expect(w.count == 1 && w[0].contains("general.preset"))
    }

    @Test func everyPresetRoundTripsAndParses() throws {
        for p in Preset.allCases {
            let b = p.baseline
            #expect(try Config.parse(b.toTOML()).0 == b, "\(p)")
            #expect(try Config.parse(b.overridesTOML()).0 == b, "\(p)")
            #expect(try Config.parse(b.overridesTOML()).1.isEmpty, "\(p)")
            #expect(b.overrides().count == (p == .homerow ? 0 : 1), "\(p): only the preset key differs")
            for s in [b.shortcuts.hint, b.shortcuts.grid, b.shortcuts.scroll] { #expect(Shortcut.parse(s) != nil) }
        }
        #expect(Preset.scoot.baseline.shortcuts.hint == "cmd+shift+j")
        #expect(Preset.scoot.baseline.shortcuts.grid == "cmd+shift+k")
        #expect(Preset.vimium.baseline.hints.alphabet == "sadfjklewcmpgh")
    }
}

@Suite struct ImporterTests {
    @Test func vimium() throws {
        let json = #"{"linkHintCharacters":"SADFJKL","filterLinkHints":false,"scrollStepSize":60,"exclusionRules":[]}"#
        let r = try Importers.run(.vimium, text: json, onto: Config())
        #expect(r.config.general.preset == .vimium)
        #expect(r.config.hints.alphabet == "sadfjkl")
        #expect(r.config.hints.labelsOnly)
        #expect(r.changes.contains { $0.key == "hints.alphabet" && $0.source == "linkHintCharacters" })
        #expect(r.unmapped.contains { $0.hasPrefix("scrollStepSize") })
    }

    @Test func vimiumFilterMode() throws {
        let r = try Importers.run(.vimium, text: #"{"filterLinkHints":true,"linkHintNumbers":"0123456789"}"#, onto: Config())
        #expect(!r.config.hints.labelsOnly)
        #expect(r.config.hints.alphabet == "0123456789")
    }

    @Test func badJSONThrows() {
        #expect(throws: (any Error).self) { try Importers.run(.vimium, text: "nope", onto: Config()) }
    }

    static let homerowPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>KeyboardShortcuts_search</key><string>{"carbonModifiers":768,"carbonKeyCode":49}</string>
          <key>KeyboardShortcuts_nonSearch</key><string>{"carbonModifiers":4096,"carbonKeyCode":3}</string>
          <key>scroll-shortcut</key><string>⌃⌥J</string>
          <key>label-characters</key><string>ASDFJKL</string>
          <key>scroll-speed</key><integer>3</integer>
          <key>theme-id</key><string>dark</string>
          <key>ignored-bundle-ids</key><array><string>com.apple.Terminal</string><string>not an id</string></array>
          <key>NSWindow Frame Settings</key><string>1 2 3 4</string>
          <key>SUEnableAutomaticChecks</key><true/>
          <key>mystery</key><integer>7</integer>
        </dict></plist>
        """

    @Test func homerowHeuristics() throws {
        let r = try Importers.run(.homerow, text: Self.homerowPlist, onto: Config())
        let c = r.config
        #expect(c.general.preset == .homerow)
        #expect(c.shortcuts.hint == "shift+cmd+space" || c.shortcuts.hint == Shortcut.parse("cmd+shift+space")!.description)
        #expect(c.shortcuts.scroll == "ctrl+opt+j")
        #expect(c.hints.alphabet == "asdfjkl")
        #expect(c.hints.theme == .dark)
        #expect(c.general.ignoredApps == ["com.apple.Terminal"])
        #expect(c.scroll.speed == Config().scroll.speed)
        #expect(r.unmapped.contains { $0.hasPrefix("scroll-speed") })
        #expect(r.unmapped.contains { $0.hasPrefix("mystery") })
        #expect(r.unmapped.contains { $0.contains("KeyboardShortcuts_nonSearch") })
        #expect(!r.unmapped.contains { $0.contains("NSWindow") })
    }

    @Test func emptyPlistThrows() {
        let empty = #"<?xml version="1.0"?><plist version="1.0"><dict/></plist>"#
        #expect(throws: (any Error).self) { try Importers.run(.shortcat, text: empty, onto: Config()) }
    }

    @Test func shortcutEncodings() {
        #expect(
            Importers.shortcutString(#"{"carbonKeyCode":49,"carbonModifiers":768}"#)
                == KeyChord(keyCode: 49, modifiers: [.command, .shift]).description)
        #expect(Importers.shortcutString(["keyCode": 38, "modifierFlags": 1 << 20 | 1 << 19] as [String: Any]) == "opt+cmd+j")
        #expect(Importers.shortcutString("⌘⇧Space") == KeyChord(keyCode: 49, modifiers: [.command, .shift]).description)
        #expect(Importers.shortcutString("tap:rcmd") == "tap:rcmd")
        #expect(Importers.shortcutString("garbage!!") == nil)
    }

    @Test func mouselessYAML() throws {
        let yaml = """
            # Mouseless config
            activation_shortcut: "ctrl+space"
            overlay:
              characters: 'qwerasdf'   # grid keys
              theme: Dark
            scroll:
              speed: 1500
            excluded_apps:
              - com.apple.Safari
              - com.example.app
            unknown_flag: yes
            """
        let pairs = Importers.yamlPairs(yaml)
        #expect(pairs.contains { $0.0 == "overlay.characters" && ($0.1 as? String) == "qwerasdf" })
        #expect(pairs.contains { $0.0 == "excluded_apps" && ($0.1 as? [String]) == ["com.apple.Safari", "com.example.app"] })
        let r = try Importers.run(.mouseless, text: yaml, onto: Config())
        #expect(r.config.general.preset == .mouseless)
        #expect(r.config.shortcuts.hint == "ctrl+space")
        #expect(r.config.hints.alphabet == "qwerasdf")
        #expect(r.config.hints.theme == .dark)
        #expect(r.config.scroll.speed == 1500)
        #expect(r.config.general.ignoredApps == ["com.apple.Safari", "com.example.app"])
        #expect(r.unmapped.contains { $0.hasPrefix("unknown_flag") })
    }

    @Test func invalidValuesRejected() {
        let a = [Importers.Assignment(path: ["hints", "alphabet"], value: .string("a"), source: "x")]
        let r = Importers.apply(a, onto: Config())
        #expect(r.config == Config())
        #expect(r.changes.isEmpty)
        #expect(r.unmapped.contains { $0.contains("hints.alphabet") })
    }
}
