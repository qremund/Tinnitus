import Foundation

/// Fast, allocation-free Gaussian noise (xorshift64* plus Box-Muller), safe to call on the audio thread.
public struct GaussianNoise {
    private var state: UInt64
    private var spare: Double?

    public init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        state = seed == 0 ? 1 : seed
    }

    /// Uniform in [0, 1).
    @inline(__always)
    public mutating func nextUniform() -> Double {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let value = state &* 2_685_821_657_736_338_717
        return Double(value >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Standard normal sample (mean 0, variance 1).
    public mutating func next() -> Double {
        if let s = spare {
            spare = nil
            return s
        }
        let u1 = max(nextUniform(), 1e-300)
        let u2 = nextUniform()
        let r = (-2 * log(u1)).squareRoot()
        let theta = 2 * Double.pi * u2
        spare = r * sin(theta)
        return r * cos(theta)
    }
}

public enum Decibels {
    public static func amplitude(fromDB db: Double) -> Double {
        pow(10, db / 20)
    }

    public static func db(fromAmplitude amplitude: Double) -> Double {
        20 * log10(max(amplitude, 1e-12))
    }
}

public enum SafetyLimits {
    /// Loudest any test sound may play, relative to a full-scale sine. Enforced inside the synth.
    public static let maxTestLevelDBFS = -12.0
    /// Quietest level offered by the hearing threshold step.
    public static let minTestLevelDBFS = -100.0
}
