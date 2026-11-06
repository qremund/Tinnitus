import XCTest
@testable import TinnitusCore

final class ToneSynthTests: XCTestCase {
    let sampleRate = 48_000.0

    /// Renders one second (enough for the fade-in to settle) and returns the RMS of the last half.
    private func renderRMS(_ parameters: TestSoundParameters) -> (left: Double, right: Double) {
        let synth = ToneSynth(sampleRate: sampleRate, configuration: ToneSynth.configuration(for: parameters, sampleRate: sampleRate))
        let count = Int(sampleRate)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer {
            left.deallocate()
            right.deallocate()
        }
        synth.render(left: left, right: right, frameCount: count)
        func rms(_ buffer: UnsafeMutablePointer<Float>) -> Double {
            var sum = 0.0
            for i in (count / 2)..<count { sum += Double(buffer[i]) * Double(buffer[i]) }
            return (sum / Double(count / 2)).squareRoot()
        }
        return (rms(left), rms(right))
    }

    func testStoppedSynthFadesToSilent() {
        let playing = TestSoundParameters(frequencyHz: 1000, kind: .tone, levelDBFS: -20, ear: .both, isPlaying: true)
        let synth = ToneSynth(sampleRate: sampleRate, configuration: ToneSynth.configuration(for: playing, sampleRate: sampleRate))
        let count = Int(sampleRate / 2)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { left.deallocate() }
        synth.render(left: left, right: nil, frameCount: count)
        XCTAssertFalse(synth.isSilent)
        var stopped = playing
        stopped.isPlaying = false
        synth.apply(ToneSynth.configuration(for: stopped, sampleRate: sampleRate))
        XCTAssertFalse(synth.isSilent)
        synth.render(left: left, right: nil, frameCount: count)
        XCTAssertTrue(synth.isSilent)
    }

    func testToneLevelMatchesDBFS() {
        let rms = renderRMS(TestSoundParameters(frequencyHz: 1000, kind: .tone, levelDBFS: -20, ear: .both, isPlaying: true))
        // A -20 dBFS sine has peak 0.1 and RMS 0.1 / sqrt(2).
        XCTAssertEqual(rms.left, 0.1 / 2.0.squareRoot(), accuracy: 0.002)
        XCTAssertEqual(rms.right, 0.1 / 2.0.squareRoot(), accuracy: 0.002)
    }

    func testNoiseHasSamePowerAsToneAtSameLevel() {
        let rms = renderRMS(TestSoundParameters(frequencyHz: 3000, kind: .narrowbandNoise(bandwidthOctaves: 1), levelDBFS: -20, ear: .both, isPlaying: true))
        XCTAssertEqual(rms.left, 0.1 / 2.0.squareRoot(), accuracy: 0.01)
    }

    func testLeftEarOnlySilencesRight() {
        let rms = renderRMS(TestSoundParameters(frequencyHz: 3000, kind: .tone, levelDBFS: -20, ear: .left, isPlaying: true))
        XCTAssertGreaterThan(rms.left, 0.05)
        XCTAssertLessThan(rms.right, 1e-6)
    }

    func testStoppedIsSilent() {
        let rms = renderRMS(TestSoundParameters(frequencyHz: 3000, kind: .tone, levelDBFS: -20, ear: .both, isPlaying: false))
        XCTAssertLessThan(rms.left, 1e-9)
    }

    func testLevelIsCappedAtSafetyCeiling() {
        let config = ToneSynth.configuration(for: TestSoundParameters(levelDBFS: 0, isPlaying: true), sampleRate: sampleRate)
        XCTAssertEqual(config.parameters.levelDBFS, SafetyLimits.maxTestLevelDBFS)
        let rms = renderRMS(TestSoundParameters(frequencyHz: 1000, levelDBFS: 0, isPlaying: true))
        let ceilingRMS = Decibels.amplitude(fromDB: SafetyLimits.maxTestLevelDBFS) / 2.0.squareRoot()
        XCTAssertEqual(rms.left, ceilingRMS, accuracy: 0.005)
    }

    func testBandwidthZeroMeansTone() {
        XCTAssertEqual(TestSoundKind(bandwidthOctaves: 0), .tone)
        XCTAssertEqual(TestSoundKind(bandwidthOctaves: 0.5), .narrowbandNoise(bandwidthOctaves: 0.5))
    }
}
