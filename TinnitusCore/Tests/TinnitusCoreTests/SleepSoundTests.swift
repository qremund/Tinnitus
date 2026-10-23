import XCTest
@testable import TinnitusCore

final class NotchDesignTests: XCTestCase {
    let sampleRate = 48_000.0

    private func response(_ sections: [BiquadCoefficients], _ hz: Double) -> Double {
        BiquadCascade(sections).magnitudeDB(atHz: hz, sampleRate: sampleRate)
    }

    func testOneOctaveNotchAt3kHz() {
        let notch = NotchDesign.forTinnitus(centerHz: 3000, widthOctaves: 1, sampleRate: sampleRate)
        let edges = PitchMatching.notchEdges(centerHz: 3000, widthOctaves: 1)
        XCTAssertEqual(notch.count, 4)
        XCTAssertLessThan(response(notch, 3000), -60)
        XCTAssertEqual(response(notch, edges.low), -3.01, accuracy: 0.05)
        XCTAssertEqual(response(notch, edges.high), -3.01, accuracy: 0.05)
        XCTAssertEqual(response(notch, 20), 0, accuracy: 0.01)
        XCTAssertGreaterThan(response(notch, edges.low / 2), -0.1)
        XCTAssertGreaterThan(response(notch, edges.high * 2), -0.1)
    }

    func testNotchIsDeepAcrossMostOfTheBand() {
        let notch = NotchDesign.forTinnitus(centerHz: 3000, widthOctaves: 1, sampleRate: sampleRate)
        // A quarter octave either side of center is still well attenuated.
        XCTAssertLessThan(response(notch, PitchMatching.shift(3000, semitones: -3)), -20)
        XCTAssertLessThan(response(notch, PitchMatching.shift(3000, semitones: 3)), -20)
    }

    func testHalfOctaveAndExtremeCentersStayStable() {
        for (center, width) in [(3000.0, 0.5), (250.0, 1.0), (12_000.0, 1.0)] {
            let notch = NotchDesign.forTinnitus(centerHz: center, widthOctaves: width, sampleRate: sampleRate)
            XCTAssertLessThan(response(notch, center), -40, "center \(center)")
            for section in notch {
                // Poles inside the unit circle: |a2| < 1 and |a1| < 1 + a2.
                XCTAssertLessThan(abs(section.a2), 1)
                XCTAssertLessThan(abs(section.a1), 1 + section.a2)
            }
        }
    }
}

final class SleepSoundTests: XCTestCase {
    let sampleRate = 48_000.0

    func testEverySoundIsAboutUnitRMS() {
        for sound in SleepSound.allCases {
            var generator = SleepSoundGenerator(sound: sound, sampleRate: sampleRate, seed: 99)
            var sumSquares = 0.0
            var allFinite = true
            let count = Int(sampleRate * 30)
            for _ in 0..<count {
                let x = generator.next()
                allFinite = allFinite && x.isFinite
                sumSquares += x * x
            }
            XCTAssertTrue(allFinite, "\(sound)")
            let rms = (sumSquares / Double(count)).squareRoot()
            XCTAssertGreaterThan(rms, 0.7, "\(sound)")
            XCTAssertLessThan(rms, 1.4, "\(sound)")
        }
    }

    private func mixerRMS(_ configuration: SleepMixer.Configuration) -> Double {
        let mixer = SleepMixer(sampleRate: sampleRate, configuration: configuration)
        let count = Int(sampleRate * 4)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { left.deallocate() }
        mixer.render(left: left, right: nil, frameCount: count)
        var sum = 0.0
        for i in (count / 2)..<count { sum += Double(left[i]) * Double(left[i]) }
        return (sum / Double(count / 2)).squareRoot()
    }

    func testMixerLevelAndNotch() {
        let notch = NotchDesign.forTinnitus(centerHz: 3000, widthOctaves: 1, sampleRate: sampleRate)
        let dry = mixerRMS(.init(sound: .white, levelDBFS: -20, isPlaying: true, notch: notch, filterEnabled: false))
        let wet = mixerRMS(.init(sound: .white, levelDBFS: -20, isPlaying: true, notch: notch, filterEnabled: true))
        XCTAssertEqual(dry, 0.1 / 2.0.squareRoot(), accuracy: 0.004)
        // Removing about 2.1 to 4.2 kHz takes roughly 9% of white noise's power.
        XCTAssertLessThan(wet, dry * 0.98)
        XCTAssertGreaterThan(wet, dry * 0.9)
    }

    func testMixerStoppedAndFaded() {
        XCTAssertLessThan(mixerRMS(.init(sound: .pink, levelDBFS: -20, isPlaying: false)), 1e-6)
        let full = mixerRMS(.init(sound: .white, levelDBFS: -20, isPlaying: true))
        let half = mixerRMS(.init(sound: .white, levelDBFS: -20, isPlaying: true, fadeGain: 0.5))
        XCTAssertEqual(half / full, 0.5, accuracy: 0.01)
    }

    func testMixerLevelIsCapped() {
        let config = SleepMixer.Configuration(levelDBFS: 0)
        XCTAssertEqual(config.levelDBFS, SafetyLimits.maxSleepLevelDBFS)
    }
}
