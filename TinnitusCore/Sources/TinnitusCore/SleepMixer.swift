import Foundation

/// Renders a stereo sleep sound through the tinnitus notch. Build a `Configuration` off the audio
/// thread, hand it to `apply(_:)`, and call `render` from the audio thread.
public final class SleepMixer {
    public struct Configuration: Equatable, Sendable {
        public var sound: SleepSound
        /// RMS level in dB relative to a full-scale sine, capped at `SafetyLimits.maxSleepLevelDBFS`.
        public var levelDBFS: Double
        public var isPlaying: Bool
        /// Empty when there is no profile yet.
        public var notch: [BiquadCoefficients]
        public var filterEnabled: Bool
        /// Extra gain from 0 to 1, used by the sleep timer's fade-out.
        public var fadeGain: Double

        public init(
            sound: SleepSound = .pink,
            levelDBFS: Double = -30,
            isPlaying: Bool = false,
            notch: [BiquadCoefficients] = [],
            filterEnabled: Bool = true,
            fadeGain: Double = 1
        ) {
            self.sound = sound
            self.levelDBFS = min(levelDBFS, SafetyLimits.maxSleepLevelDBFS)
            self.isPlaying = isPlaying
            self.notch = notch
            self.filterEnabled = filterEnabled
            self.fadeGain = min(max(fadeGain, 0), 1)
        }

        public var isFiltering: Bool { filterEnabled && !notch.isEmpty }
    }

    public let sampleRate: Double
    public private(set) var configuration: Configuration
    private var leftSource: SleepSoundGenerator
    private var rightSource: SleepSoundGenerator
    private var leftNotch: BiquadCascade
    private var rightNotch: BiquadCascade
    private var gain = 0.0
    private var wet = 0.0
    private let smoothing: Double

    public init(sampleRate: Double, configuration: Configuration = Configuration()) {
        self.sampleRate = sampleRate
        self.configuration = configuration
        // Different seeds keep the two ears decorrelated, which sounds wider and calmer.
        leftSource = SleepSoundGenerator(sound: configuration.sound, sampleRate: sampleRate, seed: 0x1234_5678_9ABC_DEF1)
        rightSource = SleepSoundGenerator(sound: configuration.sound, sampleRate: sampleRate, seed: 0x0FED_CBA9_8765_4321)
        leftNotch = BiquadCascade(configuration.notch)
        rightNotch = BiquadCascade(configuration.notch)
        wet = configuration.isFiltering ? 1 : 0
        // About a 0.3 s glide for volume, start, stop, and filter on/off.
        smoothing = 1 - exp(-1 / (0.3 * sampleRate))
    }

    public func apply(_ newConfiguration: Configuration) {
        configuration = newConfiguration
        leftSource.sound = newConfiguration.sound
        rightSource.sound = newConfiguration.sound
        leftNotch.setCoefficients(newConfiguration.notch)
        rightNotch.setCoefficients(newConfiguration.notch)
    }

    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frameCount: Int) {
        let c = configuration
        let targetGain = c.isPlaying ? Decibels.amplitude(fromDB: c.levelDBFS) / 2.0.squareRoot() * c.fadeGain : 0
        let targetWet = c.isFiltering ? 1.0 : 0.0
        let hasNotch = !c.notch.isEmpty

        for i in 0..<frameCount {
            gain += (targetGain - gain) * smoothing
            wet += (targetWet - wet) * smoothing
            let dryLeft = leftSource.next()
            let dryRight = rightSource.next()
            // The notch always runs so turning it back on is seamless.
            let notchedLeft = hasNotch ? leftNotch.process(dryLeft) : dryLeft
            let notchedRight = hasNotch ? rightNotch.process(dryRight) : dryRight
            let outLeft = (dryLeft + (notchedLeft - dryLeft) * wet) * gain
            let outRight = (dryRight + (notchedRight - dryRight) * wet) * gain
            left[i] = Float(min(max(outLeft, -1), 1))
            right?[i] = Float(min(max(outRight, -1), 1))
        }
    }
}
