import Testing

@testable import PounceCore

private let screen = Rect(x: 0, y: 0, width: 900, height: 900)

@Suite struct GridSessionTests {
    @Test func cells() {
        let g = GridSession(bounds: screen)
        #expect(g.cells.count == 9)
        #expect(g.cells[0] == Rect(x: 0, y: 0, width: 300, height: 300))
        #expect(g.cells[4] == Rect(x: 300, y: 300, width: 300, height: 300))
        #expect(g.cells[8] == Rect(x: 600, y: 600, width: 300, height: 300))
        #expect(g.cells[5] == Rect(x: 600, y: 300, width: 300, height: 300))
        #expect(g.center == Point(x: 450, y: 450))
    }

    @Test func narrowing() {
        var g = GridSession(bounds: screen)
        #expect(g.handle(.char("u")) == [.update])
        #expect(g.rect == Rect(x: 0, y: 0, width: 300, height: 300))
        #expect(g.handle(.char(".")) == [.update])
        #expect(g.rect == Rect(x: 200, y: 200, width: 100, height: 100))
        #expect(g.handle(.char("K")) == [.update])  // uppercase works
        #expect(g.rect.x == 200 + 100.0 / 3)
        #expect(g.history.count == 3)
        #expect(g.handle(.char("z")) == [])
        #expect(g.history.count == 3)
    }

    @Test func backspaceUndo() {
        var g = GridSession(bounds: screen)
        #expect(g.handle(.backspace) == [])
        _ = g.handle(.char("o"))
        _ = g.handle(.char("m"))
        #expect(g.handle(.backspace) == [.update])
        #expect(g.rect == Rect(x: 600, y: 0, width: 300, height: 300))
        _ = g.handle(.backspace)
        #expect(g.rect == screen)
        #expect(g.history.isEmpty)
    }

    @Test func minCellSize() {
        var g = GridSession(bounds: Rect(x: 0, y: 0, width: 54, height: 54))
        #expect(g.handle(.char("u")) == [.update])  // 54/3 = 18 ≥ 6
        #expect(g.handle(.char("u")) == [.update])  // 18/3 = 6 ≥ 6
        #expect(g.handle(.char("u")) == [.warn])  // 6/3 = 2 < 6
        #expect(g.rect.width == 6)
        var thin = GridSession(bounds: Rect(x: 0, y: 0, width: 900, height: 12))
        #expect(thin.handle(.char("u")) == [.warn])
    }

    @Test(arguments: [
        (Modifiers(), HintAction.click),
        (Modifiers.shift, HintAction.rightClick),
        (Modifiers.command, HintAction.commandClick),
        (Modifiers.option, HintAction.optionClick),
        (Modifiers.control, HintAction.doubleClick),
    ])
    func returnClicksCenter(mods: Modifiers, action: HintAction) {
        var g = GridSession(bounds: screen)
        _ = g.handle(.char("u"))
        #expect(g.handle(.returnKey(mods)) == [.click(Point(x: 150, y: 150), action)])
    }

    @Test func spaceMoves() {
        var g = GridSession(bounds: screen)
        _ = g.handle(.char("."))
        #expect(g.handle(.space([])) == [.move(Point(x: 750, y: 750))])
    }

    @Test func dragFlow() {
        var g = GridSession(bounds: screen)
        _ = g.handle(.char("u"))
        #expect(g.handle(.control("d")) == [.update])
        #expect(g.dragFrom == Point(x: 150, y: 150))
        #expect(g.rect == screen)  // back to full screen to pick destination
        #expect(g.history.isEmpty)
        _ = g.handle(.char("."))
        #expect(g.handle(.returnKey([])) == [.drag(from: Point(x: 150, y: 150), to: Point(x: 750, y: 750))])
        #expect(g.dragFrom == nil)
        #expect(g.handle(.returnKey([])) == [.click(Point(x: 750, y: 750), .click)])
    }

    @Test func dragWithoutNarrowing() {
        var g = GridSession(bounds: screen)
        _ = g.handle(.control("d"))
        #expect(g.dragFrom == Point(x: 450, y: 450))
        #expect(g.rect == screen)
    }

    @Test func escape() {
        var g = GridSession(bounds: screen)
        _ = g.handle(.control("d"))
        #expect(g.handle(.escape) == [.update])
        #expect(g.dragFrom == nil)
        #expect(g.handle(.escape) == [.exit])
    }

    @Test func arrowsNudge() {
        var g = GridSession(bounds: screen)
        _ = g.handle(.char("k"))  // 300,300 300×300
        #expect(g.handle(.arrow(.left, [])) == [.update])
        #expect(g.rect == Rect(x: 150, y: 300, width: 300, height: 300))
        _ = g.handle(.arrow(.right, []))
        _ = g.handle(.arrow(.right, []))
        #expect(g.rect.x == 450)
        _ = g.handle(.arrow(.up, []))
        #expect(g.rect.y == 150)
        _ = g.handle(.arrow(.down, .shift))
        #expect(g.rect.y == 300)
        #expect(g.rect.width == 300 && g.rect.height == 300)
    }

    @Test func tabNextScreenAndReset() {
        var g = GridSession(bounds: screen)
        #expect(g.handle(.tab(backward: false)) == [.nextScreen])
        _ = g.handle(.char("u"))
        let other = Rect(x: 900, y: 0, width: 600, height: 300)
        g.reset(bounds: other)
        #expect(g.rect == other)
        #expect(g.history.isEmpty)
    }

    @Test func customAndInvalidKeys() {
        var g = GridSession(bounds: screen, keys: "qweasdzxc")
        _ = g.handle(.char("c"))
        #expect(g.rect == Rect(x: 600, y: 600, width: 300, height: 300))
        let bad = GridSession(bounds: screen, keys: "abc")
        #expect(bad.keys == Array("uiojklm,."))
    }

    @Test func ignoredInputs() {
        var g = GridSession(bounds: screen)
        #expect(g.handle(.control("x")) == [])
    }
}

@Suite struct TwoKeyGridTests {
    private let wide = Rect(x: 0, y: 0, width: 2600, height: 1300)

    @Test func layout() {
        let g = GridSession(bounds: wide, style: .twokey)
        #expect(g.picking)
        #expect(g.labelGrid.cols == 26 && g.labelGrid.rows == 13)
        #expect(g.labelCells.count == 26 * 13)
        #expect(g.labelCells[0] == GridLabelCell(rect: Rect(x: 0, y: 0, width: 100, height: 100), label: "aa"))
        #expect(g.labelCells[27].label == "bb")
        let tall = GridSession(bounds: Rect(x: 0, y: 0, width: 900, height: 1800), style: .twokey, labelKeys: "abcd")
        #expect(tall.labelGrid.rows == 4 && tall.labelGrid.cols == 2)
    }

    @Test func twoKeysThenRefine() {
        var g = GridSession(bounds: wide, style: .twokey)
        #expect(g.handle(.char("c")) == [.update])
        #expect(g.firstKey == "c")
        #expect(g.handle(.char("E")) == [.update])
        #expect(!g.picking)
        #expect(g.rect == Rect(x: 400, y: 200, width: 100, height: 100))
        #expect(g.handle(.returnKey([])) == [.click(Point(x: 450, y: 250), .click)])
        // 3×3 refinement as usual.
        #expect(g.handle(.char("u")) == [.update])
        #expect(g.rect.width == 100.0 / 3)
        _ = g.handle(.backspace)
        #expect(g.rect == Rect(x: 400, y: 200, width: 100, height: 100))
        _ = g.handle(.backspace)  // back to picking
        #expect(g.picking && g.rect == wide)
    }

    @Test func pickingRejects() {
        var g = GridSession(bounds: wide, style: .twokey)
        #expect(g.handle(.char("z")) == [.warn])  // row 25 doesn't exist (13 rows)
        #expect(g.handle(.returnKey([])) == [.warn])
        #expect(g.handle(.char("1")) == [])
        _ = g.handle(.char("a"))
        #expect(g.handle(.backspace) == [.update])
        #expect(g.firstKey == nil)
        _ = g.handle(.char("a"))
        #expect(g.handle(.escape) == [.update])
        #expect(g.handle(.escape) == [.exit])
        #expect(g.handle(.tab(backward: false)) == [.nextScreen])
    }

    @Test func dragReturnsToPicking() {
        var g = GridSession(bounds: wide, style: .twokey)
        _ = g.handle(.char("a"))
        _ = g.handle(.char("a"))
        #expect(g.handle(.control("d")) == [.update])
        #expect(g.dragFrom == Point(x: 50, y: 50))
        #expect(g.picking)
        _ = g.handle(.char("b"))
        _ = g.handle(.char("b"))
        #expect(g.handle(.returnKey([])) == [.drag(from: Point(x: 50, y: 50), to: Point(x: 150, y: 150))])
    }

    @Test func resetAndRecursiveUnchanged() {
        var g = GridSession(bounds: wide, style: .twokey)
        _ = g.handle(.char("a"))
        _ = g.handle(.char("a"))
        let other = Rect(x: 2600, y: 0, width: 1300, height: 1300)
        g.reset(bounds: other)
        #expect(g.picking && g.rect == other && g.firstKey == nil)
        let r = GridSession(bounds: wide)
        #expect(!r.picking)
    }
}
