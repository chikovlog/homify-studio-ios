import XCTest
@testable import HomifyCore

final class KeyframeTests: XCTestCase {
    let tol = Time.frame(30)

    func testEasingEndpointsAndMonotonic() {
        for e in Easing.allCases where e != .hold {
            XCTAssertEqual(e.apply(0), 0, accuracy: 1e-6)
            XCTAssertEqual(e.apply(1), 1, accuracy: 1e-6)
            var last = -1.0
            for i in 0...20 {
                let v = e.apply(Double(i) / 20)
                XCTAssertGreaterThanOrEqual(v, last - 1e-9, "\(e)")
                last = v
            }
        }
        XCTAssertEqual(Easing.easeInOut.apply(0.5), 0.5, accuracy: 1e-4)
        XCTAssertLessThan(Easing.easeIn.apply(0.25), 0.25)
        XCTAssertGreaterThan(Easing.easeOut.apply(0.25), 0.25)
    }

    func testCubicBezierLinearEquivalent() {
        let b = CubicBezier(1.0 / 3, 1.0 / 3, 2.0 / 3, 2.0 / 3)
        for x in stride(from: 0.0, through: 1.0, by: 0.1) {
            XCTAssertEqual(b.y(forX: x), x, accuracy: 1e-5)
        }
    }

    /// The user's example: 0s → 100 %, 2s → 125 %, 4s → 100 %.
    func testAutoKeyframePinchExample() {
        var s = AnimatedScalar(1)
        s.set(1.25, at: .seconds(2), autoKeyframe: true, tolerance: tol, anchor: .zero)
        s.set(1.0, at: .seconds(4), autoKeyframe: true, tolerance: tol, anchor: .zero)
        XCTAssertEqual(s.keyframes.map(\.time), [.zero, .seconds(2), .seconds(4)])
        XCTAssertEqual(s.value(at: .zero), 1)
        XCTAssertEqual(s.value(at: .seconds(2)), 1.25, accuracy: 1e-9)
        XCTAssertEqual(s.value(at: .seconds(4)), 1)
        XCTAssertEqual(s.value(at: .seconds(1)), 1.125, accuracy: 1e-3) // ease-in-out midpoint
        XCTAssertEqual(s.value(at: .seconds(10)), 1)
    }

    func testAutoKeyframeUpdatesExistingNearby() {
        var s = AnimatedScalar(0)
        s.set(1, at: .seconds(1), autoKeyframe: true, tolerance: tol)
        s.set(2, at: .seconds(1) + Time(value: 100), autoKeyframe: true, tolerance: tol)
        XCTAssertEqual(s.keyframes.count, 1)
        XCTAssertEqual(s.keyframes[0].value, 2)
    }

    func testNoAccidentalKeyframesWhenAutoOff() {
        var s = AnimatedScalar(1)
        s.set(2, at: .seconds(3), autoKeyframe: false, tolerance: tol)
        XCTAssertFalse(s.isAnimated)
        XCTAssertEqual(s.value(at: .seconds(9)), 2)

        // With an existing animation, auto-off offsets the whole curve.
        var a = AnimatedScalar(0, keyframes: [Keyframe(time: .zero, value: 0), Keyframe(time: .seconds(2), value: 10)])
        a.set(15, at: .seconds(2), autoKeyframe: false, tolerance: tol)
        XCTAssertEqual(a.keyframes.count, 2)
        XCTAssertEqual(a.keyframes.map(\.value), [5, 15])
    }

    func testTransformApplyOnlyTouchesChangedProperties() {
        var t = ClipTransform()
        var v = t.value(at: .seconds(1))
        v.scale = 1.5
        t.apply(v, at: .seconds(1), autoKeyframe: true, tolerance: tol)
        XCTAssertTrue(t.scale.isAnimated)
        XCTAssertFalse(t.positionX.isAnimated)
        XCTAssertFalse(t.rotation.isAnimated)
        XCTAssertFalse(t.opacity.isAnimated)
    }

    func testMoveAndDeleteKeyframe() {
        var s = AnimatedScalar(0, keyframes: [Keyframe(time: .zero, value: 0), Keyframe(time: .seconds(2), value: 1)])
        XCTAssertTrue(s.moveKeyframe(from: .seconds(2), to: .seconds(3), tolerance: tol))
        XCTAssertEqual(s.value(at: .seconds(3)), 1)
        XCTAssertLessThan(s.value(at: .seconds(2)), 1)
        XCTAssertTrue(s.removeKeyframe(near: .zero, tolerance: tol))
        XCTAssertTrue(s.removeKeyframe(near: .seconds(3), tolerance: tol))
        XCTAssertFalse(s.isAnimated)
        XCTAssertEqual(s.constant, 1, "removing the last keyframe keeps its value")
    }

    func testHoldEasing() {
        let s = AnimatedScalar(0, keyframes: [Keyframe(time: .zero, value: 0, easing: .hold), Keyframe(time: .seconds(1), value: 1)])
        XCTAssertEqual(s.value(at: .seconds(0.99)), 0)
        XCTAssertEqual(s.value(at: .seconds(1)), 1)
    }

    func testCopyPasteKeyframes() {
        var t = ClipTransform()
        t.scale.insertOrUpdate(Keyframe(time: .seconds(1), value: 2))
        t.rotation.insertOrUpdate(Keyframe(time: .seconds(1), value: 45))
        let snap = t.keyframeSnapshot(near: .seconds(1), tolerance: tol)
        XCTAssertEqual(snap.count, 2)
        t.paste(snap, at: .seconds(3))
        XCTAssertEqual(t.keyframeTimes, [.seconds(1), .seconds(3)])
        XCTAssertEqual(t.value(at: .seconds(3)).rotation, 45)
    }

    func testKeyframesSurviveSplitBecauseTheyUseSourceTime() throws {
        var (p, ids) = Fixtures.project([4])
        try p.updateClip(ids[0]) { c in
            c.transform.scale.insertOrUpdate(Keyframe(time: .zero, value: 1, easing: .linear))
            c.transform.scale.insertOrUpdate(Keyframe(time: .seconds(4), value: 2))
        }
        let right = try p.split(clipID: ids[0], at: .seconds(2))
        let r = p.clip(right)!
        // Evaluate at the right clip's first frame (source time 2s).
        XCTAssertEqual(r.transform.value(at: r.sourceTime(atTimeline: .seconds(2))).scale, 1.5, accuracy: 1e-9)
    }

    func testTransformCodableOmitsEmptyKeyframes() throws {
        let data = try JSONEncoder().encode(ClipTransform())
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("keyframes"))
        XCTAssertEqual(try JSONDecoder().decode(ClipTransform.self, from: data), ClipTransform())
    }
}
