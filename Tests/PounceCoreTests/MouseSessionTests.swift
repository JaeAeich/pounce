import Testing

@testable import PounceCore

@Suite struct MouseSessionTests {
    @Test func holdMovesWithEaseIn() {
        var m = MouseSession()
        #expect(m.keyDown(.char("l")) == [.update])
        #expect(m.isMoving)
        let first = m.step(dt: 0.01)
        #expect(first.dx > 0 && first.dy == 0)
        // After the ramp, steps are faster than the first one.
        for _ in 0..<40 { _ = m.step(dt: 0.01) }
        let late = m.step(dt: 0.01)
        #expect(late.dx > first.dx * 5)
        #expect(abs(late.dx - m.tuning.speed * 0.01) < 1e-6)  // at top speed
        #expect(m.keyUp(.char("l")) == [.update])
        #expect(!m.isMoving)
        #expect(m.step(dt: 0.01) == (0, 0))
    }

    @Test func speedTiers() {
        let t = MouseSession.Tuning()
        #expect(t.speed(after: 0, .normal) == t.speed * t.startFraction)
        #expect(t.speed(after: 10, .fast) == t.fastSpeed)
        #expect(t.speed(after: 10, .slow) == t.slowSpeed)
        #expect(t.speed(after: t.ramp / 2, .normal) < t.speed(after: t.ramp, .normal))
    }

    @Test func diagonalAndShiftedKeys() {
        var m = MouseSession()
        _ = m.keyDown(.char("J"))  // shift held: same direction
        _ = m.keyDown(.char("h"))
        let d = m.step(dt: 0.02)
        #expect(d.dx < 0 && d.dy > 0)
        _ = m.keyUp(.char("j"))
        #expect(m.held.keys.contains(.left) && !m.held.keys.contains(.down))
    }

    @Test func clicks() {
        var m = MouseSession()
        #expect(m.keyDown(.space([])) == [.click(.left, count: 1, modifiers: [])])
        #expect(m.keyDown(.space(.shift)) == [.click(.left, count: 1, modifiers: [])])
        #expect(m.keyDown(.returnKey([])) == [.click(.left, count: 1, modifiers: [])])
        #expect(m.keyDown(.returnKey(.command)) == [.click(.left, count: 1, modifiers: .command)])
        #expect(m.keyDown(.returnKey(.shift)) == [.click(.right, count: 1, modifiers: [])])
        #expect(m.keyDown(.char("r")) == [.click(.right, count: 1, modifiers: [])])
        #expect(m.keyDown(.char("m")) == [.click(.middle, count: 1, modifiers: [])])
        #expect(m.keyDown(.char("c")) == [.click(.left, count: 2, modifiers: [])])
        #expect(m.keyDown(.returnKey(.control)) == [.click(.left, count: 2, modifiers: [])])
        #expect(m.keyDown(.char("[")) == [.click(.back, count: 1, modifiers: [])])
        #expect(m.keyDown(.char("]")) == [.click(.forward, count: 1, modifiers: [])])
    }

    @Test func dragToggle() {
        var m = MouseSession()
        #expect(m.keyDown(.char("v")) == [.dragBegin, .update])
        #expect(m.dragging)
        #expect(m.keyDown(.char("v")) == [.dragEnd, .update])
        _ = m.keyDown(.char("v"))
        #expect(m.keyDown(.space([])) == [.dragEnd, .update])  // click drops
        _ = m.keyDown(.char("v"))
        #expect(m.keyDown(.char("r")) == [.dragEnd, .click(.right, count: 1, modifiers: [])])
        _ = m.keyDown(.char("v"))
        #expect(m.keyDown(.escape) == [.dragEnd, .exit])
        #expect(m.keyDown(.escape) == [.exit])
    }

    @Test func nudgeAndScroll() {
        var m = MouseSession()
        #expect(m.keyDown(.arrow(.left, [])) == [.nudge(dx: -1, dy: 0)])
        #expect(m.keyDown(.arrow(.down, .shift)) == [.nudge(dx: 0, dy: 10)])
        #expect(m.keyDown(.char("d")) == [.scrollStart(down: true)])
        #expect(m.keyDown(.char("d")) == [])  // repeat
        #expect(m.keyUp(.char("d")) == [.scrollStop(down: true)])
        #expect(m.keyDown(.char("u")) == [.scrollStart(down: false)])
        #expect(m.keyUp(.char("u")) == [.scrollStop(down: false)])
    }

    @Test func customKeysAndRelease() {
        var m = MouseSession(keys: "jkil")
        _ = m.keyDown(.char("i"))
        #expect(m.step(dt: 0.01).dy < 0)
        m.releaseAll()
        #expect(!m.isMoving)
        let bad = MouseSession(keys: "aab")
        var b = bad
        _ = b.keyDown(.char("h"))
        #expect(b.isMoving)
    }
}
