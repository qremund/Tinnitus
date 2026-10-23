import XCTest
@testable import TinnitusCore

/// Deterministic generator so shuffles are repeatable in tests.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class PitchMatchingTests: XCTestCase {
    func testCoarseFrequenciesSpan250HzTo16kHz() {
        let f = PitchMatching.coarseFrequencies
        XCTAssertEqual(f.count, 13)
        XCTAssertEqual(f.first!, 250, accuracy: 0.001)
        XCTAssertEqual(f.last!, 16_000, accuracy: 0.001)
    }

    func testOctaveCandidates() {
        XCTAssertEqual(PitchMatching.octaveCandidates(for: 3000), [1500, 3000, 6000])
        XCTAssertEqual(PitchMatching.octaveCandidates(for: 12_000), [6000, 12_000])
    }

    func testNotchEdgesForOneOctaveAt6kHz() {
        let edges = PitchMatching.notchEdges(centerHz: 6000, widthOctaves: 1)
        XCTAssertEqual(edges.low, 4243, accuracy: 1)
        XCTAssertEqual(edges.high, 8485, accuracy: 1)
    }

    func testBandwidthSliderRoundTrips() {
        XCTAssertEqual(PitchMatching.bandwidth(sliderPosition: 0), 0)
        XCTAssertEqual(PitchMatching.bandwidth(sliderPosition: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(PitchMatching.bandwidth(sliderPosition: 0.2), 1.0 / 16, accuracy: 1e-9)
        XCTAssertEqual(PitchMatching.sliderPosition(bandwidthOctaves: 1.0 / 16), 0.2, accuracy: 1e-9)
    }

    func testRatingSessionPlaysEachFrequencyThreeTimes() {
        var rng = SplitMix64(state: 1)
        let session = LikenessRatingSession(using: &rng)
        XCTAssertEqual(session.trials.count, 39)
        for f in PitchMatching.coarseFrequencies {
            XCTAssertEqual(session.trials.filter { $0.frequencyHz == f }.count, 3)
        }
    }

    func testRatingSessionFindsBestFrequency() {
        var rng = SplitMix64(state: 2)
        var session = LikenessRatingSession(using: &rng)
        let target = PitchMatching.coarseFrequencies[6] // about 2.83 kHz
        while let trial = session.currentTrial {
            session.rate(trial.frequencyHz == target ? 9 : 2)
        }
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.bestFrequencyHz!, target, accuracy: 0.001)
        XCTAssertEqual(session.meanRatings.count, 13)
    }

    func testRatingTieUsesGeometricMiddle() {
        var rng = SplitMix64(state: 3)
        var session = LikenessRatingSession(frequencies: [2000, 4000], repetitions: 1, using: &rng)
        session.rate(8)
        session.rate(8)
        XCTAssertEqual(session.bestFrequencyHz!, 2000 * 2.0.squareRoot(), accuracy: 0.001)
    }

    func testGoBackLetsYouRerate() {
        var rng = SplitMix64(state: 4)
        var session = LikenessRatingSession(frequencies: [1000], repetitions: 1, using: &rng)
        session.rate(3)
        session.goBack()
        session.rate(7)
        XCTAssertEqual(session.meanRatings.first?.meanRating, 7)
    }
}

final class TinnitusProfileTests: XCTestCase {
    private func profile(_ hz: Double, daysAgo: Double) -> TinnitusProfile {
        TinnitusProfile(
            date: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400),
            ear: .both,
            soundType: .tone,
            centerFrequencyHz: hz,
            bandwidthOctaves: 0.1,
            thresholdDBFS: -70,
            matchLevelDBFS: -60
        )
    }

    func testConsensusIsMedianPitch() {
        let result = TinnitusProfile.consensus(of: [profile(2800, daysAgo: 2), profile(3200, daysAgo: 1), profile(3000, daysAgo: 0)])!
        XCTAssertEqual(result.centerFrequencyHz, 3000, accuracy: 0.001)
        XCTAssertEqual(result.sensationLevelDB, 10)
    }

    func testConsensusOfOneIsItself() {
        let p = profile(3000, daysAgo: 0)
        XCTAssertEqual(TinnitusProfile.consensus(of: [p]), p)
        XCTAssertNil(TinnitusProfile.consensus(of: []))
    }

    func testProfileRoundTripsThroughJSON() throws {
        let p = profile(3000, daysAgo: 0)
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(TinnitusProfile.self, from: data), p)
    }
}
