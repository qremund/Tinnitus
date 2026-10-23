import Foundation

/// Butterworth band-stop filters built from an analog prototype and the bilinear transform.
public enum NotchDesign {
    /// Order of the low-pass prototype. The band-stop is twice this (8th order, 4 biquads).
    public static let prototypeOrder = 4

    /// Notch centered on the tinnitus pitch, `widthOctaves` wide between the -3 dB edges.
    public static func forTinnitus(centerHz: Double, widthOctaves: Double, sampleRate: Double) -> [BiquadCoefficients] {
        let edges = PitchMatching.notchEdges(centerHz: centerHz, widthOctaves: widthOctaves)
        return bandStop(lowHz: edges.low, highHz: edges.high, sampleRate: sampleRate)
    }

    /// Band-stop with -3 dB points at `lowHz` and `highHz`, unity gain well outside the band.
    public static func bandStop(lowHz: Double, highHz: Double, sampleRate: Double) -> [BiquadCoefficients] {
        let maxHz = sampleRate * 0.45
        let f1 = min(max(lowHz, 10), maxHz * 0.99)
        let f2 = min(max(highHz, f1 * 1.01), maxHz)

        // Prewarp the edges so the digital filter lands exactly on them.
        let k = 2 * sampleRate
        let omega1 = k * tan(Double.pi * f1 / sampleRate)
        let omega2 = k * tan(Double.pi * f2 / sampleRate)
        let w0Squared = omega1 * omega2
        let bandwidth = omega2 - omega1

        // Each prototype pole p maps to the roots of s^2 - (B/p) s + w0^2. Taking the upper-half
        // poles and pairing every root with its conjugate gives real second-order sections.
        var sections: [BiquadCoefficients] = []
        for i in 1...(prototypeOrder / 2) {
            let angle = Double.pi * Double(2 * i + prototypeOrder - 1) / Double(2 * prototypeOrder)
            let pole = Complex(re: cos(angle), im: sin(angle))
            let c = Complex(re: bandwidth, im: 0) / pole
            let disc = Complex.sqrt(c * c - Complex(re: 4 * w0Squared, im: 0))
            for root in [(c + disc) * 0.5, (c - disc) * 0.5] {
                sections.append(bilinearSection(root: root, w0Squared: w0Squared, k: k))
            }
        }
        return sections
    }

    /// Digitizes H(s) = g (s^2 + w0^2) / ((s - r)(s - r*)), with g chosen for unity gain at DC.
    private static func bilinearSection(root: Complex, w0Squared: Double, k: Double) -> BiquadCoefficients {
        let a1 = -2 * root.re
        let a0 = root.magnitudeSquared
        let g = a0 / w0Squared
        let b2 = g
        let b0 = g * w0Squared
        let kk = k * k
        let norm = kk + a1 * k + a0
        return BiquadCoefficients(
            b0: (b2 * kk + b0) / norm,
            b1: 2 * (b0 - b2 * kk) / norm,
            b2: (b2 * kk + b0) / norm,
            a1: 2 * (a0 - kk) / norm,
            a2: (kk - a1 * k + a0) / norm
        )
    }
}

/// Just enough complex arithmetic for filter design.
struct Complex {
    var re: Double
    var im: Double

    var magnitudeSquared: Double { re * re + im * im }

    static func + (a: Complex, b: Complex) -> Complex { Complex(re: a.re + b.re, im: a.im + b.im) }
    static func - (a: Complex, b: Complex) -> Complex { Complex(re: a.re - b.re, im: a.im - b.im) }
    static func * (a: Complex, b: Complex) -> Complex {
        Complex(re: a.re * b.re - a.im * b.im, im: a.re * b.im + a.im * b.re)
    }
    static func * (a: Complex, s: Double) -> Complex { Complex(re: a.re * s, im: a.im * s) }
    static func / (a: Complex, b: Complex) -> Complex {
        let d = b.magnitudeSquared
        return Complex(re: (a.re * b.re + a.im * b.im) / d, im: (a.im * b.re - a.re * b.im) / d)
    }

    static func sqrt(_ z: Complex) -> Complex {
        let r = z.magnitudeSquared.squareRoot()
        let re = ((r + z.re) / 2).squareRoot()
        let im = ((r - z.re) / 2).squareRoot()
        return Complex(re: re, im: z.im < 0 ? -im : im)
    }
}
