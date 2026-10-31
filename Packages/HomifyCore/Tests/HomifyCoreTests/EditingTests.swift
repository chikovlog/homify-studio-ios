import XCTest
@testable import HomifyCore

final class EditingTests: XCTestCase {
    func testInsertPacksMainTrack() {
        let (p, _) = Fixtures.project([3, 2, 4])
        XCTAssertEqual(p.mainTrack.clips.map(\.timelineStart), [.zero, .seconds(3), .seconds(5)])
        XCTAssertEqual(p.duration, .seconds(9))
        XCTAssertEqual(p.validate(), [])
    }

    func testInsertNearBoundary() throws {
        var (p, ids) = Fixtures.project([4, 4])
        let m = Fixtures.video(1)
        p.addMedia(m)
        // 1s is in the first half of clip 0 → inserted before it.
        let id = try p.insertIntoMain(mediaID: m.id, near: .seconds(1))
        XCTAssertEqual(p.mainTrack.clips.map(\.id), [id, ids[0], ids[1]])
        XCTAssertEqual(p.validate(), [])
    }

    func testSplitProducesTwoContiguousClips() throws {
        var (p, ids) = Fixtures.project([4])
        let right = try p.split(clipID: ids[0], at: .seconds(1.5))
        let clips = p.mainTrack.clips
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].duration, .seconds(1.5))
        XCTAssertEqual(clips[1].id, right)
        XCTAssertEqual(clips[1].sourceRange.start, .seconds(1.5))
        XCTAssertEqual(clips[1].timelineStart, .seconds(1.5))
        XCTAssertEqual(p.duration, .seconds(4))
        XCTAssertEqual(p.validate(), [])
    }

    func testSplitOutsideClipFails() {
        var (p, ids) = Fixtures.project([2])
        XCTAssertThrowsError(try p.split(clipID: ids[0], at: .seconds(2))) { XCTAssertEqual($0 as? EditError, .notOnClip) }
        XCTAssertThrowsError(try p.split(clipID: ids[0], at: .zero))
    }

    func testSplitSnapsToFrame() throws {
        var (p, ids) = Fixtures.project([2])
        try p.split(clipID: ids[0], at: .seconds(1.011))
        XCTAssertEqual(p.mainTrack.clips[0].duration, .seconds(1))
    }

    func testTrimStartOnMainRipples() throws {
        var (p, ids) = Fixtures.project([4, 3])
        try p.trim(clipID: ids[0], edge: .start, to: .seconds(1))
        XCTAssertEqual(p.mainTrack.clips[0].sourceRange.start, .seconds(1))
        XCTAssertEqual(p.mainTrack.clips[0].timelineStart, .zero)
        XCTAssertEqual(p.mainTrack.clips[1].timelineStart, .seconds(3))
        XCTAssertEqual(p.duration, .seconds(6))
        XCTAssertEqual(p.validate(), [])
    }

    func testTrimEndIsClampedToMedia() throws {
        var (p, ids) = Fixtures.project([4, 3])
        try p.trim(clipID: ids[0], edge: .end, to: .seconds(2))
        XCTAssertEqual(p.mainTrack.clips[1].timelineStart, .seconds(2))
        // Extending past the source is clamped to the 4 s of media.
        try p.trim(clipID: ids[0], edge: .end, to: .seconds(10))
        XCTAssertEqual(p.mainTrack.clips[0].duration, .seconds(4))
        XCTAssertEqual(p.validate(), [])
    }

    func testTrimRespectsMinimumDuration() throws {
        var (p, ids) = Fixtures.project([4])
        try p.trim(clipID: ids[0], edge: .end, to: .zero)
        XCTAssertEqual(p.mainTrack.clips[0].duration, p.minimumClipDuration)
        try p.trim(clipID: ids[0], edge: .start, to: .seconds(5))
        XCTAssertEqual(p.mainTrack.clips[0].duration, p.minimumClipDuration)
    }

    func testTrimStartCannotRevealBeforeMedia() throws {
        var (p, ids) = Fixtures.project([4])
        try p.trim(clipID: ids[0], edge: .start, to: .seconds(-3))
        XCTAssertEqual(p.mainTrack.clips[0].sourceRange.start, .zero)
        XCTAssertEqual(p.mainTrack.clips[0].duration, .seconds(4))
    }

    func testDeleteRipples() throws {
        var (p, ids) = Fixtures.project([1, 2, 3])
        try p.delete(clipID: ids[1])
        XCTAssertEqual(p.mainTrack.clips.map(\.id), [ids[0], ids[2]])
        XCTAssertEqual(p.mainTrack.clips[1].timelineStart, .seconds(1))
    }

    func testDuplicateInsertsAfter() throws {
        var (p, ids) = Fixtures.project([1, 2])
        let copy = try p.duplicate(clipID: ids[0])
        XCTAssertEqual(p.mainTrack.clips.map(\.id), [ids[0], copy, ids[1]])
        XCTAssertEqual(p.duration, .seconds(4))
        XCTAssertEqual(p.validate(), [])
    }

    func testReorder() throws {
        var (p, ids) = Fixtures.project([1, 2, 3])
        try p.moveMainClip(clipID: ids[0], toIndex: 2)
        XCTAssertEqual(p.mainTrack.clips.map(\.id), [ids[1], ids[2], ids[0]])
        XCTAssertEqual(p.mainTrack.clips[2].timelineStart, .seconds(5))
    }

    func testMainDropIndex() {
        let (p, ids) = Fixtures.project([2, 2, 2])
        // Drag first clip so its centre is at 4.5 s: past centres of clip 1 (3s) and clip 2 (5s)? no → index 1
        XCTAssertEqual(p.mainDropIndex(forCenter: .seconds(4.5), moving: ids[0]), 1)
        XCTAssertEqual(p.mainDropIndex(forCenter: .seconds(9), moving: ids[0]), 2)
        XCTAssertEqual(p.mainDropIndex(forCenter: .zero, moving: ids[2]), 0)
    }

    func testLockedTrackRejectsEdits() {
        var (p, ids) = Fixtures.project([2])
        p.setTrackLocked(p.mainTrack.id, true)
        XCTAssertThrowsError(try p.split(clipID: ids[0], at: .seconds(1))) { XCTAssertEqual($0 as? EditError, .trackLocked) }
        XCTAssertThrowsError(try p.delete(clipID: ids[0]))
    }

    func testLayeredClipsAllocateNewTrackOnOverlap() throws {
        var (p, _) = Fixtures.project([10])
        let a = Fixtures.audio(4)
        p.addMedia(a)
        let c1 = try p.addLayeredClip(mediaID: a.id, kind: .audio, at: .seconds(1))
        let c2 = try p.addLayeredClip(mediaID: a.id, kind: .audio, at: .seconds(2))
        let c3 = try p.addLayeredClip(mediaID: a.id, kind: .audio, at: .seconds(5))
        let audioTracks = p.tracks.filter { $0.kind == .audio }
        XCTAssertEqual(audioTracks.count, 2)
        XCTAssertEqual(p.track(containing: c1)?.id, p.track(containing: c3)?.id)
        XCTAssertNotEqual(p.track(containing: c1)?.id, p.track(containing: c2)?.id)
        XCTAssertEqual(p.validate(), [])
    }

    func testOverlayTracksSitBelowAudioTracks() throws {
        var (p, _) = Fixtures.project([10])
        let a = Fixtures.audio(4), v = Fixtures.video(3)
        p.addMedia(a); p.addMedia(v)
        try p.addLayeredClip(mediaID: a.id, kind: .audio, at: .zero)
        try p.addLayeredClip(mediaID: v.id, kind: .overlay, at: .zero)
        XCTAssertEqual(p.tracks.map(\.kind), [.main, .overlay, .audio])
    }

    func testMoveLayeredClipRejectsOverlap() throws {
        var p = Project(name: "x")
        let a = Fixtures.audio(2)
        p.addMedia(a)
        let c1 = try p.addLayeredClip(mediaID: a.id, kind: .audio, at: .zero)
        _ = try p.addLayeredClip(mediaID: a.id, kind: .audio, at: .seconds(3))
        XCTAssertThrowsError(try p.moveLayeredClip(clipID: c1, toStart: .seconds(2))) { XCTAssertEqual($0 as? EditError, .overlap) }
        try p.moveLayeredClip(clipID: c1, toStart: .seconds(5))
        XCTAssertEqual(p.clip(c1)?.timelineStart, .seconds(5))
        XCTAssertEqual(p.validate(), [])
    }

    func testLayeredTrimStartMovesTimelineStart() throws {
        var p = Project(name: "x")
        let a = Fixtures.audio(5)
        p.addMedia(a)
        let c = try p.addLayeredClip(mediaID: a.id, kind: .audio, at: .seconds(2))
        try p.trim(clipID: c, edge: .start, to: .seconds(3))
        XCTAssertEqual(p.clip(c)?.timelineStart, .seconds(3))
        XCTAssertEqual(p.clip(c)?.sourceRange.start, .seconds(1))
        XCTAssertEqual(p.clip(c)?.timelineRange.end, .seconds(7))
    }

    func testDeletingLastLayeredClipRemovesTrack() throws {
        var p = Project(name: "x")
        let a = Fixtures.audio(5)
        p.addMedia(a)
        let c = try p.addLayeredClip(mediaID: a.id, kind: .audio, at: .zero)
        try p.delete(clipID: c)
        XCTAssertEqual(p.tracks.count, 1)
    }

    func testSnapping() {
        let pts: [Time] = [.zero, .seconds(2), .seconds(5)]
        XCTAssertEqual(Snapping.snap(.seconds(2.1), to: pts, threshold: .seconds(0.2)), .seconds(2))
        XCTAssertNil(Snapping.snap(.seconds(3), to: pts, threshold: .seconds(0.2)))
    }

    func testUndoRedo() throws {
        var (p, ids) = Fixtures.project([4])
        var h = EditHistory<Project>()
        h.record(p, name: "Split")
        try p.split(clipID: ids[0], at: .seconds(2))
        XCTAssertEqual(p.mainTrack.clips.count, 2)
        p = h.undo(current: p)!
        XCTAssertEqual(p.mainTrack.clips.count, 1)
        XCTAssertTrue(h.canRedo)
        p = h.redo(current: p)!
        XCTAssertEqual(p.mainTrack.clips.count, 2)
        XCTAssertNil(h.redo(current: p))
    }

    func testHistoryLimit() {
        var h = EditHistory<Int>(limit: 3)
        for i in 0..<10 { h.record(i, name: "\(i)") }
        XCTAssertEqual(h.undoStack.map(\.state), [7, 8, 9])
    }
}
