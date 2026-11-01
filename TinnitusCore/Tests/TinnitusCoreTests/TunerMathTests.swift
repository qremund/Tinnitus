import XCTest
@testable import TinnitusCore

final class TunerMathTests: XCTestCase {
    func testPitchPositionIsLogarithmicAndRoundTrips() {
        XCTAssertEqual(TunerMath.pitchPosition(250), 0)
        XCTAssertEqual(TunerMath.pitchPosition(16_000), 1)
        // 2 kHz is 3 of the 6 octaves above 250 Hz.
        XCTAssertEqual(TunerMath.pitchPosition(2000), 0.5, accuracy: 1e-12)
        for hz in [300.0, 3150, 11_000] {
            XCTAssertEqual(TunerMath.pitch(atPosition: TunerMath.pitchPosition(hz)), hz, accuracy: 1e-6)
        }
        XCTAssertEqual(TunerMath.pitchPosition(50), 0)
        XCTAssertEqual(TunerMath.pitch(atPosition: 2), 16_000)
    }

    func testLevelNeverExceedsSafetyCap() {
        XCTAssertEqual(TunerMath.level(atPosition: 1), SafetyLimits.maxTestLevelDBFS)
        XCTAssertEqual(TunerMath.level(atPosition: 5), SafetyLimits.maxTestLevelDBFS)
        XCTAssertEqual(TunerMath.level(atPosition: 0), TunerMath.minLevelDBFS)
        XCTAssertEqual(TunerMath.levelPosition(TunerMath.level(atPosition: 0.3)), 0.3, accuracy: 1e-12)
    }

    func testSoundTypeFromWidth() {
        XCTAssertEqual(TunerMath.soundType(forBandwidthOctaves: 0), .tone)
        XCTAssertEqual(TunerMath.soundType(forBandwidthOctaves: 1.0 / 32), .narrowHiss)
        XCTAssertEqual(TunerMath.soundType(forBandwidthOctaves: 1.0 / 8), .narrowHiss)
        XCTAssertEqual(TunerMath.soundType(forBandwidthOctaves: 1.0 / 7), .narrowHiss)
        XCTAssertEqual(TunerMath.soundType(forBandwidthOctaves: 1.0 / 3), .narrowHiss)
        XCTAssertEqual(TunerMath.soundType(forBandwidthOctaves: 1.0 / 2), .broadHiss)
    }

    func testDialMapsAnglesAcrossTheSweep() {
        // Lower left is the start, straight up is the middle, lower right is the end.
        XCTAssertEqual(TunerMath.dialFraction(dx: -1, dy: 1), 0, accuracy: 1e-9)
        XCTAssertEqual(TunerMath.dialFraction(dx: 0, dy: -1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(TunerMath.dialFraction(dx: 1, dy: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(TunerMath.dialFraction(dx: -1, dy: 0), 45.0 / 270, accuracy: 1e-9)
        // The bottom gap snaps to the nearer end.
        XCTAssertEqual(TunerMath.dialFraction(dx: -0.1, dy: 1), 0)
        XCTAssertEqual(TunerMath.dialFraction(dx: 0.1, dy: 1), 1)
        for fraction in [0.0, 0.25, 0.8, 1.0] {
            let radians = TunerMath.dialAngleDegrees(fraction: fraction) * .pi / 180
            XCTAssertEqual(TunerMath.dialFraction(dx: cos(radians), dy: sin(radians)), fraction, accuracy: 1e-9)
        }
    }
}
