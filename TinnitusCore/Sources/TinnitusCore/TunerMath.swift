import Foundation

/// Mappings behind the one-screen tuner's sliders, pad, band graph, and dial.
public enum TunerMath {
    public static let minPitchHz = 250.0
    public static let maxPitchHz = 16_000.0
    public static let minLevelDBFS = -90.0
    public static var maxLevelDBFS: Double { SafetyLimits.maxTestLevelDBFS }

    /// 0...1 across the pitch range on a log scale, so each octave gets the same space.
    public static func pitchPosition(_ hz: Double) -> Double {
        let p = log2(hz / minPitchHz) / log2(maxPitchHz / minPitchHz)
        return min(max(p, 0), 1)
    }

    public static func pitch(atPosition position: Double) -> Double {
        let p = min(max(position, 0), 1)
        return minPitchHz * pow(maxPitchHz / minPitchHz, p)
    }

    public static func clampPitch(_ hz: Double) -> Double {
        min(max(hz, minPitchHz), maxPitchHz)
    }

    public static func levelPosition(_ dbfs: Double) -> Double {
        min(max((dbfs - minLevelDBFS) / (maxLevelDBFS - minLevelDBFS), 0), 1)
    }

    public static func level(atPosition position: Double) -> Double {
        let p = min(max(position, 0), 1)
        return minLevelDBFS + p * (maxLevelDBFS - minLevelDBFS)
    }

    /// The sound type a tuned width corresponds to: a tone, a narrow hiss up to 1/8 octave, or a broad hiss.
    public static func soundType(forBandwidthOctaves width: Double) -> TinnitusSoundType {
        if width <= 0 { return .tone }
        return width <= 1.0 / 8 + 1e-9 ? .narrowHiss : .broadHiss
    }

    /// The dial sweeps 270 degrees clockwise from the lower left, with a gap at the bottom.
    public static let dialStartDegrees = 135.0
    public static let dialSweepDegrees = 270.0

    /// 0...1 for a touch at (dx, dy) from the dial center, in screen coordinates (y grows downward).
    /// Touches in the bottom gap snap to the nearer end.
    public static func dialFraction(dx: Double, dy: Double) -> Double {
        var degrees = atan2(dy, dx) * 180 / .pi - dialStartDegrees
        degrees = degrees.truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        if degrees <= dialSweepDegrees { return degrees / dialSweepDegrees }
        return degrees > dialSweepDegrees + (360 - dialSweepDegrees) / 2 ? 0 : 1
    }

    /// Angle in degrees (screen coordinates) of the dial's thumb for a 0...1 value.
    public static func dialAngleDegrees(fraction: Double) -> Double {
        dialStartDegrees + min(max(fraction, 0), 1) * dialSweepDegrees
    }
}
