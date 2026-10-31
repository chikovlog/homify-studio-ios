import Foundation

public enum EditError: Error, Equatable, CustomStringConvertible {
    case clipNotFound
    case mediaNotFound
    case trackLocked
    case notOnClip
    case tooShort
    case overlap
    case invalidOperation(String)

    public var description: String {
        switch self {
        case .clipNotFound: return "Clip not found."
        case .mediaNotFound: return "Media not found."
        case .trackLocked: return "The track is locked."
        case .notOnClip: return "Move the playhead inside the selected clip."
        case .tooShort: return "The clip would be too short."
        case .overlap: return "There is another clip in the way."
        case .invalidOperation(let s): return s
        }
    }
}

public enum ClipEdge: String, Sendable { case start, end }

/// Non-destructive editing operations. Every operation only rewrites the
/// project description; media files are never touched.
extension Project {
    /// Shortest clip any edit may produce.
    public var minimumClipDuration: Time { Time.frame(frameRate) * 3 }

    // MARK: - Media

    public mutating func addMedia(_ asset: MediaAsset) {
        if let i = media.firstIndex(where: { $0.id == asset.id }) { media[i] = asset } else { media.append(asset) }
    }

    // MARK: - Insertion

    /// Inserts a video into the magnetic main track at the clip boundary
    /// nearest to `time`. Returns the new clip id.
    @discardableResult
    public mutating func insertIntoMain(mediaID: UUID, near time: Time) throws -> UUID {
        guard let asset = mediaAsset(mediaID) else { throw EditError.mediaNotFound }
        let ti = mainTrackIndex
        guard !tracks[ti].isLocked else { throw EditError.trackLocked }
        let clip = Clip(mediaID: mediaID, sourceRange: TimeRange(start: .zero, duration: asset.duration), timelineStart: .zero)
        let clips = tracks[ti].clips
        var index = clips.count
        for (i, c) in clips.enumerated() where c.timelineRange.contains(time) {
            let mid = c.timelineStart + Time(value: c.duration.value / 2)
            index = time < mid ? i : i + 1
            break
        }
        if time < .zero { index = 0 }
        tracks[ti].clips.insert(clip, at: index)
        packMainTrack()
        return clip.id
    }

    /// Places media on the first overlay/audio track that has room at `time`,
    /// creating a new track when every existing one is occupied.
    @discardableResult
    public mutating func addLayeredClip(mediaID: UUID, kind: TrackKind, at time: Time) throws -> UUID {
        guard kind != .main else { throw EditError.invalidOperation("Use insertIntoMain for the main track.") }
        guard let asset = mediaAsset(mediaID) else { throw EditError.mediaNotFound }
        let clip = Clip(mediaID: mediaID, sourceRange: TimeRange(start: .zero, duration: asset.duration),
                        timelineStart: max(.zero, time))
        let ti = trackIndexWithRoom(kind: kind, for: clip.timelineRange)
        tracks[ti].clips.append(clip)
        tracks[ti].sortClips()
        return clip.id
    }

    mutating func trackIndexWithRoom(kind: TrackKind, for range: TimeRange, ignoring clipID: UUID? = nil) -> Int {
        if let i = tracks.indices.first(where: { tracks[$0].kind == kind && !tracks[$0].isLocked && tracks[$0].isFree(range, ignoring: clipID) }) {
            return i
        }
        let track = Track(kind: kind)
        // Keep ordering: main, overlays (bottom→top), then audio tracks.
        if kind == .overlay, let firstAudio = tracks.firstIndex(where: { $0.kind == .audio }) {
            tracks.insert(track, at: firstAudio)
            return firstAudio
        }
        tracks.append(track)
        return tracks.count - 1
    }

    // MARK: - Split / Trim

    /// Splits a clip at timeline time `t`. Returns the id of the right half.
    @discardableResult
    public mutating func split(clipID: UUID, at t: Time) throws -> UUID {
        guard let loc = location(ofClip: clipID) else { throw EditError.clipNotFound }
        guard !tracks[loc.track].isLocked else { throw EditError.trackLocked }
        let t = t.snapped(toFrameRate: frameRate)
        let clip = tracks[loc.track].clips[loc.clip]
        let left = t - clip.timelineStart
        let right = clip.timelineRange.end - t
        guard left > .zero, right > .zero else { throw EditError.notOnClip }
        guard left >= Time.frame(frameRate), right >= Time.frame(frameRate) else { throw EditError.tooShort }

        var a = clip
        var b = clip
        b.id = UUID()
        a.sourceRange.duration = left
        a.fadeOut = .zero
        b.sourceRange.start = clip.sourceRange.start + left
        b.sourceRange.duration = right
        b.timelineStart = t
        b.fadeIn = .zero
        tracks[loc.track].clips[loc.clip] = a
        tracks[loc.track].clips.insert(b, at: loc.clip + 1)
        return b.id
    }

    /// Moves one edge of a clip to timeline time `t` (clamped to the source
    /// media and neighbours). On the main track the rest of the story ripples.
    /// Returns the timeline time the edge actually landed on.
    @discardableResult
    public mutating func trim(clipID: UUID, edge: ClipEdge, to t: Time) throws -> Time {
        guard let loc = location(ofClip: clipID) else { throw EditError.clipNotFound }
        guard !tracks[loc.track].isLocked else { throw EditError.trackLocked }
        guard let asset = mediaAsset(tracks[loc.track].clips[loc.clip].mediaID) else { throw EditError.mediaNotFound }
        let isMain = tracks[loc.track].kind == .main
        var clip = tracks[loc.track].clips[loc.clip]
        let minD = minimumClipDuration
        let t = t.snapped(toFrameRate: frameRate)
        let landed: Time

        switch edge {
        case .start:
            // delta > 0 shortens from the left.
            var delta = t - clip.timelineStart
            delta = max(delta, -clip.sourceRange.start)                 // can't reveal before media start
            delta = min(delta, clip.duration - minD)                    // keep minimum length
            if !isMain {
                let prevEnd = tracks[loc.track].clips[..<loc.clip].map(\.timelineRange.end).max() ?? .zero
                delta = max(delta, prevEnd - clip.timelineStart)        // don't overlap previous clip
            }
            clip.sourceRange.start += delta
            clip.sourceRange.duration -= delta
            if !isMain { clip.timelineStart += delta }
            landed = clip.timelineStart
        case .end:
            var newDuration = t - clip.timelineStart
            newDuration = min(newDuration, asset.duration - clip.sourceRange.start)
            newDuration = max(newDuration, minD)
            if !isMain, loc.clip + 1 < tracks[loc.track].clips.count {
                let nextStart = tracks[loc.track].clips[loc.clip + 1].timelineStart
                newDuration = min(newDuration, nextStart - clip.timelineStart)
            }
            clip.sourceRange.duration = newDuration
            landed = clip.timelineRange.end
        }
        guard clip.duration >= Time.frame(frameRate) else { throw EditError.tooShort }
        tracks[loc.track].clips[loc.clip] = clip
        if isMain { packMainTrack() }
        return landed
    }

    // MARK: - Delete / Duplicate / Move

    public mutating func delete(clipID: UUID) throws {
        guard let loc = location(ofClip: clipID) else { throw EditError.clipNotFound }
        guard !tracks[loc.track].isLocked else { throw EditError.trackLocked }
        tracks[loc.track].clips.remove(at: loc.clip)
        if tracks[loc.track].kind == .main { packMainTrack() }
        removeEmptyLayerTracks()
    }

    @discardableResult
    public mutating func duplicate(clipID: UUID) throws -> UUID {
        guard let loc = location(ofClip: clipID) else { throw EditError.clipNotFound }
        guard !tracks[loc.track].isLocked else { throw EditError.trackLocked }
        var copy = tracks[loc.track].clips[loc.clip]
        copy.id = UUID()
        if tracks[loc.track].kind == .main {
            tracks[loc.track].clips.insert(copy, at: loc.clip + 1)
            packMainTrack()
        } else {
            copy.timelineStart = copy.timelineRange.end
            let ti = trackIndexWithRoom(kind: tracks[loc.track].kind, for: copy.timelineRange)
            let preferred = tracks[loc.track].isFree(copy.timelineRange) ? loc.track : ti
            tracks[preferred].clips.append(copy)
            tracks[preferred].sortClips()
        }
        return copy.id
    }

    /// Reorders a clip within the main track.
    public mutating func moveMainClip(clipID: UUID, toIndex: Int) throws {
        let ti = mainTrackIndex
        guard !tracks[ti].isLocked else { throw EditError.trackLocked }
        guard let ci = tracks[ti].clips.firstIndex(where: { $0.id == clipID }) else { throw EditError.clipNotFound }
        let clip = tracks[ti].clips.remove(at: ci)
        let dest = min(max(0, toIndex), tracks[ti].clips.count)
        tracks[ti].clips.insert(clip, at: dest)
        packMainTrack()
    }

    /// Index the clip would take on the main track if dropped with its
    /// centre at timeline time `t`.
    public func mainDropIndex(forCenter t: Time, moving clipID: UUID) -> Int {
        let others = mainTrack.clips.filter { $0.id != clipID }
        var index = 0
        for c in others {
            let mid = c.timelineStart + Time(value: c.duration.value / 2)
            if t > mid { index += 1 }
        }
        // Positions of `others` are pre-removal; this is good enough because
        // the moving clip's own span is excluded from the comparison.
        return index
    }

    /// Moves an overlay/audio clip to a new start (and optionally another
    /// track of the same kind). Fails instead of overlapping.
    public mutating func moveLayeredClip(clipID: UUID, toStart start: Time, trackID: UUID? = nil) throws {
        guard let loc = location(ofClip: clipID) else { throw EditError.clipNotFound }
        let srcKind = tracks[loc.track].kind
        guard srcKind != .main else { throw EditError.invalidOperation("Use moveMainClip for the main track.") }
        guard !tracks[loc.track].isLocked else { throw EditError.trackLocked }
        var clip = tracks[loc.track].clips[loc.clip]
        clip.timelineStart = max(.zero, start.snapped(toFrameRate: frameRate))
        let destIndex: Int
        if let trackID, let i = tracks.firstIndex(where: { $0.id == trackID }) {
            guard tracks[i].kind == srcKind else { throw EditError.invalidOperation("Clips can only move between tracks of the same type.") }
            guard !tracks[i].isLocked else { throw EditError.trackLocked }
            destIndex = i
        } else {
            destIndex = loc.track
        }
        guard tracks[destIndex].isFree(clip.timelineRange, ignoring: clipID) else { throw EditError.overlap }
        tracks[loc.track].clips.remove(at: loc.clip)
        tracks[destIndex].clips.append(clip)
        tracks[destIndex].sortClips()
        removeEmptyLayerTracks()
    }

    // MARK: - Properties

    public mutating func updateClip(_ clipID: UUID, _ body: (inout Clip) -> Void) throws {
        guard let loc = location(ofClip: clipID) else { throw EditError.clipNotFound }
        guard !tracks[loc.track].isLocked else { throw EditError.trackLocked }
        body(&tracks[loc.track].clips[loc.clip])
        tracks[loc.track].clips[loc.clip].volume = min(max(tracks[loc.track].clips[loc.clip].volume, 0), 2)
    }

    public mutating func setTrackMuted(_ trackID: UUID, _ muted: Bool) {
        if let i = tracks.firstIndex(where: { $0.id == trackID }) { tracks[i].isMuted = muted }
    }

    public mutating func setTrackLocked(_ trackID: UUID, _ locked: Bool) {
        if let i = tracks.firstIndex(where: { $0.id == trackID }) { tracks[i].isLocked = locked }
    }

    // MARK: - Housekeeping

    /// Packs main-track clips back-to-back from zero (magnetic timeline).
    public mutating func packMainTrack() {
        let ti = mainTrackIndex
        var cursor = Time.zero
        for i in tracks[ti].clips.indices {
            tracks[ti].clips[i].timelineStart = cursor
            cursor += tracks[ti].clips[i].duration
        }
    }

    public mutating func removeEmptyLayerTracks() {
        tracks.removeAll { $0.kind != .main && $0.clips.isEmpty }
    }

    /// All edges that a dragged item can magnetically snap to.
    public func snapPoints(excluding clipID: UUID?, playhead: Time?) -> [Time] {
        var pts: Set<Time> = [.zero]
        if let playhead { pts.insert(playhead) }
        for t in tracks {
            for c in t.clips where c.id != clipID {
                pts.insert(c.timelineStart)
                pts.insert(c.timelineRange.end)
            }
        }
        return pts.sorted()
    }

    /// Validates structural invariants. Used by tests and before saving.
    public func validate() -> [String] {
        var problems: [String] = []
        if tracks.filter({ $0.kind == .main }).count != 1 { problems.append("Expected exactly one main track") }
        for t in tracks {
            for (i, c) in t.clips.enumerated() {
                if c.duration <= .zero { problems.append("Clip \(c.id) has no duration") }
                if c.sourceRange.start < .zero { problems.append("Clip \(c.id) starts before media") }
                if let m = mediaAsset(c.mediaID), c.sourceRange.end > m.duration {
                    problems.append("Clip \(c.id) extends past media end")
                }
                if mediaAsset(c.mediaID) == nil { problems.append("Clip \(c.id) references missing media") }
                if i > 0, t.clips[i - 1].timelineRange.end > c.timelineStart {
                    problems.append("Clips overlap on track \(t.id)")
                }
            }
            if t.kind == .main {
                var cursor = Time.zero
                for c in t.clips {
                    if c.timelineStart != cursor { problems.append("Main track has a gap") }
                    cursor = c.timelineRange.end
                }
            }
        }
        return problems
    }
}

public enum Snapping {
    /// Returns the candidate closest to `t` if it is within `threshold`.
    public static func snap(_ t: Time, to candidates: [Time], threshold: Time) -> Time? {
        var best: Time?
        var bestDistance = threshold.value
        for c in candidates {
            let d = abs((c - t).value)
            if d <= bestDistance { best = c; bestDistance = d }
        }
        return best
    }
}
