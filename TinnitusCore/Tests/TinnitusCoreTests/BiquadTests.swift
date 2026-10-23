import XCTest
@testable import TinnitusCore

final class BiquadTests: XCTestCase {
    let sampleRate = 48_000.0

    func testBandPassPeaksAtZeroDBAtCenter() {
        let c = BiquadCoefficients.bandPass(centerHz: 3000, bandwidthOctaves: 0.5, sampleRate: sampleRate)
        XCTAssertEqual(c.magnitudeDB(atHz: 3000, sampleRate: sampleRate), 0, accuracy: 0.01)
    }

    func testBandPassIsAboutMinus3DBAtEdges() {
        let c = BiquadCoefficients.bandPass(centerHz: 1000, bandwidthOctaves: 1, sampleRate: sampleRate)
        let edges = PitchMatching.notchEdges(centerHz: 1000, widthOctaves: 1)
        XCTAssertEqual(c.magnitudeDB(atHz: edges.low, sampleRate: sampleRate), -3, accuracy: 0.5)
        XCTAssertEqual(c.magnitudeDB(atHz: edges.high, sampleRate: sampleRate), -3, accuracy: 0.5)
    }

    func testBandPassAttenuatesFarAway() {
        let c = BiquadCoefficients.bandPass(centerHz: 3000, bandwidthOctaves: 1.0 / 8, sampleRate: sampleRate)
        XCTAssertLessThan(c.magnitudeDB(atHz: 750, sampleRate: sampleRate), -20)
        XCTAssertLessThan(c.magnitudeDB(atHz: 12_000, sampleRate: sampleRate), -20)
    }

    func testFilteredNoiseIsNormalizedToUnitVariance() {
        let config = ToneSynth.configuration(
            for: TestSoundParameters(frequencyHz: 3000, kind: .narrowbandNoise(bandwidthOctaves: 1.0 / 16)),
            sampleRate: sampleRate
        )
        var cascade = BiquadCascade(config.bandPass)
        var noise = GaussianNoise(seed: 42)
        var sumSquares = 0.0
        let count = 2_000_000
        for _ in 0..<count {
            let y = cascade.process(noise.next()) * config.noiseNormalization
            sumSquares += y * y
        }
        XCTAssertEqual(sumSquares / Double(count), 1, accuracy: 0.1)
    }

    func testGaussianNoiseHasUnitVariance() {
        var noise = GaussianNoise(seed: 7)
        var sum = 0.0
        var sumSquares = 0.0
        let count = 200_000
        for _ in 0..<count {
            let x = noise.next()
            sum += x
            sumSquares += x * x
        }
        XCTAssertEqual(sum / Double(count), 0, accuracy: 0.01)
        XCTAssertEqual(sumSquares / Double(count), 1, accuracy: 0.02)
    }
}
