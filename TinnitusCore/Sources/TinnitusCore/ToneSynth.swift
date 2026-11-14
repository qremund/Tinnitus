import Foundation

public enum Ear: String, Codable, CaseIterable, Sendable {
    case left
    case right
    case both
}

public enum TestSoundKind: Equatable, Sendable {
    case tone
    /// Gaussian noise band-passed to the given width (between -3 dB points).
    case narrowbandNoise(bandwidthOctaves: Double)

    /// 0 means a pure tone.
    public init(bandwidthOctaves: Double) {
        self = bandwidthOctaves <= 0 ? .tone : .narrowbandNoise(bandwidthOctaves: bandwidthOctaves)
    }
}

public struct TestSoundParameters: Equatable, Sendable {
    public var frequencyHz: Double
    public var kind: TestSoundKind
    /// RMS level in dB relative to a full-scale sine, so tones and noise at the same value have equal power.
    public var levelDBFS: Double
    public var ear: Ear
    public var isPlaying: Bool

    public init(
        frequencyHz: Double = 3000,
        kind: TestSoundKind = .tone,
        levelDBFS: Double = -40,
        ear: Ear = .both,
        isPlaying: Bool = false
    ) {
        self.frequencyHz = frequencyHz
        self.kind = kind
        self.levelDBFS = levelDBFS
        self.ear = ear
        self.isPlaying = isPlaying
    }
}

/// Renders test tones and narrowband noise. Build a `Configuration` off the audio thread, then
/// hand it to `apply(_:)` and call `render` from the audio thread.
public final class ToneSynth {
    public struct Configuration: Equatable, Sendable {
        public var parameters: TestSoundParameters
        public var bandPass: [BiquadCoefficients]
        /// Scales the filtered noise back to unit variance.
        public var noiseNormalization: Double
    }

    static let bandPassSections = 2
    /// Two identical sections in series narrow the -3 dB width to about 0.64 of one section's.
    static let cascadeNarrowing = 0.64

    public static func configuration(for parameters: TestSoundParameters, sampleRate: Double) -> Configuration {
        var p = parameters
        p.levelDBFS = min(p.levelDBFS, SafetyLimits.maxTestLevelDBFS)
        p.frequencyHz = min(max(p.frequencyHz, 20), sampleRate * 0.45)
        guard case let .narrowbandNoise(bandwidth) = p.kind else {
            return Configuration(parameters: p, bandPass: [], noiseNormalization: 1)
        }
        let sectionWidth = max(bandwidth, 1.0 / 64) / cascadeNarrowing
        let section = BiquadCoefficients.bandPass(centerHz: p.frequencyHz, bandwidthOctaves: sectionWidth, sampleRate: sampleRate)
        let coefficients = Array(repeating: section, count: bandPassSections)
        let power = BiquadCascade.whiteNoisePowerGain(of: coefficients)
        return Configuration(parameters: p, bandPass: coefficients, noiseNormalization: 1 / max(power, 1e-12).squareRoot())
    }

    public let sampleRate: Double
    public private(set) var configuration: Configuration
    private var filter: BiquadCascade
    private var noise = GaussianNoise()
    private var phase = 0.0
    private var leftGain = 0.0
    private var rightGain = 0.0
    private let smoothing: Double

    public init(sampleRate: Double, configuration: Configuration) {
        self.sampleRate = sampleRate
        self.configuration = configuration
        // About a 20 ms fade for every level, ear, and start/stop change.
        smoothing = 1 - exp(-1 / (0.02 * sampleRate))
        // Always two sections, so switching between tone and noise never reallocates on the audio thread.
        let sections = configuration.bandPass.count == Self.bandPassSections
            ? configuration.bandPass
            : Array(repeating: .identity, count: Self.bandPassSections)
        filter = BiquadCascade(sections)
    }

    /// True once a stopped sound has faded out, so a mixer can skip rendering it.
    public var isSilent: Bool {
        !configuration.parameters.isPlaying && leftGain < 1e-6 && rightGain < 1e-6
    }

    /// Takes new settings. Safe on the audio thread. Swaps the old settings into `newConfiguration`,
    /// so the caller can release them off the audio thread.
    public func apply(_ newConfiguration: inout Configuration) {
        swap(&configuration, &newConfiguration)
        // A pure tone doesn't use the filter, so its settings are left alone until noise needs them.
        if configuration.bandPass.count == Self.bandPassSections {
            filter.setCoefficients(configuration.bandPass)
        }
    }

    /// Takes new settings. For use off the audio thread, such as in tests.
    public func apply(_ newConfiguration: Configuration) {
        var copy = newConfiguration
        apply(&copy)
    }

    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frameCount: Int) {
        if isSilent {
            left.update(repeating: 0, count: frameCount)
            right?.update(repeating: 0, count: frameCount)
            return
        }
        let p = configuration.parameters
        let amplitude = p.isPlaying ? Decibels.amplitude(fromDB: p.levelDBFS) : 0
        let targetLeft = p.ear == .right ? 0 : amplitude
        let targetRight = p.ear == .left ? 0 : amplitude
        let increment = 2 * Double.pi * p.frequencyHz / sampleRate
        let isTone = p.kind == .tone
        // A full-scale sine has RMS 1/sqrt(2); scale unit-variance noise to match.
        let noiseScale = configuration.noiseNormalization / 2.0.squareRoot()

        for i in 0..<frameCount {
            leftGain += (targetLeft - leftGain) * smoothing
            rightGain += (targetRight - rightGain) * smoothing
            let sample: Double
            if isTone {
                sample = sin(phase)
                phase += increment
                if phase >= 2 * Double.pi { phase -= 2 * Double.pi }
            } else {
                sample = filter.process(noise.next()) * noiseScale
            }
            left[i] = Float(min(max(sample * leftGain, -1), 1))
            right?[i] = Float(min(max(sample * rightGain, -1), 1))
        }
    }
}
