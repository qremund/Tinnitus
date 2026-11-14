import XCTest
@testable import TinnitusCore

final class MatchScreenTests: XCTestCase {
    func testOneSoundIsOnlyCapped() {
        XCTAssertEqual(SafetyLimits.combinedTestLevels([-40]), [-40])
        XCTAssertEqual(SafetyLimits.combinedTestLevels([0]), [SafetyLimits.maxTestLevelDBFS])
    }

    func testQuietSoundsTogetherKeepTheirLevels() {
        XCTAssertEqual(SafetyLimits.combinedTestLevels([-50, -45, -60]), [-50, -45, -60])
    }

    func testLoudSoundsTogetherNeverPassTheCap() {
        let levels = SafetyLimits.combinedTestLevels([-12, -12, -15, -20])
        let total = 10 * log10(levels.reduce(0) { $0 + pow(10, $1 / 10) })
        XCTAssertEqual(total, SafetyLimits.maxTestLevelDBFS, accuracy: 1e-9)
        // All come down by the same amount, so their balance stays the same.
        XCTAssertEqual(levels[0] - levels[2], 3, accuracy: 1e-9)
        XCTAssertEqual(levels[0] - levels[3], 8, accuracy: 1e-9)
    }

    func testTapSelectsTheNotchUnderIt() {
        let notches = [
            NotchPicker.Notch(id: "low", lowHz: 900, highHz: 1100),
            NotchPicker.Notch(id: "high", lowHz: 7000, highHz: 9000),
        ]
        XCTAssertEqual(NotchPicker.hits(at: NotchScale.position(8000), in: notches, minimumSpan: 0.05), ["high"])
        XCTAssertEqual(NotchPicker.hits(at: NotchScale.position(3000), in: notches, minimumSpan: 0.05), [])
    }

    func testNarrowNotchIsStillEasyToHit() {
        let tone = [NotchPicker.Notch(id: 1, lowHz: 3990, highHz: 4010)]
        let nearby = NotchScale.position(4000) + 0.02
        XCTAssertEqual(NotchPicker.hits(at: nearby, in: tone, minimumSpan: 0.05), [1])
        XCTAssertEqual(NotchPicker.hits(at: nearby, in: tone, minimumSpan: 0.01), [])
    }

    func testTappingOverlappingNotchesStepsThroughThem() {
        let notches = [
            NotchPicker.Notch(id: "wide", lowHz: 2000, highHz: 8000),
            NotchPicker.Notch(id: "narrow", lowHz: 3800, highHz: 4200),
            NotchPicker.Notch(id: "elsewhere", lowHz: 500, highHz: 600),
        ]
        let hits = NotchPicker.hits(at: NotchScale.position(4000), in: notches, minimumSpan: 0.05)
        XCTAssertEqual(Set(hits), ["wide", "narrow"])
        let first = NotchPicker.pick(hits, current: "elsewhere")
        XCTAssertEqual(first, hits[0])
        let second = NotchPicker.pick(hits, current: first)
        XCTAssertEqual(second, hits[1])
        XCTAssertEqual(NotchPicker.pick(hits, current: second), first)
        XCTAssertNil(NotchPicker.pick([String](), current: "wide"))
    }
}
