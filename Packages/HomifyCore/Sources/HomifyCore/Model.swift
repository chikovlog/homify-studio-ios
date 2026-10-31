import Foundation

public enum AspectRatio: String, Codable, CaseIterable, Sendable, Identifiable {
    case portrait9x16 = "9:16"
    case square = "1:1"
    case landscape16x9 = "16:9"
    case portrait4x5 = "4:5"

    public var id: String { rawValue }

    public var widthOverHeight: Double {
        switch self {
        case .portrait9x16: return 9.0 / 16.0
        case .square: return 1
        case .landscape16x9: return 16.0 / 9.0
        case .portrait4x5: return 4.0 / 5.0
        }
    }

    /// Render size whose shorter side is `shortSide` (e.g. 1080 for 1080p).
    /// Dimensions are rounded to even numbers as H.264 requires.
    public func renderSize(shortSide: Int) -> PixelSize {
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        if widthOverHeight >= 1 {
            return PixelSize(width: even(Double(shortSide) * widthOverHeight), height: even(Double(shortSide)))
        } else {
            return PixelSize(width: even(Double(shortSide)), height: even(Double(shortSide) / widthOverHeight))
        }
    }
}

public struct PixelSize: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

public enum MediaKind: String, Codable, Sendable { case video, audio }

/// A media file copied into the project's folder. The original is never modified.
public struct MediaAsset: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: MediaKind
    /// File name relative to the project's media directory.
    public var fileName: String
    public var originalName: String
    public var duration: Time
    public var naturalWidth: Double
    public var naturalHeight: Double
    /// Affine (a, b, c, d, tx, ty) from the video track's preferredTransform.
    public var preferredTransform: [Double]
    public var frameRate: Double
    public var hasVideo: Bool
    public var hasAudio: Bool

    public init(id: UUID = UUID(), kind: MediaKind, fileName: String, originalName: String, duration: Time,
                naturalWidth: Double = 0, naturalHeight: Double = 0,
                preferredTransform: [Double] = [1, 0, 0, 1, 0, 0], frameRate: Double = 30,
                hasVideo: Bool, hasAudio: Bool) {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.originalName = originalName
        self.duration = duration
        self.naturalWidth = naturalWidth
        self.naturalHeight = naturalHeight
        self.preferredTransform = preferredTransform.count == 6 ? preferredTransform : [1, 0, 0, 1, 0, 0]
        self.frameRate = frameRate
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
    }

    /// Rotation (multiple of 90°) encoded in the preferred transform.
    public var rotationQuarterTurns: Int { LayerGeometry.quarterTurns(preferredTransform) }

    /// Size of the picture as the user sees it (after rotation metadata).
    public var displayWidth: Double { rotationQuarterTurns % 2 == 0 ? naturalWidth : naturalHeight }
    public var displayHeight: Double { rotationQuarterTurns % 2 == 0 ? naturalHeight : naturalWidth }
}

public enum TrackKind: String, Codable, Sendable {
    /// Magnetic primary storyline: clips are always packed from time zero.
    case main
    /// Picture-in-picture video layers above the main track.
    case overlay
    /// Music, voice-over and sound effects.
    case audio

    public var isVisual: Bool { self != .audio }
}

public struct Track: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: TrackKind
    public var isMuted: Bool
    public var isLocked: Bool
    /// Always sorted by `timelineStart` and non-overlapping.
    public var clips: [Clip]

    public init(id: UUID = UUID(), kind: TrackKind, isMuted: Bool = false, isLocked: Bool = false, clips: [Clip] = []) {
        self.id = id
        self.kind = kind
        self.isMuted = isMuted
        self.isLocked = isLocked
        self.clips = clips
    }

    public var end: Time { clips.map(\.timelineRange.end).max() ?? .zero }

    public func isFree(_ range: TimeRange, ignoring clipID: UUID? = nil) -> Bool {
        !clips.contains { $0.id != clipID && $0.timelineRange.overlaps(range) }
    }

    mutating func sortClips() { clips.sort { $0.timelineStart < $1.timelineStart } }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(TrackKind.self, forKey: .kind)
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
    }
}

public struct Clip: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var mediaID: UUID
    /// Portion of the source media used, in source time.
    public var sourceRange: TimeRange
    /// Position on the timeline.
    public var timelineStart: Time
    /// Linear gain, 0…2.
    public var volume: Double
    public var fadeIn: Time
    public var fadeOut: Time
    public var transform: ClipTransform

    public init(id: UUID = UUID(), mediaID: UUID, sourceRange: TimeRange, timelineStart: Time,
                volume: Double = 1, fadeIn: Time = .zero, fadeOut: Time = .zero,
                transform: ClipTransform = ClipTransform()) {
        self.id = id
        self.mediaID = mediaID
        self.sourceRange = sourceRange
        self.timelineStart = timelineStart
        self.volume = volume
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.transform = transform
    }

    public var duration: Time { sourceRange.duration }
    public var timelineRange: TimeRange { TimeRange(start: timelineStart, duration: duration) }

    /// Maps a timeline time to the matching source-media time.
    public func sourceTime(atTimeline t: Time) -> Time { sourceRange.start + (t - timelineStart) }
    public func timelineTime(atSource s: Time) -> Time { timelineStart + (s - sourceRange.start) }

    /// Fades clamped so they never exceed the clip duration together.
    public var effectiveFades: (fadeIn: Time, fadeOut: Time) {
        let d = duration.value
        var fi = max(0, fadeIn.value), fo = max(0, fadeOut.value)
        if fi + fo > d, fi + fo > 0 {
            let k = Double(d) / Double(fi + fo)
            fi = Int64(Double(fi) * k)
            fo = d - fi
        }
        return (Time(value: fi), Time(value: fo))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        mediaID = try c.decode(UUID.self, forKey: .mediaID)
        sourceRange = try c.decode(TimeRange.self, forKey: .sourceRange)
        timelineStart = try c.decode(Time.self, forKey: .timelineStart)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        fadeIn = try c.decodeIfPresent(Time.self, forKey: .fadeIn) ?? .zero
        fadeOut = try c.decodeIfPresent(Time.self, forKey: .fadeOut) ?? .zero
        transform = try c.decodeIfPresent(ClipTransform.self, forKey: .transform) ?? ClipTransform()
    }
}

/// The whole edit, stored as instructions. Source media is never modified.
public struct Project: Codable, Identifiable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var aspectRatio: AspectRatio
    public var frameRate: Int
    public var tracks: [Track]
    public var media: [MediaAsset]

    public init(id: UUID = UUID(), name: String, aspectRatio: AspectRatio = .portrait9x16, frameRate: Int = 30,
                createdAt: Date = Date()) {
        self.schemaVersion = Project.currentSchemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = createdAt
        self.aspectRatio = aspectRatio
        self.frameRate = frameRate
        self.tracks = [Track(kind: .main)]
        self.media = []
    }

    public var duration: Time { tracks.map(\.end).max() ?? .zero }

    public var mainTrackIndex: Int {
        if let i = tracks.firstIndex(where: { $0.kind == .main }) { return i }
        return 0
    }

    public var mainTrack: Track { tracks[mainTrackIndex] }

    public func mediaAsset(_ id: UUID) -> MediaAsset? { media.first { $0.id == id } }

    public func location(ofClip id: UUID) -> (track: Int, clip: Int)? {
        for (ti, t) in tracks.enumerated() {
            if let ci = t.clips.firstIndex(where: { $0.id == id }) { return (ti, ci) }
        }
        return nil
    }

    public func clip(_ id: UUID) -> Clip? {
        guard let l = location(ofClip: id) else { return nil }
        return tracks[l.track].clips[l.clip]
    }

    public func track(containing clipID: UUID) -> Track? {
        guard let l = location(ofClip: clipID) else { return nil }
        return tracks[l.track]
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
        aspectRatio = try c.decodeIfPresent(AspectRatio.self, forKey: .aspectRatio) ?? .portrait9x16
        frameRate = try c.decodeIfPresent(Int.self, forKey: .frameRate) ?? 30
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        media = try c.decodeIfPresent([MediaAsset].self, forKey: .media) ?? []
        if !tracks.contains(where: { $0.kind == .main }) { tracks.insert(Track(kind: .main), at: 0) }
    }
}
