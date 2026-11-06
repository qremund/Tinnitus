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

    /// The most separate notches in one ear. Each is 4 biquads, so this bounds the work per sample.
    public static let maxNotchesPerEar = 4

    /// How much wider than the matched sound each notch is, so the edges of a hiss are cut deeply
    /// and not just by the 3 dB at the filter's edges.
    public static let widthMarginOctaves = 0.5

    /// Notch width for a match: the matched width plus the margin, and never narrower than `minimumOctaves`
    /// (the width chosen on the Profile tab).
    public static func notchWidth(matchedOctaves: Double, minimumOctaves: Double) -> Double {
        max(minimumOctaves, max(matchedOctaves, 0) + widthMarginOctaves)
    }

    /// The bands removed for notches at `centersHz`, all `widthOctaves` wide, lowest first.
    public static func bands(centersHz: [Double], widthOctaves: Double, maxBands: Int = maxNotchesPerEar) -> [(low: Double, high: Double)] {
        bands(edges: centersHz.filter { $0 > 0 }.map { PitchMatching.notchEdges(centerHz: $0, widthOctaves: widthOctaves) }, maxBands: maxBands)
    }

    /// The bands removed for `notches`, each sized from its own matched width, lowest first.
    public static func bands(notches: [NotchSpec], minimumWidthOctaves: Double, maxBands: Int = maxNotchesPerEar) -> [(low: Double, high: Double)] {
        bands(edges: notches.filter { $0.centerHz > 0 }.map {
            PitchMatching.notchEdges(centerHz: $0.centerHz, widthOctaves: notchWidth(matchedOctaves: $0.matchedWidthOctaves, minimumOctaves: minimumWidthOctaves))
        }, maxBands: maxBands)
    }

    /// Notches that overlap merge into one wider band. If more than `maxBands` remain, the two closest
    /// neighbors are joined until they fit, so every pitch stays notched.
    static func bands(edges: [(low: Double, high: Double)], maxBands: Int) -> [(low: Double, high: Double)] {
        var merged: [(low: Double, high: Double)] = []
        for band in edges.sorted(by: { $0.low < $1.low }) {
            if let last = merged.last, band.low <= last.high {
                merged[merged.count - 1].high = max(last.high, band.high)
            } else {
                merged.append(band)
            }
        }
        while merged.count > max(maxBands, 1) {
            var closest = 0
            var smallestGap = Double.infinity
            for i in 0..<(merged.count - 1) {
                let gap = log2(merged[i + 1].low / merged[i].high)
                if gap < smallestGap {
                    smallestGap = gap
                    closest = i
                }
            }
            merged[closest].high = max(merged[closest].high, merged[closest + 1].high)
            merged.remove(at: closest + 1)
        }
        return merged
    }

    /// Notches for every pitch in one ear, in series. Empty when there are no pitches.
    public static func forTinnitus(centersHz: [Double], widthOctaves: Double, sampleRate: Double) -> [BiquadCoefficients] {
        bands(centersHz: centersHz, widthOctaves: widthOctaves).flatMap {
            bandStop(lowHz: $0.low, highHz: $0.high, sampleRate: sampleRate)
        }
    }

    /// Notches for every match in one ear, each as wide as its match plus the margin. Empty when there are none.
    public static func forTinnitus(notches: [NotchSpec], minimumWidthOctaves: Double, sampleRate: Double) -> [BiquadCoefficients] {
        bands(notches: notches, minimumWidthOctaves: minimumWidthOctaves).flatMap {
            bandStop(lowHz: $0.low, highHz: $0.high, sampleRate: sampleRate)
        }
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

/// One notch to cut: the matched pitch and the width of the matched sound (0 for a pure tone).
public struct NotchSpec: Hashable, Sendable {
    public var centerHz: Double
    public var matchedWidthOctaves: Double

    public init(centerHz: Double, matchedWidthOctaves: Double = 0) {
        self.centerHz = centerHz
        self.matchedWidthOctaves = matchedWidthOctaves
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
