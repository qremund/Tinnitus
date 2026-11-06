import Foundation
import os

/// Applies the tinnitus notch to a stream of audio as it plays, such as a song. Settings come from the
/// main thread and take effect within a block, with a short fade, so changing profiles or turning the
/// notch off never needs the song to be prepared again.
///
/// Thread use: `update` on the main thread; `prepare` and `unprepare` on the player's setup thread;
/// `beginBlock`, `process`, and `endBlock` on the audio thread.
public final class LiveNotchProcessor: @unchecked Sendable {
    public struct Settings: Equatable, Sendable {
        public var pitches: EarPitches
        public var minimumWidthOctaves: Double
        public var enabled: Bool

        public init(pitches: EarPitches = .none, minimumWidthOctaves: Double = 1, enabled: Bool = true) {
            self.pitches = pitches
            self.minimumWidthOctaves = minimumWidthOctaves
            self.enabled = enabled
        }
    }

    /// Everything the audio thread needs, worked out ahead of time.
    struct Update {
        var sampleRate: Double
        var channels: [[BiquadCoefficients]]
        var enabled: Bool
    }

    /// A notch shifts the timing of sound near its edges, which can push a loud song's peaks past full
    /// scale. 1 dB of headroom on everything, filtered or not, keeps the two equally loud and unclipped.
    public static let headroomGain = Float(Decibels.amplitude(fromDB: -1))

    private struct Shared {
        var settings: Settings
        var sampleRate: Double?
        var channelCount = 0
    }

    private let shared: OSAllocatedUnfairLock<Shared>
    private let mailbox = RealtimeMailbox<Update>()
    // Audio thread only, apart from prepare and unprepare, which the player never runs during a block.
    private var bank: NotchFilterBank?
    private var current = Update(sampleRate: 0, channels: [], enabled: true)

    public init(settings: Settings) {
        shared = OSAllocatedUnfairLock(initialState: Shared(settings: settings))
    }

    public var settings: Settings { shared.withLock { $0.settings } }

    /// Main thread: new notches or on/off. Takes effect on the next audio block.
    public func update(_ settings: Settings) {
        let format = shared.withLock { state -> (Double, Int)? in
            state.settings = settings
            return state.sampleRate.map { ($0, state.channelCount) }
        }
        guard let (sampleRate, channelCount) = format else { return }
        mailbox.post(Self.makeUpdate(settings, sampleRate: sampleRate, channelCount: channelCount))
    }

    /// Before playback, once the stream's format is known.
    public func prepare(sampleRate: Double, channelCount: Int) {
        let settings = shared.withLock { state -> Settings in
            state.sampleRate = sampleRate
            state.channelCount = channelCount
            return state.settings
        }
        let update = Self.makeUpdate(settings, sampleRate: sampleRate, channelCount: channelCount)
        let bank = NotchFilterBank(channelCount: channelCount, sampleRate: sampleRate, enabled: update.enabled)
        for (channel, coefficients) in update.channels.enumerated() {
            bank.setTarget(channel: channel, coefficients: coefficients)
        }
        bank.commit()
        bank.settle()
        current = update
        self.bank = bank
    }

    public func unprepare() {
        shared.withLock { $0.sampleRate = nil }
        bank = nil
        mailbox.collectGarbage()
    }

    /// Audio thread: picks up any new settings. Call once per block, before `process`.
    public func beginBlock() {
        guard let bank, mailbox.exchange(&current), current.sampleRate == bank.sampleRate else { return }
        for channel in 0..<min(current.channels.count, bank.channelCount) {
            bank.setTarget(channel: channel, coefficients: current.channels[channel])
        }
        bank.commit()
        bank.setEnabled(current.enabled)
    }

    /// Audio thread: filters one channel in place and applies the headroom.
    public func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int, channel: Int, stride: Int = 1) {
        bank?.process(samples, frameCount: frameCount, channel: channel, stride: stride)
        let gain = Self.headroomGain
        for i in 0..<frameCount {
            samples[i * stride] *= gain
        }
    }

    /// Audio thread: call once per block, after every channel's `process`.
    public func endBlock(frameCount: Int) {
        bank?.advance(frameCount: frameCount)
    }

    /// One set of sections per channel: the left ear's on channel 0, the right's on channel 1, and the
    /// left's on any others. A mono stream can't separate the ears, so it gets both ears' notches.
    static func makeUpdate(_ settings: Settings, sampleRate: Double, channelCount: Int) -> Update {
        let width = settings.minimumWidthOctaves
        let channels: [[BiquadCoefficients]]
        if channelCount <= 1 {
            channels = [settings.pitches.combinedNotch(widthOctaves: width, sampleRate: sampleRate)]
        } else {
            let left = settings.pitches.notch(for: .left, widthOctaves: width, sampleRate: sampleRate)
            let right = settings.pitches.notch(for: .right, widthOctaves: width, sampleRate: sampleRate)
            channels = (0..<channelCount).map { $0 == 1 ? right : left }
        }
        return Update(sampleRate: sampleRate, channels: channels, enabled: settings.enabled)
    }
}
