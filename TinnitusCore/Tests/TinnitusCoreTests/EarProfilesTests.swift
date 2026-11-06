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
        XCTAssertEqual(ears.left.first!.centerFrequencyHz, 4200, accuracy: 0.001)
        XCTAssertEqual(ears.right.first!.centerFrequencyHz, 5000, accuracy: 0.001)
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
        XCTAssertEqual(ears.left.first!.centerFrequencyHz, 5000, accuracy: 0.001)
        XCTAssertEqual(ears.left, ears.right)
    }

    func testOnlyNewestThreePerEarCount() {
        let profiles = [
            profile(4000, .left, daysAgo: 0),
            profile(4100, .left, daysAgo: 1),
            profile(4200, .left, daysAgo: 2),
            profile(9000, .left, daysAgo: 3),
        ]
        XCTAssertEqual(EarProfiles.from(profiles, sameForBothEars: false).left.first!.centerFrequencyHz, 4100, accuracy: 0.001)
    }

    func testNoProfiles() {
        XCTAssertTrue(EarProfiles.from([], sameForBothEars: false).isEmpty)
        XCTAssertTrue(EarProfiles.from([], sameForBothEars: true).pitches.isEmpty)
    }

    func testProfilePutsEachMatchInItsOwnEar() {
        let left1 = profile(6000, .left, daysAgo: 0)
        let left2 = profile(3000, .left, daysAgo: 1)
        let right = profile(4000, .right, daysAgo: 2)
        let both = profile(8000, .both, daysAgo: 3)
        let ears = EarProfiles.combining([left1, left2, right, both], sameForBothEars: false)
        XCTAssertEqual(ears.pitches, EarPitches(left: [3000, 6000, 8000], right: [4000, 8000]))
        XCTAssertEqual(ears.matches(for: .both), [both])
    }

    func testProfileWithSameForBothEarsMirrorsEveryMatch() {
        let ears = EarProfiles.combining([profile(3000, .left, daysAgo: 0), profile(5000, .right, daysAgo: 1)], sameForBothEars: true)
        XCTAssertEqual(ears.pitches, EarPitches(left: [3000, 5000], right: [3000, 5000]))
        XCTAssertTrue(ears.pitches.isSameInBothEars)
    }

    func testEmptyProfileIsUnfiltered() {
        XCTAssertTrue(EarProfiles.combining([], sameForBothEars: false).pitches.isEmpty)
    }

    func testMatchProfileRoundTripsAsJSON() throws {
        let original = MatchProfile(name: "Night", matchIDs: [UUID(), UUID()])
        let decoded = try JSONDecoder().decode(MatchProfile.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testMedianDropsTheNewestMatchName() {
        var named = profile(3000, .both, daysAgo: 0)
        named.name = "Evening"
        let median = TinnitusProfile.consensus(of: [named, profile(3100, .both, daysAgo: 1)])
        XCTAssertNil(median?.name)
    }
}
