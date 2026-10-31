import AVFoundation
import HomifyCore

struct ExportSettings: Equatable {
    enum Resolution: Int, CaseIterable, Identifiable {
        case p720 = 720
        case p1080 = 1080
        var id: Int { rawValue }
        var label: String { "\(rawValue)p" }
    }

    var resolution: Resolution = .p1080
    var frameRate: Int = 30
}

enum ExportError: LocalizedError {
    case noVideo
    case cannotCreateSession
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideo: return "Add at least one video clip before exporting."
        case .cannotCreateSession: return "This device could not start an H.264 export session."
        case .failed(let m): return m
        case .cancelled: return "Export cancelled."
        }
    }
}

/// Renders a project to an H.264 MP4. AVAssetExportSession streams frames
/// from the original media through the same compositor as the preview, so
/// memory stays flat regardless of project length.
final class VideoExporter: @unchecked Sendable {
    private var session: AVAssetExportSession?
    private let lock = NSLock()

    func export(project: Project, store: ProjectStore, settings: ExportSettings, to outputURL: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws {
        var project = project
        project.frameRate = settings.frameRate
        let projectID = project.id
        let builder = CompositionBuilder { store.mediaURL(projectID: projectID, fileName: $0.fileName) }
        let built = try await builder.build(project: project,
                                            renderSize: project.aspectRatio.renderSize(shortSide: settings.resolution.rawValue))
        guard built.hasVideo else { throw ExportError.noVideo }
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.cannotCreateSession
        }
        try? FileManager.default.removeItem(at: outputURL)
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        lock.lock(); self.session = session; lock.unlock()
        defer { lock.lock(); self.session = nil; lock.unlock() }

        let poll = Task.detached {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        defer { poll.cancel() }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { c.resume() }
        }
        switch session.status {
        case .completed:
            progress(1)
        case .cancelled:
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.cancelled
        default:
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.failed(session.error?.localizedDescription ?? "Export failed.")
        }
    }

    func cancel() {
        lock.lock(); let s = session; lock.unlock()
        s?.cancelExport()
    }
}
