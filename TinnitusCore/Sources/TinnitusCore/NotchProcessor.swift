import Foundation

/// Runs the tinnitus notch over blocks of multichannel audio, keeping separate filter state per channel.
/// Used to render songs through the notch ahead of playback.
public struct NotchProcessor {
    public private(set) var channels: [BiquadCascade]

    public init(channelCount: Int, coefficients: [BiquadCoefficients]) {
        channels = Array(repeating: BiquadCascade(coefficients), count: max(channelCount, 0))
    }

    /// One set of coefficients per channel. An empty set passes that channel through.
    public init(channelCoefficients: [[BiquadCoefficients]]) {
        channels = channelCoefficients.map(BiquadCascade.init)
    }

    public static func forTinnitus(centerHz: Double, widthOctaves: Double, sampleRate: Double, channelCount: Int) -> NotchProcessor {
        NotchProcessor(
            channelCount: channelCount,
            coefficients: NotchDesign.forTinnitus(centerHz: centerHz, widthOctaves: widthOctaves, sampleRate: sampleRate)
        )
    }

    /// Channel 1 gets the right ear's notch and every other channel the left's.
    /// A mono source should be upmixed to stereo first when the ears differ.
    public static func forTinnitus(pitches: EarPitches, widthOctaves: Double, sampleRate: Double, channelCount: Int) -> NotchProcessor {
        let left = pitches.notch(for: .left, widthOctaves: widthOctaves, sampleRate: sampleRate)
        let right = pitches.notch(for: .right, widthOctaves: widthOctaves, sampleRate: sampleRate)
        return NotchProcessor(channelCoefficients: (0..<max(channelCount, 0)).map { $0 == 1 ? right : left })
    }

    /// Filters `frameCount` samples of one channel in place. State carries over to the next block.
    public mutating func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int, channel: Int) {
        guard channels.indices.contains(channel) else { return }
        var cascade = channels[channel]
        for i in 0..<frameCount {
            samples[i] = Float(cascade.process(Double(samples[i])))
        }
        channels[channel] = cascade
    }
}
