import XCTest
@testable import HomifyCore

final class StoreTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("homify-tests-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testSaveLoadRoundTrip() throws {
        let store = ProjectStore(rootURL: root)
        var p = try store.create(name: "Trip", aspectRatio: .landscape16x9, frameRate: 60)
        let m = Fixtures.video(5)
        p.addMedia(m)
        let id = try p.insertIntoMain(mediaID: m.id, near: .zero)
        try p.split(clipID: id, at: .seconds(2))
        try p.updateClip(id) { $0.transform.scale.insertOrUpdate(Keyframe(time: .seconds(1), value: 1.3, easing: .cubicBezier(x1: 0.1, y1: 0.2, x2: 0.3, y2: 1))) }
        try store.save(p)
        let loaded = try store.load(p.id)
        XCTAssertEqual(loaded, p)
        XCTAssertEqual(store.list().map(\.id), [p.id])
    }

    func testImportCopiesWithoutTouchingOriginal() throws {
        let store = ProjectStore(rootURL: root)
        let p = try store.create(name: "x", aspectRatio: .square)
        let src = root.appendingPathComponent("src.mov")
        try Data([1, 2, 3]).write(to: src)
        let name = try store.importFile(at: src, into: p.id, move: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
        XCTAssertEqual(try Data(contentsOf: store.mediaURL(projectID: p.id, fileName: name)), Data([1, 2, 3]))
    }

    func testDecodesOlderDocumentsWithMissingFields() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old","createdAt":800000000,
         "tracks":[{"id":"\(UUID().uuidString)","kind":"main"}]}
        """
        let p = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        XCTAssertEqual(p.aspectRatio, .portrait9x16)
        XCTAssertEqual(p.frameRate, 30)
        XCTAssertEqual(p.tracks.count, 1)
    }

    func testPurgeUnusedMedia() throws {
        let store = ProjectStore(rootURL: root)
        var p = try store.create(name: "x", aspectRatio: .square)
        let src = root.appendingPathComponent("a.mov")
        try Data([0]).write(to: src)
        var used = Fixtures.video(1); used.fileName = try store.importFile(at: src, into: p.id, move: false)
        var unused = Fixtures.video(1); unused.fileName = try store.importFile(at: src, into: p.id, move: false)
        p.addMedia(used); p.addMedia(unused)
        try p.insertIntoMain(mediaID: used.id, near: .zero)
        XCTAssertEqual(store.purgeUnusedMedia(of: &p), 1)
        XCTAssertEqual(p.media.map(\.id), [used.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.mediaURL(projectID: p.id, fileName: unused.fileName).path))
    }
}
