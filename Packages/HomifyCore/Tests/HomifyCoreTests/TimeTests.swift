import XCTest
@testable import HomifyCore

final class TimeTests: XCTestCase {
    func testFrameDurationsAreExact() {
        for fps in [24, 25, 30, 48, 50, 60, 120] {
            XCTAssertEqual(Time.frame(fps).value * Int64(fps), Time.timescale, "fps \(fps)")
        }
    }

    func testSnappingToFrames() {
        XCTAssertEqual(Time.seconds(1.01).snapped(toFrameRate: 30), .seconds(1.0))
        XCTAssertEqual(Time.seconds(1.02).snapped(toFrameRate: 30), Time.seconds(1) + Time.frame(30))
        XCTAssertEqual(Time.seconds(0.5).frameIndex(fps: 60), 30)
    }

    func testRangeOverlapIsHalfOpen() {
        let a = TimeRange(start: .zero, duration: .seconds(2))
        let b = TimeRange(start: .seconds(2), duration: .seconds(1))
        XCTAssertFalse(a.overlaps(b))
        XCTAssertTrue(a.overlaps(TimeRange(start: .seconds(1.9), duration: .seconds(1))))
        XCTAssertFalse(a.contains(.seconds(2)))
    }

    func testTimecode() {
        XCTAssertEqual(Timecode.string(.seconds(61.5), fps: 30), "01:01:15")
        XCTAssertEqual(Timecode.string(.seconds(3600), fps: 30), "1:00:00:00")
        XCTAssertEqual(Timecode.string(.zero, fps: 30), "00:00:00")
    }

    func testCodableRoundTrip() throws {
        let t = Time.seconds(12.345)
        let data = try JSONEncoder().encode([t])
        XCTAssertEqual(try JSONDecoder().decode([Time].self, from: data), [t])
    }
}
