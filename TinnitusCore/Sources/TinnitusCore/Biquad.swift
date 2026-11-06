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

    /// Passes audio through unchanged.
    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

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
    /// Computed from the coefficients, so it costs a few thousand operations at most instead of running
    /// the filter for as many samples as a narrow band takes to ring out.
    public func whiteNoisePowerGain() -> Double {
        BiquadCascade.whiteNoisePowerGain(of: sections.map(\.coefficients))
    }

    /// Exact white noise power gain of biquads in series. Unstable filters return infinity.
    ///
    /// Works on the sections' own state equations, x' = Ax + Bu and y = Cx + Du. The gain is
    /// D^2 + C P C^T, where P is the sum of A^k B B^T (A^T)^k, and each pass below doubles the number of
    /// terms in P. Multiplying the sections into one polynomial would be shorter, but its coefficients
    /// lose the poles of a narrow, low band to rounding, which puts the answer off by percents.
    public static func whiteNoisePowerGain(of coefficients: [BiquadCoefficients]) -> Double {
        // Inside the stability triangle, every section's poles are inside the unit circle.
        guard coefficients.allSatisfy({ abs($0.a2) < 1 && abs($0.a1) < 1 + $0.a2 }) else { return .infinity }

        let n = 2 * coefficients.count
        var a = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        var b = [Double](repeating: 0, count: n)
        var c = [Double](repeating: 0, count: n) // Together with d, gives the output of the sections so far.
        var d = 1.0
        for (section, q) in coefficients.enumerated() {
            let i = 2 * section
            // Transposed direct form II, with the section's output substituted into its state updates.
            let p1 = q.b1 - q.a1 * q.b0
            let p2 = q.b2 - q.a2 * q.b0
            for j in 0..<n {
                a[i][j] = p1 * c[j]
                a[i + 1][j] = p2 * c[j]
            }
            a[i][i] -= q.a1
            a[i][i + 1] += 1
            a[i + 1][i] -= q.a2
            b[i] = p1 * d
            b[i + 1] = p2 * d
            for j in 0..<n {
                c[j] *= q.b0
            }
            c[i] += 1
            d *= q.b0
        }

        var p = b.map { x in b.map { x * $0 } }
        var power = a
        for _ in 0..<64 where power.joined().contains(where: { abs($0) > 1e-20 }) {
            let added = multiply(multiply(power, p), transpose(power))
            for i in 0..<n {
                for j in 0..<n {
                    p[i][j] += added[i][j]
                }
            }
            power = multiply(power, power)
        }

        var gain = d * d
        for i in 0..<n {
            for j in 0..<n {
                gain += c[i] * p[i][j] * c[j]
            }
        }
        return gain
    }

    private static func multiply(_ x: [[Double]], _ y: [[Double]]) -> [[Double]] {
        var result = x.map { $0.map { _ in 0.0 } }
        for i in x.indices {
            for k in y.indices {
                for j in y[k].indices {
                    result[i][j] += x[i][k] * y[k][j]
                }
            }
        }
        return result
    }

    private static func transpose(_ x: [[Double]]) -> [[Double]] {
        x.indices.map { j in x.indices.map { i in x[i][j] } }
    }
}
