import Foundation

/// Normalized biquad coefficients (a0 == 1), using the forms from the RBJ Audio EQ Cookbook.
public struct BiquadCoefficients: Equatable, Sendable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// Band-pass with a 0 dB peak. `bandwidthOctaves` is the width between the -3 dB points.
    public static func bandPass(centerHz: Double, bandwidthOctaves: Double, sampleRate: Double) -> BiquadCoefficients {
        let w0 = 2 * Double.pi * centerHz / sampleRate
        let alpha = sin(w0) * sinh(log(2) / 2 * bandwidthOctaves * w0 / sin(w0))
        let a0 = 1 + alpha
        return BiquadCoefficients(
            b0: alpha / a0,
            b1: 0,
            b2: -alpha / a0,
            a1: -2 * cos(w0) / a0,
            a2: (1 - alpha) / a0
        )
    }

    /// Magnitude response in dB at `frequencyHz`.
    public func magnitudeDB(atHz frequencyHz: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequencyHz / sampleRate
        let numRe = b0 + b1 * cos(w) + b2 * cos(2 * w)
        let numIm = -(b1 * sin(w) + b2 * sin(2 * w))
        let denRe = 1 + a1 * cos(w) + a2 * cos(2 * w)
        let denIm = -(a1 * sin(w) + a2 * sin(2 * w))
        let power = (numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm)
        return 10 * log10(max(power, 1e-30))
    }
}

/// One biquad section in transposed direct form II.
public struct Biquad {
    public var coefficients: BiquadCoefficients
    private var z1 = 0.0
    private var z2 = 0.0

    public init(_ coefficients: BiquadCoefficients) {
        self.coefficients = coefficients
    }

    @inline(__always)
    public mutating func process(_ x: Double) -> Double {
        let c = coefficients
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }

    public mutating func reset() {
        z1 = 0
        z2 = 0
    }
}

/// Biquad sections run in series. An empty cascade passes audio through unchanged.
public struct BiquadCascade {
    public private(set) var sections: [Biquad]

    public init(_ coefficients: [BiquadCoefficients]) {
        sections = coefficients.map(Biquad.init)
    }

    @inline(__always)
    public mutating func process(_ x: Double) -> Double {
        var y = x
        for i in sections.indices {
            y = sections[i].process(y)
        }
        return y
    }

    /// Swaps in new coefficients. Filter state is kept when the section count is unchanged, which avoids clicks.
    public mutating func setCoefficients(_ coefficients: [BiquadCoefficients]) {
        guard coefficients.count == sections.count else {
            sections = coefficients.map(Biquad.init)
            return
        }
        for i in sections.indices {
            sections[i].coefficients = coefficients[i]
        }
    }

    public func magnitudeDB(atHz frequencyHz: Double, sampleRate: Double) -> Double {
        sections.reduce(0) { $0 + $1.coefficients.magnitudeDB(atHz: frequencyHz, sampleRate: sampleRate) }
    }

    /// Output variance for unit-variance white noise input: the sum of the squared impulse response.
    public func whiteNoisePowerGain(sampleCount: Int = 1 << 15) -> Double {
        var fresh = BiquadCascade(sections.map(\.coefficients))
        var sum = 0.0
        for n in 0..<sampleCount {
            let y = fresh.process(n == 0 ? 1 : 0)
            sum += y * y
        }
        return sum
    }
}
