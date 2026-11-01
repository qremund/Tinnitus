import XCTest
@testable import TinnitusCore

final class EarProfilesTests: XCTestCase {
    private func profile(_ hz: Double, _ ear: Ear, daysAgo: Double) -> TinnitusProfile {
        TinnitusProfile(
            date: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400),
            ear: ear,
            soundType: .tone,
            centerFrequencyHz: hz,
            bandwidthOctaves: 0,
            thresholdDBFS: -70,
            matchLevelDBFS: -60
        )
    }

    func testEachEarUsesItsOwnMatches() {
        let profiles = [profile(4000, .left, daysAgo: 0), profile(6000, .right, daysAgo: 1)]
        let ears = EarProfiles.from(profiles, sameForBothEars: false)
        XCTAssertEqual(ears.pitches, EarPitches(left: 4000, right: 6000))
        XCTAssertFalse(ears.pitches.isSameInBothEars)
    }

    func testBothEarMatchesCountForEachEar() {
        let profiles = [profile(4000, .left, daysAgo: 0), profile(5000, .both, daysAgo: 1), profile(4200, .left, daysAgo: 2)]
        let ears = EarProfiles.from(profiles, sameForBothEars: false)
        // Left: median of 4000, 5000, 4200. Right: only the "both" match.
        XCTAssertEqual(ears.left!.centerFrequencyHz, 4200, accuracy: 0.001)
        XCTAssertEqual(ears.right!.centerFrequencyHz, 5000, accuracy: 0.001)
    }

    func testEarWithoutMatchesIsUnfiltered() {
        let ears = EarProfiles.from([profile(4000, .left, daysAgo: 0)], sameForBothEars: false)
        XCTAssertEqual(ears.pitches, EarPitches(left: 4000, right: nil))
        XCTAssertTrue(ears.pitches.notch(for: .right, widthOctaves: 1, sampleRate: 44_100).isEmpty)
    }

    func testSameForBothEarsUsesNewestThreeOfAnyEar() {
        let profiles = [
            profile(4000, .left, daysAgo: 0),
            profile(6000, .right, daysAgo: 1),
            profile(5000, .both, daysAgo: 2),
            profile(9000, .right, daysAgo: 3),
        ]
        let ears = EarProfiles.from(profiles, sameForBothEars: true)
        XCTAssertEqual(ears.left!.centerFrequencyHz, 5000, accuracy: 0.001)
        XCTAssertEqual(ears.left, ears.right)
    }

    func testOnlyNewestThreePerEarCount() {
        let profiles = [
            profile(4000, .left, daysAgo: 0),
            profile(4100, .left, daysAgo: 1),
            profile(4200, .left, daysAgo: 2),
            profile(9000, .left, daysAgo: 3),
        ]
        XCTAssertEqual(EarProfiles.from(profiles, sameForBothEars: false).left!.centerFrequencyHz, 4100, accuracy: 0.001)
    }

    func testNoProfiles() {
        XCTAssertTrue(EarProfiles.from([], sameForBothEars: false).isEmpty)
        XCTAssertTrue(EarProfiles.from([], sameForBothEars: true).pitches.isEmpty)
    }

    func testChosenMatchOverridesTheMedianForThatEar() {
        let old = profile(2000, .left, daysAgo: 5)
        let profiles = [profile(3000, .left, daysAgo: 1), profile(3200, .right, daysAgo: 0), old]
        let ears = EarProfiles.resolve(profiles, sameForBothEars: false, leftChoice: old.id, rightChoice: nil)
        XCTAssertEqual(ears.left, old)
        XCTAssertEqual(ears.right?.centerFrequencyHz ?? 0, 3200, accuracy: 0.01)
    }

    func testChoiceCanUseAnotherEarsMatchAndIgnoresMissingIDs() {
        let right = profile(4000, .right, daysAgo: 0)
        let profiles = [profile(3000, .left, daysAgo: 1), right]
        let ears = EarProfiles.resolve(profiles, sameForBothEars: false, leftChoice: right.id, rightChoice: UUID())
        XCTAssertEqual(ears.left, right)
        XCTAssertEqual(ears.right, right)
    }

    func testMedianDropsTheNewestMatchName() {
        var named = profile(3000, .both, daysAgo: 0)
        named.name = "Evening"
        let median = TinnitusProfile.consensus(of: [named, profile(3100, .both, daysAgo: 1)])
        XCTAssertNil(median?.name)
    }
}
