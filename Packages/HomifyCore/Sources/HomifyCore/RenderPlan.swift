import Foundation

/// A platform-independent description of how to build an AVFoundation
/// composition from a `Project`. Preview and export use the *same* plan, which
/// is what keeps the exported file identical to the preview in timing,
/// transform and audio.
public struct RenderPlan: Equatable, Sendable {
    public struct LaneClip: Equatable, Sendable {
        public var clipID: UUID
        public var mediaID: UUID
        public var sourceRange: TimeRange
        public var timelineStart: Time
        public var timelineRange: TimeRange { TimeRange(start: timelineStart, duration: sourceRange.duration) }
    }

    public struct VolumeRamp: Equatable, Sendable {
        public var range: TimeRange
        public var startVolume: Double
        public var endVolume: Double
    }

    /// One composition video track. Clips never overlap within a lane.
    public struct VideoLane: Equatable, Sendable {
        public var trackID: UUID
        public var clips: [LaneClip]
    }

    /// One composition audio track with its volume automation.
    public struct AudioLane: Equatable, Sendable {
        public var trackID: UUID
        public var clips: [LaneClip]
        public var ramps: [VolumeRamp]
    }

    /// A stretch of the timeline with a constant set of visible layers.
    public struct VideoSegment: Equatable, Sendable {
        public struct Layer: Equatable, Sendable {
            public var laneIndex: Int
            public var clipID: UUID
        }
        public var range: TimeRange
        /// Bottom → top.
        public var layers: [Layer]
    }

    public var duration: Time
    public var videoLanes: [VideoLane]
    public var audioLanes: [AudioLane]
    public var segments: [VideoSegment]

    /// Number of linear ramp pieces used to approximate a curved fade.
    public static let fadeSteps = 8

    public static func make(from project: Project) -> RenderPlan {
        var videoLanes: [VideoLane] = []
        var audioLanes: [AudioLane] = []

        for track in project.tracks {
            let clips = track.clips.sorted { $0.timelineStart < $1.timelineStart }
            if track.kind.isVisual {
                let visual = clips.filter { project.mediaAsset($0.mediaID)?.hasVideo == true }
                if !visual.isEmpty {
                    videoLanes.append(VideoLane(trackID: track.id, clips: visual.map(laneClip)))
                }
            }
            guard !track.isMuted else { continue }
            let audible = clips.filter { project.mediaAsset($0.mediaID)?.hasAudio == true && $0.volume > 0 }
            if !audible.isEmpty {
                audioLanes.append(AudioLane(trackID: track.id, clips: audible.map(laneClip),
                                            ramps: audible.flatMap(volumeRamps)))
            }
        }

        let duration = project.duration
        let segments = makeSegments(lanes: videoLanes, duration: duration)
        return RenderPlan(duration: duration, videoLanes: videoLanes, audioLanes: audioLanes, segments: segments)
    }

    private static func laneClip(_ c: Clip) -> LaneClip {
        LaneClip(clipID: c.id, mediaID: c.mediaID, sourceRange: c.sourceRange, timelineStart: c.timelineStart)
    }

    /// Volume automation for one clip as a list of linear ramps covering the
    /// clip exactly. Fades follow an equal-power curve.
    public static func volumeRamps(for c: Clip) -> [VolumeRamp] {
        let (fi, fo) = c.effectiveFades
        let start = c.timelineStart
        let d = c.duration
        var ramps: [VolumeRamp] = []

        func curve(from: Time, length: Time, fadingIn: Bool) {
            let n = fadeSteps
            for i in 0..<n {
                let s = Time(value: length.value * Int64(i) / Int64(n))
                let e = Time(value: length.value * Int64(i + 1) / Int64(n))
                guard e > s else { continue }
                let p0 = Double(i) / Double(n), p1 = Double(i + 1) / Double(n)
                let g0 = AudioMath.fadeInCurve(fadingIn ? p0 : 1 - p0) * c.volume
                let g1 = AudioMath.fadeInCurve(fadingIn ? p1 : 1 - p1) * c.volume
                ramps.append(VolumeRamp(range: TimeRange(start: from + s, end: from + e), startVolume: g0, endVolume: g1))
            }
        }

        if fi > .zero { curve(from: start, length: fi, fadingIn: true) }
        let bodyStart = start + fi
        let bodyEnd = start + d - fo
        if bodyEnd > bodyStart {
            ramps.append(VolumeRamp(range: TimeRange(start: bodyStart, end: bodyEnd), startVolume: c.volume, endVolume: c.volume))
        }
        if fo > .zero { curve(from: bodyEnd, length: fo, fadingIn: false) }
        return ramps
    }

    /// Splits [0, duration) at every visual clip boundary so each segment has
    /// a fixed layer stack. Segments are contiguous and cover the whole
    /// duration, which AVVideoComposition requires.
    static func makeSegments(lanes: [VideoLane], duration: Time) -> [VideoSegment] {
        guard duration > .zero else { return [] }
        var cuts: Set<Time> = [.zero, duration]
        for lane in lanes {
            for c in lane.clips {
                if c.timelineStart > .zero && c.timelineStart < duration { cuts.insert(c.timelineStart) }
                let e = c.timelineRange.end
                if e > .zero && e < duration { cuts.insert(e) }
            }
        }
        let sorted = cuts.sorted()
        var out: [VideoSegment] = []
        for i in 0..<(sorted.count - 1) {
            let range = TimeRange(start: sorted[i], end: sorted[i + 1])
            var layers: [VideoSegment.Layer] = []
            for (li, lane) in lanes.enumerated() {
                if let c = lane.clips.first(where: { $0.timelineRange.contains(range.start) }) {
                    layers.append(.init(laneIndex: li, clipID: c.clipID))
                }
            }
            // Merge with previous segment when the layer stack is identical.
            if var last = out.last, last.layers == layers {
                last.range = TimeRange(start: last.range.start, end: range.end)
                out[out.count - 1] = last
            } else {
                out.append(VideoSegment(range: range, layers: layers))
            }
        }
        return out
    }
}
