import Foundation

/// Easing applied to the segment that *leaves* a keyframe.
public enum Easing: Codable, Equatable, Hashable, Sendable, CaseIterable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case hold
    case cubicBezier(x1: Double, y1: Double, x2: Double, y2: Double)

    public static var allCases: [Easing] { [.linear, .easeIn, .easeOut, .easeInOut, .hold] }

    public var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .easeIn: return "Ease In"
        case .easeOut: return "Ease Out"
        case .easeInOut: return "Ease In-Out"
        case .hold: return "Hold"
        case .cubicBezier: return "Custom"
        }
    }

    /// Maps linear progress `p` in [0, 1] to eased progress.
    public func apply(_ p: Double) -> Double {
        let p = min(max(p, 0), 1)
        switch self {
        case .linear: return p
        case .hold: return p >= 1 ? 1 : 0
        case .easeIn: return CubicBezier(0.42, 0, 1, 1).y(forX: p)
        case .easeOut: return CubicBezier(0, 0, 0.58, 1).y(forX: p)
        case .easeInOut: return CubicBezier(0.42, 0, 0.58, 1).y(forX: p)
        case let .cubicBezier(x1, y1, x2, y2): return CubicBezier(x1, y1, x2, y2).y(forX: p)
        }
    }
}

/// CSS-style cubic Bézier timing curve with endpoints (0,0) and (1,1).
public struct CubicBezier: Sendable {
    public let x1, y1, x2, y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        // x control points must stay in [0,1] for the curve to be a function of x.
        self.x1 = min(max(x1, 0), 1)
        self.y1 = y1
        self.x2 = min(max(x2, 0), 1)
        self.y2 = y2
    }

    private func sample(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }

    private func derivative(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * p1 + 6 * u * t * (p2 - p1) + 3 * t * t * (1 - p2)
    }

    public func y(forX x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        // Newton-Raphson, falling back to bisection when the slope is flat.
        var t = x
        for _ in 0..<8 {
            let err = sample(t, x1, x2) - x
            if abs(err) < 1e-7 { return sample(t, y1, y2) }
            let d = derivative(t, x1, x2)
            if abs(d) < 1e-6 { break }
            t -= err / d
        }
        var lo = 0.0, hi = 1.0
        t = x
        for _ in 0..<40 {
            let v = sample(t, x1, x2)
            if abs(v - x) < 1e-7 { break }
            if v < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return sample(t, y1, y2)
    }
}

public struct Keyframe: Codable, Equatable, Hashable, Sendable {
    /// Time in the clip's *source media* timebase, so trimming or splitting a
    /// clip never shifts an animation relative to the picture it belongs to.
    public var time: Time
    public var value: Double
    public var easing: Easing

    public init(time: Time, value: Double, easing: Easing = .easeInOut) {
        self.time = time
        self.value = value
        self.easing = easing
    }
}

/// A scalar that is either constant or animated by keyframes.
public struct AnimatedScalar: Codable, Equatable, Hashable, Sendable {
    public var constant: Double
    public private(set) var keyframes: [Keyframe]

    public init(_ constant: Double, keyframes: [Keyframe] = []) {
        self.constant = constant
        self.keyframes = keyframes.sorted { $0.time < $1.time }
    }

    public var isAnimated: Bool { !keyframes.isEmpty }

    public func value(at t: Time) -> Double {
        guard let first = keyframes.first, let last = keyframes.last else { return constant }
        if t <= first.time { return first.value }
        if t >= last.time { return last.value }
        // Binary search for the segment containing t.
        var lo = 0, hi = keyframes.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if keyframes[mid].time <= t { lo = mid } else { hi = mid }
        }
        let a = keyframes[lo], b = keyframes[hi]
        let span = Double((b.time - a.time).value)
        guard span > 0 else { return b.value }
        let p = Double((t - a.time).value) / span
        let e = a.easing.apply(p)
        return a.value + (b.value - a.value) * e
    }

    public func keyframeIndex(near t: Time, tolerance: Time) -> Int? {
        var best: (Int, Int64)?
        for (i, k) in keyframes.enumerated() {
            let d = abs((k.time - t).value)
            if d <= tolerance.value, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }

    /// Applies a user edit of the property at time `t`.
    ///
    /// - autoKeyframe on: creates a keyframe at `t` or updates the one within
    ///   `tolerance`.
    /// - autoKeyframe off: never creates keyframes. A static property just
    ///   changes its constant; an animated one is offset as a whole (every
    ///   keyframe moves by the same delta) so the animation shape is kept.
    ///
    /// When the first keyframe is created away from `anchor` (normally the
    /// clip's first frame) the previous value is pinned at `anchor`, so
    /// "pinch to 125% at 2s" animates from the old value instead of jumping.
    public mutating func set(_ newValue: Double, at t: Time, autoKeyframe: Bool, tolerance: Time, anchor: Time? = nil) {
        if autoKeyframe {
            if keyframes.isEmpty {
                if let anchor, abs((anchor - t).value) > tolerance.value {
                    insertOrUpdate(Keyframe(time: anchor, value: constant))
                }
                insertOrUpdate(Keyframe(time: t, value: newValue))
            } else if let i = keyframeIndex(near: t, tolerance: tolerance) {
                keyframes[i].value = newValue
            } else {
                insertOrUpdate(Keyframe(time: t, value: newValue))
            }
            constant = newValue
        } else if keyframes.isEmpty {
            constant = newValue
        } else {
            let delta = newValue - value(at: t)
            for i in keyframes.indices { keyframes[i].value += delta }
        }
    }

    public mutating func insertOrUpdate(_ k: Keyframe) {
        if let i = keyframes.firstIndex(where: { $0.time == k.time }) {
            keyframes[i] = k
        } else {
            let i = keyframes.firstIndex(where: { $0.time > k.time }) ?? keyframes.count
            keyframes.insert(k, at: i)
        }
    }

    /// Removes the keyframe at `t` (within tolerance). The constant becomes the
    /// value of the remaining curve so removing the last keyframe keeps the look.
    @discardableResult
    public mutating func removeKeyframe(near t: Time, tolerance: Time) -> Bool {
        guard let i = keyframeIndex(near: t, tolerance: tolerance) else { return false }
        let v = keyframes[i].value
        keyframes.remove(at: i)
        if keyframes.isEmpty { constant = v }
        return true
    }

    /// Moves a keyframe in time. If another keyframe already sits at the
    /// destination it is replaced.
    @discardableResult
    public mutating func moveKeyframe(from: Time, to: Time, tolerance: Time) -> Bool {
        guard let i = keyframeIndex(near: from, tolerance: tolerance) else { return false }
        var k = keyframes.remove(at: i)
        k.time = to
        keyframes.removeAll { $0.time == to }
        insertOrUpdate(k)
        return true
    }

    public mutating func setEasing(_ easing: Easing, near t: Time, tolerance: Time) {
        if let i = keyframeIndex(near: t, tolerance: tolerance) { keyframes[i].easing = easing }
    }

    public mutating func removeAllKeyframes(keeping t: Time) {
        constant = value(at: t)
        keyframes.removeAll()
    }

    public mutating func replaceKeyframes(_ new: [Keyframe]) {
        keyframes = new.sorted { $0.time < $1.time }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        constant = try c.decode(Double.self, forKey: .constant)
        keyframes = (try c.decodeIfPresent([Keyframe].self, forKey: .keyframes) ?? []).sorted { $0.time < $1.time }
    }

    private enum CodingKeys: String, CodingKey { case constant, keyframes }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(constant, forKey: .constant)
        if !keyframes.isEmpty { try c.encode(keyframes, forKey: .keyframes) }
    }
}

public enum TransformProperty: String, Codable, CaseIterable, Sendable {
    case scale, positionX, positionY, rotation, opacity
}

/// Evaluated transform of a visual clip.
/// - scale: 1 = aspect-fit inside the canvas.
/// - position: offset of the clip centre as a fraction of canvas width/height
///   (+x right, +y down, like the screen).
/// - rotation: degrees, clockwise on screen.
/// - opacity: 0…1.
public struct TransformValue: Equatable, Hashable, Sendable {
    public var scale: Double = 1
    public var positionX: Double = 0
    public var positionY: Double = 0
    public var rotation: Double = 0
    public var opacity: Double = 1

    public init(scale: Double = 1, positionX: Double = 0, positionY: Double = 0, rotation: Double = 0, opacity: Double = 1) {
        self.scale = scale
        self.positionX = positionX
        self.positionY = positionY
        self.rotation = rotation
        self.opacity = opacity
    }

    public static let identity = TransformValue()

    public subscript(_ p: TransformProperty) -> Double {
        get {
            switch p {
            case .scale: return scale
            case .positionX: return positionX
            case .positionY: return positionY
            case .rotation: return rotation
            case .opacity: return opacity
            }
        }
        set {
            switch p {
            case .scale: scale = newValue
            case .positionX: positionX = newValue
            case .positionY: positionY = newValue
            case .rotation: rotation = newValue
            case .opacity: opacity = newValue
            }
        }
    }
}

/// Keyframeable transform attached directly to a clip (no adjustment layer).
public struct ClipTransform: Codable, Equatable, Hashable, Sendable {
    public var scale = AnimatedScalar(1)
    public var positionX = AnimatedScalar(0)
    public var positionY = AnimatedScalar(0)
    public var rotation = AnimatedScalar(0)
    public var opacity = AnimatedScalar(1)

    public init() {}

    public subscript(_ p: TransformProperty) -> AnimatedScalar {
        get {
            switch p {
            case .scale: return scale
            case .positionX: return positionX
            case .positionY: return positionY
            case .rotation: return rotation
            case .opacity: return opacity
            }
        }
        set {
            switch p {
            case .scale: scale = newValue
            case .positionX: positionX = newValue
            case .positionY: positionY = newValue
            case .rotation: rotation = newValue
            case .opacity: opacity = newValue
            }
        }
    }

    public var isIdentity: Bool { self == ClipTransform() }
    public var hasKeyframes: Bool { TransformProperty.allCases.contains { self[$0].isAnimated } }

    /// `t` is in the clip's source timebase.
    public func value(at t: Time) -> TransformValue {
        TransformValue(
            scale: scale.value(at: t),
            positionX: positionX.value(at: t),
            positionY: positionY.value(at: t),
            rotation: rotation.value(at: t),
            opacity: min(max(opacity.value(at: t), 0), 1)
        )
    }

    /// Writes a whole transform at once (e.g. after a pinch gesture). Only
    /// properties that actually changed are touched, so an untouched property
    /// never receives an accidental keyframe.
    public mutating func apply(_ v: TransformValue, at t: Time, autoKeyframe: Bool, tolerance: Time, anchor: Time? = nil) {
        let current = value(at: t)
        for p in TransformProperty.allCases where abs(current[p] - v[p]) > 1e-9 {
            self[p].set(v[p], at: t, autoKeyframe: autoKeyframe, tolerance: tolerance, anchor: anchor)
        }
    }

    /// Union of keyframe times across all properties, sorted.
    public var keyframeTimes: [Time] {
        Array(Set(TransformProperty.allCases.flatMap { self[$0].keyframes.map(\.time) })).sorted()
    }

    public mutating func removeKeyframes(near t: Time, tolerance: Time) {
        for p in TransformProperty.allCases { self[p].removeKeyframe(near: t, tolerance: tolerance) }
    }

    public mutating func moveKeyframes(from: Time, to: Time, tolerance: Time) {
        for p in TransformProperty.allCases { self[p].moveKeyframe(from: from, to: to, tolerance: tolerance) }
    }

    public mutating func setEasing(_ e: Easing, near t: Time, tolerance: Time) {
        for p in TransformProperty.allCases { self[p].setEasing(e, near: t, tolerance: tolerance) }
    }

    /// Snapshot of every property's keyframe at `t`, for copy/paste.
    public func keyframeSnapshot(near t: Time, tolerance: Time) -> [TransformProperty: Keyframe] {
        var out: [TransformProperty: Keyframe] = [:]
        for p in TransformProperty.allCases {
            if let i = self[p].keyframeIndex(near: t, tolerance: tolerance) { out[p] = self[p].keyframes[i] }
        }
        return out
    }

    public mutating func paste(_ snapshot: [TransformProperty: Keyframe], at t: Time) {
        for (p, k) in snapshot {
            var copy = k
            copy.time = t
            self[p].insertOrUpdate(copy)
        }
    }
}
