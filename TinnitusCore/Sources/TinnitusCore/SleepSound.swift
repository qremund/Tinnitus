import Foundation

public enum SleepSound: String, Codable, CaseIterable, Sendable {
    case white
    case pink
    case brown
    case rain
    case ocean
    case fan
}

/// Paul Kellet's pink noise filter: -3 dB per octave from white noise.
struct PinkFilter {
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        b0 = 0.99886 * b0 + x * 0.0555179
        b1 = 0.99332 * b1 + x * 0.0750759
        b2 = 0.96900 * b2 + x * 0.1538520
        b3 = 0.86650 * b3 + x * 0.3104856
        b4 = 0.55000 * b4 + x * 0.5329522
        b5 = -0.7616 * b5 - x * 0.0168980
        let y = b0 + b1 + b2 + b3 + b4 + b5 + b6 + x * 0.5362
        b6 = x * 0.115926
        return y
    }
}

/// Generates one channel of a sleep sound, procedurally, so nothing ever audibly loops.
/// Every sound comes out at roughly unit RMS so switching sounds keeps the volume steady.
public struct SleepSoundGenerator {
    public var sound: SleepSound
    private let sampleRate: Double
    private var noise: GaussianNoise
    private var pink = PinkFilter()
    private var brown = 0.0
    private var lowpass = 0.0
    private var highpassState = 0.0
    private var wavePhase = 0.0
    private var waveRate = 1.0 / 9
    private var droplet = 0.0
    private var tremorPhase = 0.0

    // Measured RMS of each raw sound, used to bring them all to about 1.
    static let pinkRMS = 3.06
    static let rainRMS = 0.66
    static let oceanRMS = 0.92
    static let fanRMS = 1.25

    public init(sound: SleepSound, sampleRate: Double, seed: UInt64) {
        self.sound = sound
        self.sampleRate = sampleRate
        noise = GaussianNoise(seed: seed)
        rainHighpass = Self.coefficient(cutoffHz: 400, sampleRate: sampleRate)
        oceanLowpass = Self.coefficient(cutoffHz: 900, sampleRate: sampleRate)
        fanLowpass = Self.coefficient(cutoffHz: 1200, sampleRate: sampleRate)
    }

    private let rainHighpass: Double
    private let oceanLowpass: Double
    private let fanLowpass: Double

    /// One-pole low-pass step; `coefficient` comes from `coefficient(cutoffHz:sampleRate:)`.
    @inline(__always)
    private static func onePole(_ state: inout Double, _ x: Double, _ coefficient: Double) -> Double {
        state += (x - state) * coefficient
        return state
    }

    private static func coefficient(cutoffHz: Double, sampleRate: Double) -> Double {
        1 - exp(-2 * Double.pi * cutoffHz / sampleRate)
    }

    public mutating func next() -> Double {
        let white = noise.next()
        let pinkSample = pink.process(white) / Self.pinkRMS
        // Leaky integrator: variance 0.01 / (1 - 0.995^2), so RMS is about 1.
        brown = 0.995 * brown + 0.1 * white

        switch sound {
        case .white:
            return white
        case .pink:
            return pinkSample
        case .brown:
            return brown
        case .rain:
            // A bright hiss (pink with the lows removed) plus random droplet clicks.
            let low = Self.onePole(&highpassState, pinkSample, rainHighpass)
            let hiss = pinkSample - low
            if noise.nextUniform() < 40 / sampleRate {
                droplet = 0.4 + 0.8 * noise.nextUniform()
            }
            droplet *= exp(-1 / (0.004 * sampleRate))
            return (hiss + droplet * noise.next() * 0.6) / Self.rainRMS
        case .ocean:
            // Low rumble whose loudness swells and recedes like waves every 7 to 12 seconds.
            wavePhase += 2 * Double.pi * waveRate / sampleRate
            if wavePhase >= 2 * Double.pi {
                wavePhase -= 2 * Double.pi
                waveRate = 1 / (7 + 5 * noise.nextUniform())
            }
            let swell = pow(0.5 - 0.5 * cos(wavePhase), 1.5)
            let wash = Self.onePole(&lowpass, pinkSample, oceanLowpass)
            return (0.5 * brown + 1.2 * wash) * (0.25 + 0.75 * swell) / Self.oceanRMS
        case .fan:
            // Steady, softened rush with a slight slow wobble.
            tremorPhase += 2 * Double.pi * 0.3 / sampleRate
            if tremorPhase >= 2 * Double.pi { tremorPhase -= 2 * Double.pi }
            let body = Self.onePole(&lowpass, 0.8 * brown + 0.6 * pinkSample, fanLowpass)
            return body * (1 + 0.04 * sin(tremorPhase)) / Self.fanRMS
        }
    }
}
