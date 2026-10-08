import Testing

@testable import PounceCore

@Suite struct ScrollSessionTests {
    @Test func hjklStartStop() {
        var s = ScrollSession(areaCount: 1)
        #expect(s.keyDown(.char("h")) == [.start(.left, dash: false)])
        #expect(s.keyDown(.char("j")) == [.start(.down, dash: false)])
        #expect(s.keyDown(.char("k")) == [.start(.up, dash: false)])
        #expect(s.keyDown(.char("l")) == [.start(.right, dash: false)])
        #expect(s.keyUp(.char("j")) == [.stop(.down)])
        #expect(s.keyUp(.char("j")) == [])  // already released
        #expect(s.keyUp(.char("x")) == [])
        #expect(s.keyUp(.escape) == [])
    }

    @Test func shiftDash() {
        var s = ScrollSession(areaCount: 1)
        #expect(s.keyDown(.char("J")) == [.start(.down, dash: true)])
        #expect(s.keyUp(.char("j")) == [.stop(.down)])  // Shift released first
        _ = s.keyDown(.char("k"))
        #expect(s.keyUp(.char("K")) == [.stop(.up)])
    }

    @Test func vectors() {
        #expect(ScrollDirection.left.vector == (-1, 0))
        #expect(ScrollDirection.right.vector == (1, 0))
        #expect(ScrollDirection.up.vector == (0, -1))
        #expect(ScrollDirection.down.vector == (0, 1))
    }

    @Test func edges() {
        var s = ScrollSession(areaCount: 1)
        #expect(s.keyDown(.char("g")) == [])
        #expect(s.keyDown(.char("g")) == [.edge(top: true)])
        #expect(s.keyDown(.char("g")) == [])  // gg consumed; new sequence
        #expect(s.keyDown(.char("j")) == [.start(.down, dash: false)])
        #expect(s.keyDown(.char("g")) == [])  // interrupted g doesn't combine
        #expect(s.keyDown(.char("G")) == [.edge(top: false)])
        #expect(s.keyDown(.char("g")) == [])
    }

    @Test func halfPages() {
        var s = ScrollSession(areaCount: 1)
        #expect(s.keyDown(.char("d")) == [.halfPage(down: true)])
        #expect(s.keyDown(.char("u")) == [.halfPage(down: false)])
        #expect(s.keyDown(.control("d")) == [.halfPage(down: true)])
        #expect(s.keyDown(.control("u")) == [.halfPage(down: false)])
    }

    @Test func digitsSelect() {
        var s = ScrollSession(areaCount: 3)
        #expect(s.keyDown(.char("2")) == [.select(1)])
        #expect(s.selected == 1)
        #expect(s.keyDown(.char("3")) == [.select(2)])
        #expect(s.keyDown(.char("4")) == [.warn])
        #expect(s.selected == 2)
        #expect(s.keyDown(.char("0")) == [.warn])  // 0 = 10th
        var ten = ScrollSession(areaCount: 10)
        #expect(ten.keyDown(.char("0")) == [.select(9)])
        #expect(ten.keyDown(.char("1")) == [.select(0)])
        var none = ScrollSession(areaCount: 0)
        #expect(none.keyDown(.char("1")) == [.warn])
    }

    @Test func tabCycling() {
        var s = ScrollSession(areaCount: 3)
        #expect(s.keyDown(.tab(backward: false)) == [.select(1)])
        #expect(s.keyDown(.tab(backward: false)) == [.select(2)])
        #expect(s.keyDown(.tab(backward: false)) == [.select(0)])
        #expect(s.keyDown(.tab(backward: true)) == [.select(2)])
        #expect(s.keyDown(.arrow(.down, [])) == [.select(0)])
        #expect(s.keyDown(.arrow(.up, [])) == [.select(2)])
        #expect(s.keyDown(.control("n")) == [.select(0)])
        #expect(s.keyDown(.control("p")) == [.select(2)])
        var one = ScrollSession(areaCount: 1)
        #expect(one.keyDown(.tab(backward: false)) == [.warn])
    }

    @Test func initClampsSelected() {
        #expect(ScrollSession(areaCount: 3, selected: 7).selected == 2)
        #expect(ScrollSession(areaCount: 3, selected: -1).selected == 0)
        #expect(ScrollSession(areaCount: 0, selected: 4).selected == 0)
    }

    @Test func escapeAndIgnored() {
        var s = ScrollSession(areaCount: 1)
        #expect(s.keyDown(.escape) == [.exit])
        #expect(s.keyDown(.char("x")) == [])
        #expect(s.keyDown(.returnKey([])) == [])
        #expect(s.keyDown(.arrow(.left, [])) == [])
    }

    @Test func customKeys() {
        var s = ScrollSession(areaCount: 1, keys: "ASDF")
        #expect(s.keyDown(.char("a")) == [.start(.left, dash: false)])
        #expect(s.keyDown(.char("s")) == [.start(.down, dash: false)])
        #expect(s.keyDown(.char("d")) == [.start(.up, dash: false)])  // scroll key wins over half-page
        #expect(s.keyDown(.char("F")) == [.start(.right, dash: true)])
        #expect(s.keyDown(.char("h")) == [])
        #expect(s.keyUp(.char("f")) == [.stop(.right)])
    }

    @Test func invalidCustomKeysFallBack() {
        var s = ScrollSession(areaCount: 1, keys: "ab")
        #expect(s.keyDown(.char("h")) == [.start(.left, dash: false)])
        #expect(s.keyDown(.char("a")) == [])
    }
}
