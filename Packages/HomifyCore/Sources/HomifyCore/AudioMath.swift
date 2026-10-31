import Foundation

public enum AudioMath {
    /// Equal-power crossfade gains for progress `p` in [0, 1].
    /// out² + in² == 1 everywhere, so perceived loudness stays constant across
    /// the overlap (no dip in the middle like a linear crossfade).
    public static func equalPowerGains(_ p: Double) -> (out: Double, in: Double) {
        let p = min(max(p, 0), 1)
        return (cos(p * .pi / 2), sin(p * .pi / 2))
    }

    /// Equal-power fade-in curve (fade-out is `fadeInCurve(1 - p)`).
    public static func fadeInCurve(_ p: Double) -> Double { equalPowerGains(p).in }

    /// Gain of a clip at `local` time from its start (fades + volume).
    public static func clipGain(local: Time, duration: Time, volume: Double, fadeIn: Time, fadeOut: Time) -> Double {
        var g = volume
        if fadeIn > .zero, local < fadeIn {
            g *= fadeInCurve(Double(local.value) / Double(fadeIn.value))
        }
        let untilEnd = duration - local
        if fadeOut > .zero, untilEnd < fadeOut {
            g *= fadeInCurve(Double(max(0, untilEnd.value)) / Double(fadeOut.value))
        }
        return g
    }

    public static func linearToDecibels(_ g: Double) -> Double { g <= 0 ? -.infinity : 20 * log10(g) }
    public static func decibelsToLinear(_ db: Double) -> Double { pow(10, db / 20) }
}
