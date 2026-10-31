import Foundation

/// Exact rational time on a fixed timescale.
///
/// 120 000 ticks per second divides evenly into 24, 25, 30, 48, 50, 60, 120 fps
/// and into the NTSC rates (30000/1001 → 4004 ticks, 24000/1001 → 5005 ticks),
/// so frame boundaries never accumulate floating point drift.
public struct Time: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public static let timescale: Int64 = 120_000

    public var value: Int64

    public init(value: Int64) { self.value = value }

    public init(seconds: Double) {
        guard seconds.isFinite else { self.value = 0; return }
        self.value = Int64((seconds * Double(Time.timescale)).rounded())
    }

    public static let zero = Time(value: 0)

    public static func seconds(_ s: Double) -> Time { Time(seconds: s) }

    /// Duration of a single frame at `fps`.
    public static func frame(_ fps: Int) -> Time {
        Time(value: Time.timescale / Int64(max(1, fps)))
    }

    public var seconds: Double { Double(value) / Double(Time.timescale) }

    /// Rounds to the nearest frame boundary for `fps`.
    public func snapped(toFrameRate fps: Int) -> Time {
        let f = Time.frame(fps).value
        guard f > 0 else { return self }
        let q = (Double(value) / Double(f)).rounded()
        return Time(value: Int64(q) * f)
    }

    /// Index of the frame containing this time.
    public func frameIndex(fps: Int) -> Int64 {
        let f = Time.frame(fps).value
        guard f > 0 else { return 0 }
        return value >= 0 ? value / f : -((-value + f - 1) / f)
    }

    public func clamped(_ lower: Time, _ upper: Time) -> Time {
        Swift.min(Swift.max(self, lower), upper)
    }

    public static func < (l: Time, r: Time) -> Bool { l.value < r.value }
    public static func + (l: Time, r: Time) -> Time { Time(value: l.value + r.value) }
    public static func - (l: Time, r: Time) -> Time { Time(value: l.value - r.value) }
    public static func += (l: inout Time, r: Time) { l.value += r.value }
    public static func -= (l: inout Time, r: Time) { l.value -= r.value }
    public static prefix func - (t: Time) -> Time { Time(value: -t.value) }
    public static func * (l: Time, r: Double) -> Time { Time(value: Int64((Double(l.value) * r).rounded())) }

    public var description: String { String(format: "%.4fs", seconds) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        value = try c.decode(Int64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}

public struct TimeRange: Hashable, Codable, Sendable, CustomStringConvertible {
    public var start: Time
    public var duration: Time

    public init(start: Time, duration: Time) {
        self.start = start
        self.duration = duration
    }

    public init(start: Time, end: Time) {
        self.start = start
        self.duration = end - start
    }

    public var end: Time { start + duration }
    public var isEmpty: Bool { duration.value <= 0 }

    /// Half-open containment: [start, end).
    public func contains(_ t: Time) -> Bool { t >= start && t < end }

    /// True when the open interiors intersect (touching edges do not overlap).
    public func overlaps(_ other: TimeRange) -> Bool {
        start < other.end && other.start < end
    }

    public func intersection(_ other: TimeRange) -> TimeRange? {
        let s = Swift.max(start, other.start)
        let e = Swift.min(end, other.end)
        return e > s ? TimeRange(start: s, end: e) : nil
    }

    public var description: String { "[\(start) – \(end))" }
}

public enum Timecode {
    /// `MM:SS:FF` (or `H:MM:SS:FF` past one hour).
    public static func string(_ t: Time, fps: Int) -> String {
        let fps = max(1, fps)
        let frames = max(0, t.frameIndex(fps: fps))
        let ff = frames % Int64(fps)
        let totalSeconds = frames / Int64(fps)
        let ss = totalSeconds % 60
        let mm = (totalSeconds / 60) % 60
        let hh = totalSeconds / 3600
        if hh > 0 {
            return String(format: "%lld:%02lld:%02lld:%02lld", hh, mm, ss, ff)
        }
        return String(format: "%02lld:%02lld:%02lld", mm, ss, ff)
    }

    /// Compact `M:SS.s` used for durations on clips.
    public static func short(_ t: Time) -> String {
        let s = max(0, t.seconds)
        let m = Int(s) / 60
        let rest = s - Double(m * 60)
        return String(format: "%d:%04.1f", m, rest)
    }
}
