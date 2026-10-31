import Foundation
@testable import HomifyCore

enum Fixtures {
    static func video(_ seconds: Double, audio: Bool = true) -> MediaAsset {
        MediaAsset(kind: .video, fileName: "\(UUID().uuidString).mov", originalName: "clip.mov",
                   duration: .seconds(seconds), naturalWidth: 1920, naturalHeight: 1080,
                   hasVideo: true, hasAudio: audio)
    }

    static func audio(_ seconds: Double) -> MediaAsset {
        MediaAsset(kind: .audio, fileName: "\(UUID().uuidString).m4a", originalName: "song.m4a",
                   duration: .seconds(seconds), hasVideo: false, hasAudio: true)
    }

    /// Project with main-track clips of the given durations.
    static func project(_ durations: [Double]) -> (Project, [UUID]) {
        var p = Project(name: "Test")
        var ids: [UUID] = []
        for d in durations {
            let m = video(d)
            p.addMedia(m)
            ids.append(try! p.insertIntoMain(mediaID: m.id, near: p.duration + .seconds(1)))
        }
        return (p, ids)
    }
}
