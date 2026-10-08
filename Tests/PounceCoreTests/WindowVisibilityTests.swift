import Testing

@testable import PounceCore

@Suite struct WindowVisibilityTests {
    let screen = Rect(x: 0, y: 0, width: 1800, height: 1169)

    @Test func aerospaceParkedWindowIsHidden() {
        // AeroSpace leaves ~1 px of hidden-workspace windows at the bottom-right corner.
        #expect(!WindowVisibility.isVisible(Rect(x: 1799, y: 1130, width: 1800, height: 1129), screens: [screen]))
        #expect(!WindowVisibility.isVisible(Rect(x: 1700, y: 1100, width: 1800, height: 1129), screens: [screen]))
    }

    @Test func mostlyOnScreenIsVisible() {
        #expect(WindowVisibility.isVisible(Rect(x: 0, y: 39, width: 1800, height: 1129), screens: [screen]))
        #expect(WindowVisibility.isVisible(Rect(x: 1500, y: 100, width: 800, height: 600), screens: [screen]))  // 300/800 on screen
    }

    @Test func smallSliverIsHidden() {
        // 10% of the window but under 40 pt wide.
        #expect(!WindowVisibility.isVisible(Rect(x: 1770, y: 100, width: 300, height: 600), screens: [screen]))
        #expect(!WindowVisibility.isVisible(Rect(x: 0, y: 0, width: 0, height: 0), screens: [screen]))
    }

    @Test func secondScreen() {
        let right = Rect(x: 1800, y: 0, width: 1920, height: 1080)
        #expect(WindowVisibility.isVisible(Rect(x: 2000, y: 100, width: 800, height: 600), screens: [screen, right]))
        // Split across two screens: each part judged on its own screen.
        #expect(WindowVisibility.visiblePart(Rect(x: 1700, y: 0, width: 400, height: 100), screens: [screen, right]).width == 300)
    }

    @Test func badgeCollisions() {
        let full = Rect(x: 0, y: 39, width: 1800, height: 1129)
        #expect(WindowVisibility.badgesCollide([full, full], size: (280, 100)))
        #expect(
            !WindowVisibility.badgesCollide(
                [Rect(x: 0, y: 39, width: 900, height: 1129), Rect(x: 900, y: 39, width: 900, height: 1129)], size: (280, 100)))
        #expect(!WindowVisibility.badgesCollide([full], size: (280, 100)))
    }

    @Test func ocrLanguages() {
        let supported = ["en-US", "fr-FR", "de-DE", "zh-Hans", "zh-Hant", "pt-BR", "ja-JP"]
        #expect(OCRLanguages.pick(preferred: ["de-CH", "en-GB"], supported: supported) == ["de-DE", "en-US"])
        #expect(OCRLanguages.pick(preferred: ["zh-Hant-TW"], supported: supported) == ["zh-Hant", "en-US"])
        #expect(OCRLanguages.pick(preferred: ["zh-HK"], supported: supported) == ["zh-Hant", "en-US"])
        #expect(OCRLanguages.pick(preferred: ["hi-IN", "fr-CA"], supported: supported) == ["fr-FR", "en-US"])
        #expect(OCRLanguages.pick(preferred: [], supported: supported) == ["en-US"])
    }

    @Test func hintScopeConfig() throws {
        #expect(try Config.parse("[hints]\nscope = \"all\"").0.hints.scope == .all)
        #expect(Config().hints.scope == .window)
        let (c, warnings) = try Config.parse("[hints]\nscope = \"everywhere\"")
        #expect(c.hints.scope == .window && !warnings.isEmpty)
    }
}
