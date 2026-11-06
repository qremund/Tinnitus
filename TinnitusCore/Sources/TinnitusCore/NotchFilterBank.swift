import Foundation

/// The tinnitus notch for live audio, one filter per channel, that can change smoothly while playing.
///
/// All memory is reserved up front, so every method is safe on the audio thread. A new set of notches
/// runs alongside the old one for `crossfadeSeconds` and fades in, which avoids the click of swapping
/// filters mid-stream. Turning the notch off and on fades between the filtered and original sound.
///
/// Use: `setTarget` for each channel, then `commit()`. Per block, call `process` for every channel and
/// then `advance` once, or use `process(left:right:frameCount:)` for stereo.
public final class NotchFilterBank {
    /// The most sections one channel can hold: four notches of four biquads each.
    public static let maxSections = NotchDesign.maxNotchesPerEar * 4
    public static let crossfadeSeconds = 0.1
    public static let toggleSeconds = 0.3

    public let channelCount: Int
    public let sampleRate: Double

    // Two filter slots: the one fading in (`active`) and the one fading out.
    // Raw buffers rather than arrays: no copy-on-write or exclusivity checks inside the sample loop.
    private let coefficients: UnsafeMutablePointer<BiquadCoefficients>
    private let state: UnsafeMutablePointer<Double>
    private let counts: UnsafeMutablePointer<Int>
    private var active = 0
    private var isFading = false
    private var fade = 1.0
    private let fadeStep: Double

    // Notches waiting to be used, filled by `setTarget`.
    private let staged: UnsafeMutablePointer<BiquadCoefficients>
    private let stagedCounts: UnsafeMutablePointer<Int>
    private var hasStaged = false

    private var wet: Double
    private var wetTarget: Double
    private let wetStep: Double

    public init(channelCount: Int, sampleRate: Double, enabled: Bool = true) {
        self.channelCount = max(channelCount, 1)
        self.sampleRate = sampleRate
        let perSlot = self.channelCount * Self.maxSections
        coefficients = .allocate(capacity: 2 * perSlot)
        coefficients.initialize(repeating: .identity, count: 2 * perSlot)
        state = .allocate(capacity: 2 * perSlot * 2)
        state.initialize(repeating: 0, count: 2 * perSlot * 2)
        counts = .allocate(capacity: 2 * self.channelCount)
        counts.initialize(repeating: 0, count: 2 * self.channelCount)
        staged = .allocate(capacity: perSlot)
        staged.initialize(repeating: .identity, count: perSlot)
        stagedCounts = .allocate(capacity: self.channelCount)
        stagedCounts.initialize(repeating: 0, count: self.channelCount)
        fadeStep = 1 / max(Self.crossfadeSeconds * sampleRate, 1)
        wetStep = 1 / max(Self.toggleSeconds * sampleRate, 1)
        wet = enabled ? 1 : 0
        wetTarget = wet
    }

    deinit {
        coefficients.deallocate()
        state.deallocate()
        counts.deallocate()
        staged.deallocate()
        stagedCounts.deallocate()
    }

    /// Whether the notch is heard. Changes fade over `toggleSeconds`.
    public var isEnabled: Bool { wetTarget > 0 }

    public func setEnabled(_ enabled: Bool) {
        wetTarget = enabled ? 1 : 0
    }

    /// Jumps straight to the current settings, with no fades. For the start of playback.
    public func settle() {
        wet = wetTarget
        if hasStaged { startFade() }
        isFading = false
        fade = 1
        clearSlot(1 - active)
    }

    /// Sets the sections one channel should use, starting from the current slot's. Takes effect at `commit()`.
    /// Sections beyond `maxSections` are ignored. Copies the values, so it never allocates.
    public func setTarget(channel: Int, coefficients newCoefficients: [BiquadCoefficients]) {
        guard channel >= 0, channel < channelCount else { return }
        if !hasStaged { copyActiveIntoStaging() }
        let count = min(newCoefficients.count, Self.maxSections)
        let base = channel * Self.maxSections
        for i in 0..<count {
            staged[base + i] = newCoefficients[i]
        }
        stagedCounts[channel] = count
        hasStaged = true
    }

    /// Starts fading to the staged notches if they differ from the ones playing. If a fade is already
    /// running, the new notches wait for it to finish.
    public func commit() {
        guard hasStaged else { return }
        if stagedMatchesActive() {
            hasStaged = false
            return
        }
        if !isFading { startFade() }
    }

    /// Filters one channel in place. Call for each channel, then `advance(frameCount:)` once.
    /// `stride` is the distance between samples, for interleaved audio.
    public func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int, channel: Int, stride: Int = 1) {
        guard channel >= 0, channel < channelCount, frameCount > 0 else { return }
        let activeCount = counts[active * channelCount + channel]
        let outgoing = 1 - active
        let outgoingCount = counts[outgoing * channelCount + channel]
        if activeCount == 0 && (!isFading || outgoingCount == 0) {
            return // Nothing to cut in this channel, so the sound passes through untouched.
        }
        let w0 = wet
        let f0 = fade
        for i in 0..<frameCount {
            let index = i * stride
            let x = Double(samples[index])
            var y = run(slot: active, channel: channel, count: activeCount, x)
            if isFading {
                let old = run(slot: outgoing, channel: channel, count: outgoingCount, x)
                let f = min(f0 + fadeStep * Double(i + 1), 1)
                y = old + (y - old) * f
            }
            let w = ramp(from: w0, to: wetTarget, step: wetStep, steps: i + 1)
            samples[index] = Float(x + (y - x) * w)
        }
    }

    /// Moves the fades on by one block.
    public func advance(frameCount: Int) {
        wet = ramp(from: wet, to: wetTarget, step: wetStep, steps: frameCount)
        guard isFading else { return }
        fade += fadeStep * Double(frameCount)
        if fade >= 1 {
            fade = 1
            isFading = false
            clearSlot(1 - active)
            if hasStaged && !stagedMatchesActive() {
                startFade()
            } else {
                hasStaged = false
            }
        }
    }

    /// Filters a stereo block in place. `right` may be nil for mono output.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frameCount: Int) {
        process(left, frameCount: frameCount, channel: 0)
        if let right {
            process(right, frameCount: frameCount, channel: min(1, channelCount - 1))
        }
        advance(frameCount: frameCount)
    }

    /// Sections in use for one channel, for tests.
    public func activeSectionCount(channel: Int) -> Int {
        counts[active * channelCount + channel]
    }

    // MARK: Internals

    @inline(__always)
    private func ramp(from value: Double, to target: Double, step: Double, steps: Int) -> Double {
        let moved = step * Double(steps)
        return value < target ? min(value + moved, target) : max(value - moved, target)
    }

    @inline(__always)
    private func run(slot: Int, channel: Int, count: Int, _ input: Double) -> Double {
        var y = input
        let base = (slot * channelCount + channel) * Self.maxSections
        for s in 0..<count {
            let c = coefficients[base + s]
            let z = (base + s) * 2
            let out = c.b0 * y + state[z]
            state[z] = c.b1 * y - c.a1 * out + state[z + 1]
            state[z + 1] = c.b2 * y - c.a2 * out
            y = out
        }
        return y
    }

    private func copyActiveIntoStaging() {
        for channel in 0..<channelCount {
            let from = (active * channelCount + channel) * Self.maxSections
            let to = channel * Self.maxSections
            let count = counts[active * channelCount + channel]
            for i in 0..<count {
                staged[to + i] = coefficients[from + i]
            }
            stagedCounts[channel] = count
        }
    }

    private func stagedMatchesActive() -> Bool {
        for channel in 0..<channelCount {
            let count = counts[active * channelCount + channel]
            guard stagedCounts[channel] == count else { return false }
            let from = (active * channelCount + channel) * Self.maxSections
            let to = channel * Self.maxSections
            for i in 0..<count where staged[to + i] != coefficients[from + i] {
                return false
            }
        }
        return true
    }

    /// Loads the staged notches into the idle slot with fresh state and starts fading to them.
    private func startFade() {
        let next = 1 - active
        clearSlot(next)
        for channel in 0..<channelCount {
            let to = (next * channelCount + channel) * Self.maxSections
            let from = channel * Self.maxSections
            let count = stagedCounts[channel]
            for i in 0..<count {
                coefficients[to + i] = staged[from + i]
            }
            counts[next * channelCount + channel] = count
        }
        hasStaged = false
        active = next
        fade = 0
        isFading = true
    }

    private func clearSlot(_ slot: Int) {
        for channel in 0..<channelCount {
            let base = (slot * channelCount + channel) * Self.maxSections
            for i in (base * 2)..<((base + Self.maxSections) * 2) {
                state[i] = 0
            }
            counts[slot * channelCount + channel] = 0
        }
    }
}
