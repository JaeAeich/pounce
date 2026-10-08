import Testing

@testable import PounceCore

@Suite struct GeometryTests {
    @Test func topLeftFrame() {
        let f = Geometry.topLeftFrame(ofCocoa: Rect(x: 10, y: 0, width: 100, height: 50), primaryHeight: 1000)
        #expect(f == Rect(x: 10, y: 950, width: 100, height: 50))
        // A screen above the primary has a negative top-left y.
        let above = Geometry.topLeftFrame(ofCocoa: Rect(x: 0, y: 1000, width: 1920, height: 1080), primaryHeight: 1000)
        #expect(above == Rect(x: 0, y: -1080, width: 1920, height: 1080))
        let primary = Geometry.topLeftFrame(ofCocoa: Rect(x: 0, y: 0, width: 1440, height: 1000), primaryHeight: 1000)
        #expect(primary == Rect(x: 0, y: 0, width: 1440, height: 1000))
    }

    @Test func local() {
        let r = Geometry.local(
            Rect(x: 1500, y: -500, width: 20, height: 10), inScreenTopLeft: Rect(x: 1440, y: -1080, width: 1920, height: 1080))
        #expect(r == Rect(x: 60, y: 580, width: 20, height: 10))
    }

    @Test func labelOriginLargeElement() {
        let p = Geometry.labelOrigin(
            for: Rect(x: 100, y: 100, width: 200, height: 100), size: (20, 14), bounds: Rect(x: 0, y: 0, width: 1000, height: 1000))
        #expect(p == Point(x: 90, y: 102))  // straddles the left edge, top-aligned when tall
    }

    @Test func labelOriginSmallElementCentered() {
        let p = Geometry.labelOrigin(
            for: Rect(x: 100, y: 100, width: 30, height: 20), size: (20, 14), bounds: Rect(x: 0, y: 0, width: 1000, height: 1000))
        #expect(p == Point(x: 105, y: 103))
    }

    @Test func labelOriginClamped() {
        let b = Rect(x: 0, y: 0, width: 500, height: 400)
        let tl = Geometry.labelOrigin(for: Rect(x: -5, y: -5, width: 10, height: 10), size: (20, 14), bounds: b)
        #expect(tl == Point(x: 0, y: 0))
        let br = Geometry.labelOrigin(for: Rect(x: 495, y: 395, width: 10, height: 10), size: (20, 14), bounds: b)
        #expect(br == Point(x: 480, y: 386))
        let offset = Geometry.labelOrigin(
            for: Rect(x: 0, y: 0, width: 10, height: 10), size: (20, 14), bounds: Rect(x: 100, y: 50, width: 500, height: 400))
        #expect(offset == Point(x: 100, y: 50))
    }

    @Test func intersection() {
        let a = Rect(x: 0, y: 0, width: 100, height: 100)
        #expect(a.intersection(Rect(x: 50, y: 25, width: 100, height: 50)) == Rect(x: 50, y: 25, width: 50, height: 50))
        #expect(a.intersection(Rect(x: 10, y: 10, width: 5, height: 5)) == Rect(x: 10, y: 10, width: 5, height: 5))
        #expect(a.intersection(Rect(x: 100, y: 0, width: 10, height: 10)) == .zero)  // touching edge
        #expect(a.intersection(Rect(x: 200, y: 200, width: 10, height: 10)) == .zero)
        #expect(a.intersection(a) == a)
        #expect(a.intersection(.zero).isEmpty)
    }

    @Test func rectBasics() {
        let r = Rect(x: 10, y: 20, width: 30, height: 40)
        #expect(r.midX == 25 && r.midY == 40 && r.maxX == 40 && r.maxY == 60)
        #expect(r.area == 1200)
        #expect(!r.isEmpty)
        #expect(Rect(x: 0, y: 0, width: -5, height: 10).area == 0)
        #expect(Rect(x: 0, y: 0, width: 0, height: 10).isEmpty)
        #expect(r.contains(x: 10, y: 20))
        #expect(!r.contains(x: 40, y: 30))
        #expect(r.description == "(10,20 30×40)")
    }
}
