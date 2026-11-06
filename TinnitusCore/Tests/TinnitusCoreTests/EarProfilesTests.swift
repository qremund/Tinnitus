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
        // 4, 5, and 6 kHz are one pitch (median 5 kHz); 9 kHz is far enough away to get its own notch.
        XCTAssertEqual(ears.left.count, 2)
        XCTAssertEqual(ears.left[0].centerFrequencyHz, 5000, accuracy: 0.001)
        XCTAssertEqual(ears.left[1].centerFrequencyHz, 9000, accuracy: 0.001)
        XCTAssertEqual(ears.left, ears.right)
    }

    func testOnlyNewestThreeOfAPitchCount() {
        let profiles = [
            profile(4000, .left, daysAgo: 0),
            profile(4100, .left, daysAgo: 1),
            profile(4200, .left, daysAgo: 2),
            profile(3000, .left, daysAgo: 3),
        ]
        // 3 kHz is within half an octave of 4 kHz, so it's the same pitch, but only the newest three count.
        let left = EarProfiles.from(profiles, sameForBothEars: false).left
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left[0].centerFrequencyHz, 4100, accuracy: 0.001)
    }

    func testTwoPitchesInOneEarEachGetANotch() {
        // A 4 kHz tone and an 8 kHz tone, matched on alternate days. One median would land near 5.7 kHz.
        let profiles = [
            profile(4000, .left, daysAgo: 0),
            profile(8000, .left, daysAgo: 1),
            profile(4100, .left, daysAgo: 2),
            profile(7900, .left, daysAgo: 3),
        ]
        let left = EarProfiles.from(profiles, sameForBothEars: false).left.map(\.centerFrequencyHz)
        XCTAssertEqual(left.count, 2)
        XCTAssertEqual(left[0], (4000 * 4100).squareRoot(), accuracy: 0.01)
        XCTAssertEqual(left[1], (8000 * 7900).squareRoot(), accuracy: 0.01)
    }

    func testOnlyRecentMatchesCountInAutomatic() {
        var profiles = (0..<EarProfiles.automaticRecentMatches).map { profile(4000 + Double($0), .left, daysAgo: Double($0)) }
        profiles.append(profile(12_000, .left, daysAgo: 30))
        XCTAssertEqual(EarProfiles.from(profiles, sameForBothEars: false).left.count, 1)
    }

    func testMatchWidthWidensItsNotch() {
        var hiss = profile(4000, .left, daysAgo: 0)
        hiss.bandwidthOctaves = 1
        let pitches = EarProfiles.combining([hiss], sameForBothEars: false).pitches
        XCTAssertEqual(pitches.leftNotches, [NotchSpec(centerHz: 4000, matchedWidthOctaves: 1)])
        // A 1-octave hiss gets a 1.5-octave notch, wider than the 1/2-octave minimum.
        let band = NotchDesign.bands(notches: pitches.leftNotches, minimumWidthOctaves: 0.5)
        XCTAssertEqual(log2(band[0].high / band[0].low), 1.5, accuracy: 1e-9)
    }

    func testOldSavedMatchesWithoutVolumeStillLoad() throws {
        let json = #"[{"id":"7C9B6F40-0E57-4F7A-9D38-1C7D2B0C1A11","date":"2026-10-23T20:00:00Z","ear":"left","soundType":"tone","centerFrequencyHz":4000,"bandwidthOctaves":0,"thresholdDBFS":-70,"matchLevelDBFS":-60,"coarseRatings":[],"notes":""}]"#
        let matches = try MatchArchive.decode(TinnitusProfile.self, from: Data(json.utf8))
        XCTAssertEqual(matches.count, 1)
        XCTAssertNil(matches[0].phoneVolume)
        XCTAssertNil(matches[0].name)
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
