import XCTest
@testable import TinnitusCore

final class NotchProcessorTests: XCTestCase {
    let sampleRate = 44_100.0

    /// RMS of a sine after the processor, skipping the start so the filter has settled.
    private func filteredRMS(hz: Double, processor: inout NotchProcessor, blockSize: Int = 4096) -> Double {
        let total = Int(sampleRate)
        var samples = (0..<total).map { Float(sin(2 * Double.pi * hz * Double($0) / sampleRate)) }
        samples.withUnsafeMutableBufferPointer { buffer in
            var start = 0
            while start < total {
                let count = min(blockSize, total - start)
                processor.process(buffer.baseAddress! + start, frameCount: count, channel: 0)
                start += count
            }
        }
        let tail = samples[(total / 2)...]
        return sqrt(tail.reduce(0) { $0 + Double($1 * $1) } / Double(tail.count))
    }

    func testRemovesCenterAndPassesMusicBand() {
        var notched = NotchProcessor.forTinnitus(centerHz: 3000, widthOctaves: 1, sampleRate: sampleRate, channelCount: 1)
        XCTAssertLessThan(filteredRMS(hz: 3000, processor: &notched), 0.001)

        var passed = NotchProcessor.forTinnitus(centerHz: 3000, widthOctaves: 1, sampleRate: sampleRate, channelCount: 1)
        XCTAssertEqual(filteredRMS(hz: 440, processor: &passed), 1 / 2.0.squareRoot(), accuracy: 0.01)
    }

    func testBlockSizeDoesNotChangeOutput() {
        var small = NotchProcessor.forTinnitus(centerHz: 3000, widthOctaves: 0.5, sampleRate: sampleRate, channelCount: 1)
        var large = NotchProcessor.forTinnitus(centerHz: 3000, widthOctaves: 0.5, sampleRate: sampleRate, channelCount: 1)
        XCTAssertEqual(
            filteredRMS(hz: 2500, processor: &small, blockSize: 333),
            filteredRMS(hz: 2500, processor: &large, blockSize: 32_768),
            accuracy: 1e-6
        )
    }

    func testChannelsAreIndependent() {
        var processor = NotchProcessor.forTinnitus(centerHz: 3000, widthOctaves: 1, sampleRate: sampleRate, channelCount: 2)
        var left = [Float](repeating: 0, count: 256)
        var right = [Float](repeating: 0, count: 256)
        left[0] = 1
        left.withUnsafeMutableBufferPointer { processor.process($0.baseAddress!, frameCount: 256, channel: 0) }
        right.withUnsafeMutableBufferPointer { processor.process($0.baseAddress!, frameCount: 256, channel: 1) }
        XCTAssertTrue(right.allSatisfy { $0 == 0 })
        XCTAssertNotEqual(left[1], 0)
    }

    func testEachEarGetsItsOwnNotch() {
        let pitches = EarPitches(left: 3000, right: 6000)
        var processor = NotchProcessor.forTinnitus(pitches: pitches, widthOctaves: 1, sampleRate: sampleRate, channelCount: 2)
        let total = Int(sampleRate)
        var left = (0..<total).map { Float(sin(2 * Double.pi * 3000 * Double($0) / sampleRate)) }
        var right = left
        left.withUnsafeMutableBufferPointer { processor.process($0.baseAddress!, frameCount: total, channel: 0) }
        right.withUnsafeMutableBufferPointer { processor.process($0.baseAddress!, frameCount: total, channel: 1) }
        func rms(_ x: [Float]) -> Double {
            let tail = x[(total / 2)...]
            return (tail.reduce(0) { $0 + Double($1) * Double($1) } / Double(tail.count)).squareRoot()
        }
        // 3 kHz sits in the left notch but well below the right one (4.2 to 8.5 kHz).
        XCTAssertLessThan(rms(left), 0.001)
        XCTAssertGreaterThan(rms(right), 0.6)
    }

    func testEarWithoutPitchPassesThrough() {
        var processor = NotchProcessor.forTinnitus(pitches: EarPitches(left: 3000, right: nil), widthOctaves: 1, sampleRate: sampleRate, channelCount: 2)
        var samples: [Float] = [0.5, -0.25, 1]
        samples.withUnsafeMutableBufferPointer { processor.process($0.baseAddress!, frameCount: 3, channel: 1) }
        XCTAssertEqual(samples, [0.5, -0.25, 1])
    }

    func testEmptyNotchPassesThrough() {
        var processor = NotchProcessor(channelCount: 1, coefficients: [])
        var samples: [Float] = [0.5, -0.25, 1]
        samples.withUnsafeMutableBufferPointer { processor.process($0.baseAddress!, frameCount: 3, channel: 0) }
        XCTAssertEqual(samples, [0.5, -0.25, 1])
    }

    func testTwoNotchesInOneEar() {
        // Half-octave notches at 3 and 6 kHz, both in the left ear; 4.24 kHz sits between them.
        let processor = NotchProcessor.forTinnitus(pitches: EarPitches(left: [3000, 6000], right: []), widthOctaves: 0.5, sampleRate: sampleRate, channelCount: 2)
        func rmsAfter(_ hz: Double) -> Double {
            var copy = processor
            let total = Int(sampleRate)
            var x = (0..<total).map { Float(sin(2 * Double.pi * hz * Double($0) / sampleRate)) }
            x.withUnsafeMutableBufferPointer { copy.process($0.baseAddress!, frameCount: total, channel: 0) }
            let tail = x[(total / 2)...]
            return (tail.reduce(0) { $0 + Double($1) * Double($1) } / Double(tail.count)).squareRoot()
        }
        XCTAssertLessThan(rmsAfter(3000), 0.001)
        XCTAssertLessThan(rmsAfter(6000), 0.001)
        XCTAssertGreaterThan(rmsAfter(4243), 0.4)
        XCTAssertEqual(processor.channels[0].sections.count, 8)
        XCTAssertTrue(processor.channels[1].sections.isEmpty)
    }

    func testOverlappingNotchesMerge() {
        let bands = NotchDesign.bands(centersHz: [3000, 3300, 8000], widthOctaves: 0.5)
        XCTAssertEqual(bands.count, 2)
        XCTAssertEqual(bands[0].low, 3000 * pow(2, -0.25), accuracy: 0.01)
        XCTAssertEqual(bands[0].high, 3300 * pow(2, 0.25), accuracy: 0.01)
    }

    func testTooManyNotchesJoinTheClosestNeighbors() {
        let bands = NotchDesign.bands(centersHz: [500, 1000, 2000, 2500, 8000, 16000], widthOctaves: 0.1, maxBands: 4)
        XCTAssertEqual(bands.count, 4)
        // Six notches become four, and every pitch stays inside a band.
        for center in [500.0, 1000, 2000, 2500, 8000, 16000] {
            XCTAssertTrue(bands.contains { $0.low <= center && center <= $0.high }, "\(center) not notched")
        }
    }
}
