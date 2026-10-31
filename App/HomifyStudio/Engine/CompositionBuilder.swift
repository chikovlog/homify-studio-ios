import AVFoundation
import HomifyCore

struct BuiltComposition {
    let composition: AVComposition
    let videoComposition: AVVideoComposition?
    let audioMix: AVAudioMix?
    let hasVideo: Bool
}

enum CompositionError: LocalizedError {
    case empty
    case missingMedia(String)

    var errorDescription: String? {
        switch self {
        case .empty: return "The timeline is empty."
        case .missingMedia(let n): return "Media file is missing: \(n)"
        }
    }
}

/// Turns a `RenderPlan` into AVFoundation objects. The project's original
/// media files are only *referenced*; nothing is decoded or copied here, so a
/// rebuild after an edit takes milliseconds. It is an actor so overlapping
/// rebuilds never race on its asset caches.
actor CompositionBuilder {
    private let mediaURL: @Sendable (MediaAsset) -> URL
    private var assets: [UUID: AVURLAsset] = [:]
    private struct SourceTracks {
        var video: AVAssetTrack?
        var videoRange: TimeRange?
        var audio: AVAssetTrack?
        var audioRange: TimeRange?
    }
    private var trackCache: [UUID: SourceTracks] = [:]

    init(mediaURL: @escaping @Sendable (MediaAsset) -> URL) {
        self.mediaURL = mediaURL
    }

    private func asset(for media: MediaAsset) -> AVURLAsset {
        if let a = assets[media.id] { return a }
        let a = AVURLAsset(url: mediaURL(media), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        assets[media.id] = a
        return a
    }

    private func tracks(for media: MediaAsset) async throws -> SourceTracks {
        if let t = trackCache[media.id] { return t }
        let a = asset(for: media)
        guard FileManager.default.fileExists(atPath: a.url.path) else { throw CompositionError.missingMedia(media.originalName) }
        var t = SourceTracks()
        if let v = try await a.loadTracks(withMediaType: .video).first {
            t.video = v
            t.videoRange = TimeRange(try await v.load(.timeRange))
        }
        if let au = try await a.loadTracks(withMediaType: .audio).first {
            t.audio = au
            t.audioRange = TimeRange(try await au.load(.timeRange))
        }
        trackCache[media.id] = t
        return t
    }

    /// - Parameters:
    ///   - renderSize: output size; preview passes a reduced size, export the full size.
    func build(project: Project, renderSize: PixelSize) async throws -> BuiltComposition {
        let plan = RenderPlan.make(from: project)
        guard plan.duration > .zero else { throw CompositionError.empty }

        let composition = AVMutableComposition()
        var laneTrackIDs: [CMPersistentTrackID] = []
        var clipInfo: [UUID: Clip] = [:]
        for t in project.tracks { for c in t.clips { clipInfo[c.id] = c } }

        // Video lanes → composition video tracks.
        for lane in plan.videoLanes {
            guard let ct = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            for lc in lane.clips {
                guard let media = project.mediaAsset(lc.mediaID) else { continue }
                let st = try await tracks(for: media)
                guard let src = st.video, let range = st.videoRange else { continue }
                try insert(lc, from: src, available: range, into: ct)
            }
            laneTrackIDs.append(ct.trackID)
        }

        // Audio lanes → composition audio tracks + volume automation.
        var mixParams: [AVMutableAudioMixInputParameters] = []
        for lane in plan.audioLanes {
            guard let ct = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            for lc in lane.clips {
                guard let media = project.mediaAsset(lc.mediaID) else { continue }
                let st = try await tracks(for: media)
                guard let src = st.audio, let range = st.audioRange else { continue }
                try insert(lc, from: src, available: range, into: ct)
            }
            let p = AVMutableAudioMixInputParameters(track: ct)
            p.audioTimePitchAlgorithm = .spectral
            for r in lane.ramps {
                if r.startVolume == r.endVolume {
                    p.setVolume(Float(r.startVolume), at: r.range.start.cmTime)
                } else {
                    p.setVolumeRamp(fromStartVolume: Float(r.startVolume), toEndVolume: Float(r.endVolume), timeRange: r.range.cmTimeRange)
                }
            }
            mixParams.append(p)
        }

        var videoComposition: AVMutableVideoComposition?
        let hasVideo = !plan.videoLanes.isEmpty
        if hasVideo {
            let vc = AVMutableVideoComposition()
            vc.customVideoCompositorClass = HomifyCompositor.self
            vc.renderSize = renderSize.cgSize
            vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, project.frameRate)))
            vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

            // Instructions must tile [0, composition.duration) exactly.
            let total = composition.duration
            var instructions: [HomifyInstruction] = []
            for seg in plan.segments {
                let start = seg.range.start.cmTime
                guard CMTimeCompare(start, total) < 0 else { break }
                var end = seg.range.end.cmTime
                if seg == plan.segments.last || CMTimeCompare(end, total) > 0 { end = total }
                let layers: [CompositorLayer] = seg.layers.compactMap { l in
                    guard let clip = clipInfo[l.clipID], let media = project.mediaAsset(clip.mediaID) else { return nil }
                    return CompositorLayer(trackID: laneTrackIDs[l.laneIndex],
                                           timelineStart: clip.timelineStart,
                                           sourceStart: clip.sourceRange.start,
                                           transform: clip.transform,
                                           orientation: CGImagePropertyOrientation(quarterTurns: media.rotationQuarterTurns))
                }
                instructions.append(HomifyInstruction(timeRange: CMTimeRange(start: start, end: end), layers: layers))
            }
            vc.instructions = instructions
            videoComposition = vc
        }

        var mix: AVMutableAudioMix?
        if !mixParams.isEmpty {
            mix = AVMutableAudioMix()
            mix?.inputParameters = mixParams
        }
        return BuiltComposition(composition: composition.copy() as! AVComposition,
                                videoComposition: videoComposition?.copy() as? AVVideoComposition,
                                audioMix: mix?.copy() as? AVAudioMix,
                                hasVideo: hasVideo)
    }

    private func insert(_ lc: RenderPlan.LaneClip, from src: AVAssetTrack, available: TimeRange,
                        into ct: AVMutableCompositionTrack) throws {
        // Clamp to the real track range: containers sometimes report a track a
        // few ms shorter than the asset. Orientation is applied in the
        // compositor, so the composition track keeps an identity transform.
        guard let usable = lc.sourceRange.intersection(available) else { return }
        let at = lc.timelineStart + (usable.start - lc.sourceRange.start)
        try ct.insertTimeRange(usable.cmTimeRange, of: src, at: at.cmTime)
    }
}
