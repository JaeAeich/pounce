import Testing

@testable import PounceCore

@Suite struct ConfigTests {
    @Test func defaultRoundtrip() throws {
        let (c, w) = try Config.parse(Config().toTOML())
        #expect(w.isEmpty)
        #expect(c == Config())
    }

    @Test func emptyIsDefault() throws {
        let (c, w) = try Config.parse("")
        #expect(w.isEmpty)
        #expect(c == Config())
    }

    @Test func customRoundtrip() throws {
        var c = Config()
        c.shortcuts.hint = "tap:rcmd"
        c.shortcuts.menu = "none"
        c.hints.alphabet = "fjdk"
        c.hints.labelsOnly = true
        c.hints.sources = [.dock, .window]
        c.hints.theme = .vimium
        c.hints.size = 15.5
        c.scroll.speed = 1234
        c.scroll.keys = "asdf"
        c.general.ignoredApps = ["com.a", "com.b \"quoted\""]
        c.apps["com.foo.bar"] = .init(ignore: true, scan: .exhaustive, labelsOnly: false)
        c.apps["org.empty"] = .init()
        c.apps["x"] = .init(scan: .fast)
        let (d, w) = try Config.parse(c.toTOML())
        #expect(w.isEmpty)
        #expect(d == c)
    }

    @Test func overrides() throws {
        let (c, w) = try Config.parse(
            """
            [shortcuts]
            hint = "hyper+f"
            [hints]
            alphabet = "qwerty"
            auto_click = false
            sources = ["Window", "dock"]
            scan = "Exhaustive"
            size = 20
            [scroll]
            dash_speed = 5000
            [grid]
            keys = "qweasdzxc"
            [general]
            hyper_key = true
            ignored_apps = ["com.x"]
            """)
        #expect(w.isEmpty)
        #expect(c.shortcuts.hint == "hyper+f")
        #expect(c.shortcuts.scroll == Config.Shortcuts().scroll)
        #expect(c.hints.alphabet == "qwerty")
        #expect(c.hints.autoClick == false)
        #expect(c.hints.sources == [.window, .dock])
        #expect(c.hints.scan == .exhaustive)
        #expect(c.hints.size == 20)
        #expect(c.scroll.dashSpeed == 5000)
        #expect(c.scroll.speed == 900)
        #expect(c.grid.keys == "qweasdzxc")
        #expect(c.general.hyperKey)
        #expect(c.general.ignoredApps == ["com.x"])
    }

    @Test func prewarmToggle() throws {
        #expect(Config().general.prewarm)
        let (c, w) = try Config.parse("[general]\nprewarm = false\n")
        #expect(w.isEmpty)
        #expect(c.general.prewarm == false)
        #expect(try Config.parse(c.toTOML()).0 == c)
    }

    @Test func unknownKeysWarn() throws {
        let (c, w) = try Config.parse(
            """
            top = 1
            [hints]
            alphabett = "x"
            [nope]
            a = 1
            """)
        #expect(c == Config())
        #expect(w.contains("unknown key 'top'"))
        #expect(w.contains("unknown key 'hints.alphabett'"))
        #expect(w.contains("unknown key 'nope'"))
        #expect(w.count == 3)
    }

    @Test func badValuesWarnAndKeepDefaults() throws {
        let (c, w) = try Config.parse(
            """
            [shortcuts]
            hint = "cmd+bogus"
            grid = 5
            [hints]
            alphabet = "aaaa"
            labels_only = "yes"
            sources = ["window", "moon"]
            scan = "slow"
            size = 100
            theme = 3
            [scroll]
            speed = "fast"
            keys = "hjk"
            [grid]
            keys = "abc"
            [general]
            ignored_apps = [1, 2]
            """)
        let d = Config()
        #expect(c.shortcuts.hint == d.shortcuts.hint)
        #expect(c.shortcuts.grid == d.shortcuts.grid)
        #expect(c.hints.alphabet == d.hints.alphabet)
        #expect(c.hints.labelsOnly == d.hints.labelsOnly)
        #expect(c.hints.sources == [.window])  // valid items kept
        #expect(c.hints.scan == d.hints.scan)
        #expect(c.hints.size == d.hints.size)
        #expect(c.hints.theme == d.hints.theme)
        #expect(c.scroll == d.scroll)
        #expect(c.grid == d.grid)
        #expect(c.general == d.general)
        #expect(w.count == 12)
        #expect(w.contains { $0.hasPrefix("shortcuts.hint") && $0.contains("cmd+bogus") })
        #expect(w.contains { $0.hasPrefix("hints.size") })
        #expect(w.contains { $0.hasPrefix("hints.sources") && $0.contains("moon") })
    }

    @Test func sectionNotATable() throws {
        let (c, w) = try Config.parse("hints = 1\napps = 2")
        #expect(c == Config())
        #expect(w.contains("hints: expected a table"))
        #expect(w.contains("apps: expected a table"))
    }

    @Test func noneShortcutAccepted() throws {
        let (c, w) = try Config.parse("[shortcuts]\nmenu = \"none\"\ntext = \"\"\nwindows = \"off\"")
        #expect(w.isEmpty)
        #expect(c.shortcuts.menu == "none")
        #expect(c.shortcuts.text == "")
    }

    @Test func syntaxErrorThrows() {
        #expect(throws: TOMLError.self) { try Config.parse("[hints\n") }
    }

    @Test func appOverrides() throws {
        let (c, w) = try Config.parse(
            """
            [apps."com.foo.bar"]
            ignore = true
            [apps."com.baz"]
            scan = "exhaustive"
            labels_only = true
            [apps."com.bad"]
            scan = "slow"
            ignore = "x"
            other = 1
            [apps]
            plain = 3
            """)
        #expect(c.apps["com.foo.bar"] == .init(ignore: true))
        #expect(c.apps["com.baz"] == .init(scan: .exhaustive, labelsOnly: true))
        #expect(c.apps["com.bad"] == .init())
        #expect(c.apps["plain"] == nil)
        #expect(w.contains("apps.plain: expected a table"))
        #expect(w.contains("unknown key 'apps.com.bad.other'"))
        #expect(w.count == 4)
    }

    @Test func helpers() {
        var c = Config()
        c.general.ignoredApps = ["com.ignored", "com.unignored"]
        c.hints.scan = .fast
        c.hints.labelsOnly = false
        c.apps["com.unignored"] = .init(ignore: false)
        c.apps["com.app"] = .init(ignore: true, scan: .exhaustive, labelsOnly: true)
        c.apps["com.partial"] = .init(scan: .exhaustive)

        #expect(!c.isIgnored(nil))
        #expect(c.isIgnored("com.ignored"))
        #expect(!c.isIgnored("com.unignored"))
        #expect(c.isIgnored("com.app"))
        #expect(!c.isIgnored("com.partial"))
        #expect(!c.isIgnored("com.other"))

        #expect(c.scanMode(for: nil) == .fast)
        #expect(c.scanMode(for: "com.app") == .exhaustive)
        #expect(c.scanMode(for: "com.partial") == .exhaustive)
        #expect(c.scanMode(for: "com.other") == .fast)

        #expect(!c.labelsOnly(for: nil))
        #expect(c.labelsOnly(for: "com.app"))
        #expect(!c.labelsOnly(for: "com.partial"))
        c.hints.labelsOnly = true
        #expect(c.labelsOnly(for: "com.partial"))
        #expect(c.labelsOnly(for: "com.other"))
    }

    @Test func defaultShortcutsParse() {
        let s = Config.Shortcuts()
        for raw in [s.hint, s.scroll, s.grid, s.windows, s.menu, s.text] { #expect(Shortcut.parse(raw) != nil, "\(raw)") }
    }

    @Test func afterClickAndClickChainAlias() throws {
        #expect(try Config.parse("[hints]\nclick_chain = true").0.hints.afterClick == .stay)
        #expect(try Config.parse("[hints]\nafter_click = \"scroll\"").0.hints.afterClick == .scroll)
        let (c, w) = try Config.parse("[hints]\nclick_chain = true\nafter_click = \"exit\"")
        #expect(w.isEmpty && c.hints.afterClick == .exit && !c.hints.clickChain)
        #expect(try Config.parse("[hints]\nafter_click = \"nope\"").1.count == 1)
    }

    @Test func modeOptionsRoundtrip() throws {
        var c = Config()
        c.shortcuts.mouse = "hyper+m"
        c.shortcuts.repeat = "ctrl+opt+r"
        c.grid.style = .twokey
        c.grid.labels = "asdfghjkl"
        c.mouse.keys = "jkil"
        c.mouse.speed = 999
        c.mouse.acceleration = 0.5
        c.hints.afterClick = .scroll
        let (d, w) = try Config.parse(c.toTOML())
        #expect(w.isEmpty)
        #expect(d == c)
        #expect(Config().mouse.resolvedKeys(scroll: Config.Scroll()) == "hjkl")
        #expect(try Config.parse("[mouse]\nkeys = \"ab\"").1.count == 1)
        #expect(try Config.parse("[grid]\nstyle = \"twokey\"").0.grid.style == .twokey)
    }
}
