import XCTest
@testable import Recorder

/// The IOProc sizes each chunk with `maxInputFrames(forOutputCapacity:)` and then
/// writes the conversion into a fixed preallocated buffer. If that math is ever
/// wrong the realtime path overruns its scratch buffer, so pin it down for every
/// rate pair a Core Audio tap realistically produces.
final class TapChunkingTests: XCTestCase {

    /// Mirrors `SystemAudioTap.resampleCapacity`.
    private let resampleCapacity = 16_384
    /// Mirrors `SystemAudioTap.scratchCapacity`.
    private let scratchCapacity = 16_384

    private static let rates: [Double] = [8_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 96_000]

    func testChunkedConversionNeverExceedsCapacityForAnyRatePair() {
        for canonical in Self.rates {
            for tapRate in Self.rates {
                let resampler = RealtimeResampler(outputRate: canonical)
                resampler.reset(inputRate: tapRate)

                var chunkLimit = scratchCapacity
                if !resampler.isPassThrough {
                    chunkLimit = min(chunkLimit, resampler.maxInputFrames(forOutputCapacity: resampleCapacity))
                }
                XCTAssertGreaterThan(chunkLimit, 0, "canonical \(canonical) tap \(tapRate)")

                // Feed a buffer larger than one chunk so the loop iterates, exactly as
                // the IOProc does for an oversized IO buffer.
                let input = [Float](repeating: 0.2, count: chunkLimit * 2 + 137)
                var out = [Float](repeating: .nan, count: resampleCapacity)

                var offset = 0
                var produced = 0
                input.withUnsafeBufferPointer { src in
                    out.withUnsafeMutableBufferPointer { dst in
                        while offset < input.count {
                            let chunk = min(input.count - offset, chunkLimit)
                            let written = resampler.process(
                                src.baseAddress! + offset,
                                count: chunk,
                                into: dst.baseAddress!,
                                capacity: resampleCapacity
                            )
                            XCTAssertLessThanOrEqual(
                                written, resampleCapacity,
                                "overflow at canonical \(canonical) tap \(tapRate)"
                            )
                            produced += written
                            offset += chunk
                        }
                    }
                }

                // Whatever the tap rate, the produced sample count must describe the
                // canonical rate: that equivalence is the invariant the garbled-transcript
                // bug broke.
                let seconds = Double(input.count) / tapRate
                let expected = seconds * canonical
                XCTAssertEqual(
                    Double(produced), expected,
                    accuracy: max(8, expected * 0.001),
                    "canonical \(canonical) tap \(tapRate)"
                )
            }
        }
    }

    func testPassThroughWhenTapMatchesCanonicalRate() {
        let resampler = RealtimeResampler(outputRate: 48_000)
        resampler.reset(inputRate: 48_000)
        XCTAssertTrue(resampler.isPassThrough)
        XCTAssertEqual(resampler.maxInputFrames(forOutputCapacity: resampleCapacity), resampleCapacity)
    }
}
