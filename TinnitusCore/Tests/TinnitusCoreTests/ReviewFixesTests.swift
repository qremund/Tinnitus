import XCTest
@testable import TinnitusCore

/// Covers the live notch, the audio-thread mailbox, the exact noise power, and the saved-file format.
final class ReviewFixesTests: XCTestCase {
    let sampleRate = 48_000.0

    private func sine(_ hz: Double, seconds: Double = 1) -> [Float] {
        (0..<Int(sampleRate * seconds)).map { Float(sin(2 * Double.pi * hz * Double($0) / sampleRate)) }
    }

    private func rms(_ x: ArraySlice<Float>) -> Double {
        (x.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(x.count, 1))).squareRoot()
    }

    /// Runs a mono bank over `samples` in blocks, like the audio thread does.
    private func run(_ bank: NotchFilterBank, _ samples: inout [Float], block: Int = 512) {
        samples.withUnsafeMutableBufferPointer { buffer in
            var start = 0
            while start < buffer.count {
                let count = min(block, buffer.count - start)
                bank.process(buffer.baseAddress! + start, frameCount: count, channel: 0)
                bank.advance(frameCount: count)
                start += count
            }
        }
    }

    // MARK: Exact noise power

    func testExactNoisePowerMatchesImpulseSum() {
        for (hz, width) in [(250.0, 0.1), (3000, 0.5), (12_000, 1.0)] {
            let section = BiquadCoefficients.bandPass(centerHz: hz, bandwidthOctaves: width, sampleRate: sampleRate)
            var cascade = BiquadCascade([section, section])
            var sum = 0.0
            for n in 0..<400_000 {
                let y = cascade.process(n == 0 ? 1 : 0)
                sum += y * y
            }
            XCTAssertEqual(BiquadCascade.whiteNoisePowerGain(of: [section, section]), sum, accuracy: sum * 1e-6, "\(hz) Hz")
        }
        XCTAssertEqual(BiquadCascade.whiteNoisePowerGain(of: []), 1, accuracy: 1e-12)
    }

    // MARK: Notch filter bank

    func testBankWithoutNotchPassesThrough() {
        let bank = NotchFilterBank(channelCount: 1, sampleRate: sampleRate)
        var x = sine(3000, seconds: 0.1)
        let original = x
        run(bank, &x)
        XCTAssertEqual(x, original)
    }

    func testBankCutsTheNotchAndKeepsTheRest() {
        let notch = NotchDesign.forTinnitus(centerHz: 3000, widthOctaves: 1, sampleRate: sampleRate)
        func output(_ hz: Double) -> Double {
            let bank = NotchFilterBank(channelCount: 1, sampleRate: sampleRate)
            bank.setTarget(channel: 0, coefficients: notch)
            bank.commit()
            bank.settle()
            var x = sine(hz)
            run(bank, &x)
            return rms(x[(x.count / 2)...])
        }
        XCTAssertLessThan(output(3000), 0.001)
        XCTAssertEqual(output(440), 1 / 2.0.squareRoot(), accuracy: 0.01)
    }

    func testBankFadesToANewNotchWithoutAClick() {
        let bank = NotchFilterBank(channelCount: 1, sampleRate: sampleRate)
        var x = sine(3000, seconds: 1)
        // Switch the notch on a quarter of the way in, while the tone plays.
        x.withUnsafeMutableBufferPointer { buffer in
            var start = 0
            while start < buffer.count {
                if start == 12_288 {
                    bank.setTarget(channel: 0, coefficients: NotchDesign.forTinnitus(centerHz: 3000, widthOctaves: 1, sampleRate: sampleRate))
                    bank.commit()
                }
                let count = min(512, buffer.count - start)
                bank.process(buffer.baseAddress! + start, frameCount: count, channel: 0)
                bank.advance(frameCount: count)
                start += count
            }
        }
        // No sudden spike while the new notch fades in, and the tone is gone by the end.
        XCTAssertLessThan(x.map { abs($0) }.max()!, 1.5)
        XCTAssertLessThan(rms(x[(x.count * 3 / 4)...]), 0.001)
        XCTAssertEqual(bank.activeSectionCount(channel: 0), 4) // One notch is four biquads.
    }

    func testBankToggleFadesToTheOriginal() {
        let bank = NotchFilterBank(channelCount: 1, sampleRate: sampleRate)
        bank.setTarget(channel: 0, coefficients: NotchDesign.forTinnitus(centerHz: 3000, widthOctaves: 1, sampleRate: sampleRate))
        bank.commit()
        bank.settle()
        bank.setEnabled(false)
        var x = sine(3000)
        run(bank, &x)
        XCTAssertEqual(rms(x[(x.count / 2)...]), 1 / 2.0.squareRoot(), accuracy: 0.01)
    }

    func testBankIgnoresSectionsBeyondItsCapacity() {
        let bank = NotchFilterBank(channelCount: 1, sampleRate: sampleRate)
        bank.setTarget(channel: 0, coefficients: Array(repeating: .identity, count: NotchFilterBank.maxSections + 5))
        bank.commit()
        bank.settle()
        XCTAssertEqual(bank.activeSectionCount(channel: 0), NotchFilterBank.maxSections)
    }

    // MARK: Live processor

    func testLiveProcessorUsesEachEarAndCombinesForMono() {
        // Two octaves apart, so the one-octave notches stay separate instead of merging into one band.
        let pitches = EarPitches(left: 1500, right: 6000)
        let stereo = LiveNotchProcessor.makeUpdate(.init(pitches: pitches, minimumWidthOctaves: 1), sampleRate: sampleRate, channelCount: 2)
        XCTAssertEqual(stereo.channels[0], pitches.notch(for: .left, widthOctaves: 1, sampleRate: sampleRate))
        XCTAssertEqual(stereo.channels[1], pitches.notch(for: .right, widthOctaves: 1, sampleRate: sampleRate))
        let mono = LiveNotchProcessor.makeUpdate(.init(pitches: pitches, minimumWidthOctaves: 1), sampleRate: sampleRate, channelCount: 1)
        XCTAssertEqual(mono.channels.count, 1)
        XCTAssertEqual(mono.channels[0].count, 8) // Both ears' notches.
    }

    func testLiveProcessorPicksUpNewSettings() {
        let processor = LiveNotchProcessor(settings: .init())
        processor.prepare(sampleRate: sampleRate, channelCount: 1)
        processor.update(.init(pitches: EarPitches(left: 3000, right: 3000), minimumWidthOctaves: 1))
        var x = sine(3000)
        x.withUnsafeMutableBufferPointer { buffer in
            var start = 0
            while start < buffer.count {
                let count = min(512, buffer.count - start)
                processor.beginBlock()
                processor.process(buffer.baseAddress! + start, frameCount: count, channel: 0)
                processor.endBlock(frameCount: count)
                start += count
            }
        }
        XCTAssertLessThan(rms(x[(x.count / 2)...]), 0.001)
    }

    func testHeadroomIsOneDecibel() {
        XCTAssertEqual(Decibels.db(fromAmplitude: Double(LiveNotchProcessor.headroomGain)), -1, accuracy: 0.001)
    }

    // MARK: Mailbox

    func testMailboxSwapsAndHoldsTheOldValue() {
        let mailbox = RealtimeMailbox<[Int]>()
        var current = [1]
        XCTAssertFalse(mailbox.exchange(&current))
        mailbox.post([2])
        XCTAssertTrue(mailbox.exchange(&current))
        XCTAssertEqual(current, [2])
        // Until the main thread posts again, the old value is still held, so a new one can't arrive.
        XCTAssertFalse(mailbox.exchange(&current))
        mailbox.post([3])
        mailbox.post([4])
        XCTAssertTrue(mailbox.exchange(&current))
        XCTAssertEqual(current, [4])
    }

    // MARK: Sleep mixer and synth

    func testStoppedMixerDoesNoWork() {
        let mixer = SleepMixer(sampleRate: sampleRate, configuration: .init(isPlaying: false))
        XCTAssertTrue(mixer.isSilent)
        var left = [Float](repeating: 1, count: 64)
        left.withUnsafeMutableBufferPointer { mixer.render(left: $0.baseAddress!, right: nil, frameCount: 64) }
        XCTAssertTrue(left.allSatisfy { $0 == 0 })
    }

    func testSynthSwitchesBetweenToneAndNoise() {
        let tone = ToneSynth.configuration(for: TestSoundParameters(kind: .tone, isPlaying: true), sampleRate: sampleRate)
        let noise = ToneSynth.configuration(for: TestSoundParameters(kind: .narrowbandNoise(bandwidthOctaves: 0.25), isPlaying: true), sampleRate: sampleRate)
        let synth = ToneSynth(sampleRate: sampleRate, configuration: tone)
        var copy = noise
        synth.apply(&copy)
        XCTAssertEqual(synth.configuration, noise)
        XCTAssertEqual(copy, tone)
    }

    // MARK: Saved files

    func testArchiveRoundTripsAndReadsTheOldFormat() throws {
        let profile = MatchProfile(name: "Night", matchIDs: [UUID()])
        XCTAssertEqual(try MatchArchive.decode(MatchProfile.self, from: MatchArchive.encode([profile])), [profile])
        let legacy = try JSONEncoder().encode([profile])
        XCTAssertEqual(try MatchArchive.decode(MatchProfile.self, from: legacy), [profile])
    }

    func testArchiveRefusesANewerFormatAndBadData() {
        let newer = Data(#"{"version": 99, "items": []}"#.utf8)
        XCTAssertThrowsError(try MatchArchive.decode(MatchProfile.self, from: newer)) {
            XCTAssertEqual($0 as? MatchArchive.ReadError, .newerVersion(99))
        }
        XCTAssertThrowsError(try MatchArchive.decode(MatchProfile.self, from: Data("not json".utf8)))
    }

    func testNotchWidthRule() {
        XCTAssertEqual(NotchDesign.notchWidth(matchedOctaves: 0, minimumOctaves: 1), 1)
        XCTAssertEqual(NotchDesign.notchWidth(matchedOctaves: 0, minimumOctaves: 0.5), 0.5)
        XCTAssertEqual(NotchDesign.notchWidth(matchedOctaves: 1, minimumOctaves: 0.5), 1.5)
        XCTAssertEqual(NotchDesign.notchWidth(matchedOctaves: 0.125, minimumOctaves: 0.5), 0.625)
    }
}
