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

    func testEarWithoutMatchesIsUnfiltered() {
        let ears = EarProfiles.combining([profile(4000, .left, daysAgo: 0)], sameForBothEars: false)
        XCTAssertEqual(ears.pitches, EarPitches(left: 4000, right: nil))
        XCTAssertTrue(ears.pitches.notch(for: .right, widthOctaves: 1, sampleRate: 44_100).isEmpty)
    }

    func testAutomaticBecomesTheNewestMatchesThatFit() {
        // Five left matches and one both-ear match: the newest four that fit the left ear, plus the
        // both-ear match only if the left ear still has room.
        var matches = (0..<5).map { profile(3000 + Double($0) * 500, .left, daysAgo: Double($0)) }
        matches.append(profile(9000, .both, daysAgo: 10))
        matches.append(profile(7000, .right, daysAgo: 11))
        let picked = EarProfiles.newestFitting(matches, sameForBothEars: false)
        XCTAssertEqual(picked.map(\.centerFrequencyHz), [3000, 3500, 4000, 4500, 7000])
        let ears = EarProfiles.combining(picked, sameForBothEars: false)
        XCTAssertEqual(ears.left.count, 4)
        XCTAssertEqual(ears.right.count, 1)
    }

    func testNewestFittingWithSameNotchCountsEveryMatchInBothEars() {
        let matches = (0..<6).map { profile(2000 + Double($0) * 1000, $0.isMultiple(of: 2) ? .left : .right, daysAgo: Double($0)) }
        XCTAssertEqual(EarProfiles.newestFitting(matches, sameForBothEars: true).count, 4)
        XCTAssertEqual(EarProfiles.newestFitting(matches, sameForBothEars: false).count, 6)
    }

    func testSavedMatchesSortByEarThenPitchThenWidth() {
        var wide = profile(3000, .left, daysAgo: 0)
        wide.bandwidthOctaves = 0.5
        let narrow = profile(3000, .left, daysAgo: 1)
        let matches = [
            profile(2000, .both, daysAgo: 0),
            profile(5000, .right, daysAgo: 0),
            wide,
            profile(8000, .left, daysAgo: 0),
            narrow,
            profile(1000, .right, daysAgo: 0),
        ]
        let sorted = matches.sorted(by: TinnitusProfile.displayOrder)
        XCTAssertEqual(sorted.map(\.ear), [.left, .left, .left, .right, .right, .both])
        XCTAssertEqual(sorted.map(\.centerFrequencyHz), [3000, 3000, 8000, 1000, 5000, 2000])
        XCTAssertEqual(sorted[0].bandwidthOctaves, 0)
        XCTAssertEqual(sorted[1].bandwidthOctaves, 0.5)
    }

    func testPaletteShadesDarkenAndTextStaysReadable() {
        // Tile labels are bold 15 pt, which counts as large text: WCAG asks for 3:1 there. Every
        // shade in between the samples clears it too (the worst is about 4.3:1).
        XCTAssertGreaterThan(MatchPalette.pitch(250).luminance, MatchPalette.pitch(16_000).luminance)
        XCTAssertGreaterThan(MatchPalette.width(0).luminance, MatchPalette.width(1.0 / 32).luminance)
        XCTAssertGreaterThan(MatchPalette.width(1.0 / 32).luminance, MatchPalette.width(1).luminance)
        for hz in [250.0, 500, 1000, 2000, 4000, 8000, 16_000] {
            let c = MatchPalette.pitch(hz)
            XCTAssertGreaterThanOrEqual(c.contrast(with: c.readableText), 3, "pitch \(hz)")
        }
        for octaves in [0, 1.0 / 32, 1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1] {
            let c = MatchPalette.width(octaves)
            XCTAssertGreaterThanOrEqual(c.contrast(with: c.readableText), 3, "width \(octaves)")
        }
        for ear in Ear.allCases {
            let c = MatchPalette.ear(ear)
            XCTAssertGreaterThanOrEqual(c.contrast(with: c.readableText), 4.5, "ear \(ear)")
        }
    }

    func testNotchScaleEnds() {
        XCTAssertEqual(NotchScale.position(250), 0, accuracy: 1e-12)
        XCTAssertEqual(NotchScale.position(16_000), 1, accuracy: 1e-12)
        XCTAssertEqual(NotchScale.position(2000), 0.5, accuracy: 1e-12)
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
