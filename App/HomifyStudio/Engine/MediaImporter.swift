import AVFoundation
import HomifyCore

enum MediaImportError: LocalizedError {
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name): return "\(name) has no playable video or audio."
        }
    }
}

/// Copies a file into the project and reads its metadata. Probing uses the
/// async `load` APIs so the main thread is never blocked.
struct MediaImporter {
    let store: ProjectStore

    func importFile(at url: URL, projectID: UUID, originalName: String? = nil, move: Bool) async throws -> MediaAsset {
        let fileName = try store.importFile(at: url, into: projectID, move: move)
        let dest = store.mediaURL(projectID: projectID, fileName: fileName)
        do {
            return try await probe(url: dest, fileName: fileName, originalName: originalName ?? url.lastPathComponent)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }

    func probe(url: URL, fileName: String, originalName: String) async throws -> MediaAsset {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else { throw MediaImportError.unsupported(originalName) }

        if let v = videoTracks.first {
            let (size, transform, fps, range) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate, .timeRange)
            return MediaAsset(kind: .video, fileName: fileName, originalName: originalName,
                              duration: Time(range.duration),
                              naturalWidth: Double(size.width), naturalHeight: Double(size.height),
                              preferredTransform: [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].map(Double.init),
                              frameRate: Double(fps > 0 ? fps : 30),
                              hasVideo: true, hasAudio: !audioTracks.isEmpty)
        }
        let range = try await audioTracks[0].load(.timeRange)
        return MediaAsset(kind: .audio, fileName: fileName, originalName: originalName,
                          duration: Time(range.duration), hasVideo: false, hasAudio: true)
    }
}
