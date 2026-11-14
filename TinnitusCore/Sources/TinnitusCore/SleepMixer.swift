import Foundation

/// Renders a stereo sleep sound through the tinnitus notch. Build a `Configuration` off the audio
/// thread, hand it to `apply(_:)`, and call `render` from the audio thread.
public final class SleepMixer {
    public struct Configuration: Equatable, Sendable {
        public var sound: SleepSound
        /// RMS level in dB relative to a full-scale sine, capped at `SafetyLimits.maxSleepLevelDBFS`.
        public var levelDBFS: Double
        public var isPlaying: Bool
        /// Empty for an ear with no profile, which then plays unfiltered.
        public var leftNotch: [BiquadCoefficients]
        public var rightNotch: [BiquadCoefficients]
        public var filterEnabled: Bool
        /// Extra gain from 0 to 1, used by the sleep timer's fade-out.
        public var fadeGain: Double

        public init(
            sound: SleepSound = .pink,
            levelDBFS: Double = -30,
            isPlaying: Bool = false,
            leftNotch: [BiquadCoefficients] = [],
            rightNotch: [BiquadCoefficients] = [],
            filterEnabled: Bool = true,
            fadeGain: Double = 1
        ) {
            self.sound = sound
            self.levelDBFS = min(levelDBFS, SafetyLimits.maxSleepLevelDBFS)
            self.isPlaying = isPlaying
            self.leftNotch = leftNotch
            self.rightNotch = rightNotch
            self.filterEnabled = filterEnabled
            self.fadeGain = min(max(fadeGain, 0), 1)
        }

        public var isFiltering: Bool { filterEnabled && !(leftNotch.isEmpty && rightNotch.isEmpty) }
    }

    public let sampleRate: Double
    public private(set) var configuration: Configuration
    private var leftSource: SleepSoundGenerator
    private var rightSource: SleepSoundGenerator
    private let notch: NotchFilterBank
    private var gain = 0.0
    private let smoothing: Double

    public init(sampleRate: Double, configuration: Configuration = Configuration()) {
        self.sampleRate = sampleRate
        self.configuration = configuration
        // Different seeds keep the two ears decorrelated, which sounds wider and calmer.
        leftSource = SleepSoundGenerator(sound: configuration.sound, sampleRate: sampleRate, seed: 0x1234_5678_9ABC_DEF1)
        rightSource = SleepSoundGenerator(sound: configuration.sound, sampleRate: sampleRate, seed: 0x0FED_CBA9_8765_4321)
        notch = NotchFilterBank(channelCount: 2, sampleRate: sampleRate, enabled: configuration.filterEnabled)
        notch.setTarget(channel: 0, coefficients: configuration.leftNotch)
        notch.setTarget(channel: 1, coefficients: configuration.rightNotch)
        notch.commit()
        notch.settle()
        // About a 0.3 s glide for volume, start, and stop.
        smoothing = 1 - exp(-1 / (0.3 * sampleRate))
    }

    /// Takes new settings. Safe on the audio thread: notch changes are copied into memory reserved
    /// up front and fade in. Swaps the old settings into `newConfiguration`, so the caller can release
    /// them off the audio thread.
    public func apply(_ newConfiguration: inout Configuration) {
        swap(&configuration, &newConfiguration)
        leftSource.sound = configuration.sound
        rightSource.sound = configuration.sound
        if configuration.leftNotch != newConfiguration.leftNotch || configuration.rightNotch != newConfiguration.rightNotch {
            notch.setTarget(channel: 0, coefficients: configuration.leftNotch)
            notch.setTarget(channel: 1, coefficients: configuration.rightNotch)
            notch.commit()
        }
        notch.setEnabled(configuration.filterEnabled)
    }

    /// Takes new settings. For use off the audio thread, such as in tests.
    public func apply(_ newConfiguration: Configuration) {
        var copy = newConfiguration
        apply(&copy)
    }

    /// True once playback has stopped and faded out, so nothing needs computing.
    public var isSilent: Bool {
        (!configuration.isPlaying || configuration.fadeGain == 0) && gain < 1e-6
    }

    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frameCount: Int) {
        if isSilent {
            gain = 0
            left.update(repeating: 0, count: frameCount)
            right?.update(repeating: 0, count: frameCount)
            return
        }
        let c = configuration
        let targetGain = c.isPlaying ? Decibels.amplitude(fromDB: c.levelDBFS) / 2.0.squareRoot() * c.fadeGain : 0

        for i in 0..<frameCount {
            left[i] = Float(leftSource.next())
            let r = Float(rightSource.next())
            right?[i] = r
        }
        // The notch always runs, even when turned off, so turning it back on is seamless.
        notch.process(left: left, right: right, frameCount: frameCount)
        for i in 0..<frameCount {
            gain += (targetGain - gain) * smoothing
            left[i] = Float(min(max(Double(left[i]) * gain, -1), 1))
            if let right {
                right[i] = Float(min(max(Double(right[i]) * gain, -1), 1))
            }
        }
    }
}
