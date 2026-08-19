import XCTest
@testable import Recorder

final class RealtimeResamplerTests: XCTestCase {

    private let capacity = 8192

    private func convert(
        _ resampler: RealtimeResampler,
        _ input: [Float],
        chunk: Int? = nil
    ) -> [Float] {
        var output: [Float] = []
        var scratch = [Float](repeating: .nan, count: capacity)
        let step = chunk ?? input.count
        var offset = 0
        input.withUnsafeBufferPointer { src in
            scratch.withUnsafeMutableBufferPointer { dst in
                while offset < input.count {
                    let frames = min(step, input.count - offset)
                    let written = resampler.process(
                        src.baseAddress! + offset,
                        count: frames,
                        into: dst.baseAddress!,
                        capacity: capacity
                    )
                    output.append(contentsOf: UnsafeBufferPointer(start: dst.baseAddress!, count: written))
                    offset += frames
                }
            }
        }
        return output
    }

    // MARK: - The invariant the bug violated

    func testDeclaredOutputRateMatchesProducedSampleCount() {
        // Three seconds of real audio arriving at 16 kHz, declared as 48 kHz output.
        // The whole desktop-tap bug was that 16 kHz data was reported as 48 kHz
        // without conversion, so one second of audio yielded a third of the samples
        // the declared rate promises.
        let resampler = RealtimeResampler(outputRate: 48_000)
        resampler.reset(inputRate: 16_000)

        let seconds = 3
        let input = [Float](repeating: 0.25, count: 16_000 * seconds)
        let output = convert(resampler, input, chunk: 512)

        let expected = 48_000 * seconds
        XCTAssertEqual(Double(output.count), Double(expected), accuracy: 4)
    }

    func testDownsampleProducesDeclaredSampleCount() {
        let resampler = RealtimeResampler(outputRate: 16_000)
        resampler.reset(inputRate: 48_000)

        let seconds = 2
        let input = [Float](repeating: -0.1, count: 48_000 * seconds)
        let output = convert(resampler, input, chunk: 1024)

        XCTAssertEqual(Double(output.count), Double(16_000 * seconds), accuracy: 4)
    }

    // MARK: - Pass-through

    func testEqualRatesCopyExactly() {
        let resampler = RealtimeResampler(outputRate: 48_000)
        resampler.reset(inputRate: 48_000)
        XCTAssertTrue(resampler.isPassThrough)

        let input = (0..<1000).map { Float($0) / 1000 }
        let output = convert(resampler, input, chunk: 256)

        XCTAssertEqual(output, input)
    }

    // MARK: - Continuity across chunk boundaries

    func testRampStaysMonotonicAcrossChunks() {
        let resampler = RealtimeResampler(outputRate: 48_000)
        resampler.reset(inputRate: 16_000)

        // A long linear ramp: any discontinuity at a chunk seam shows up as a
        // non-monotonic step or a jump far from the expected slope.
        let input = (0..<16_000).map { Float($0) }
        let output = convert(resampler, input, chunk: 320)

        XCTAssertGreaterThan(output.count, 47_000)
        let expectedSlope: Float = 16_000.0 / 48_000.0
        for i in 1..<output.count {
            let delta = output[i] - output[i - 1]
            XCTAssertGreaterThan(delta, 0, "ramp went backwards at \(i)")
            XCTAssertEqual(delta, expectedSlope, accuracy: 0.05, "slope broke at \(i)")
        }
    }

    func testSineFrequencyIsPreservedWhenDownsampling() {
        let resampler = RealtimeResampler(outputRate: 16_000)
        resampler.reset(inputRate: 48_000)

        // One second of a 1 kHz sine at 48 kHz.
        let input = (0..<48_000).map { sinf(2 * .pi * 1000 * Float($0) / 48_000) }
        let output = convert(resampler, input, chunk: 512)

        var crossings = 0
        for i in 1..<output.count where (output[i - 1] < 0) != (output[i] < 0) {
            crossings += 1
        }
        // 1 kHz over ~1 second is ~2000 sign changes.
        XCTAssertEqual(Double(crossings), 2000, accuracy: 20)
    }

    // MARK: - Realtime safety constraints

    func testNeverWritesBeyondCapacity() {
        let resampler = RealtimeResampler(outputRate: 48_000)
        resampler.reset(inputRate: 16_000)

        let small = 64
        var scratch = [Float](repeating: .nan, count: small)
        let input = [Float](repeating: 0.5, count: 4096)

        let written = input.withUnsafeBufferPointer { src in
            scratch.withUnsafeMutableBufferPointer { dst in
                resampler.process(
                    src.baseAddress!,
                    count: input.count,
                    into: dst.baseAddress!,
                    capacity: small
                )
            }
        }
        XCTAssertLessThanOrEqual(written, small)
    }

    func testMaxInputFramesFitsTheGivenCapacity() {
        let resampler = RealtimeResampler(outputRate: 48_000)
        resampler.reset(inputRate: 16_000)

        let allowed = resampler.maxInputFrames(forOutputCapacity: capacity)
        XCTAssertGreaterThan(allowed, 0)

        let input = [Float](repeating: 0.3, count: allowed)
        var scratch = [Float](repeating: .nan, count: capacity)
        let written = input.withUnsafeBufferPointer { src in
            scratch.withUnsafeMutableBufferPointer { dst in
                resampler.process(
                    src.baseAddress!,
                    count: allowed,
                    into: dst.baseAddress!,
                    capacity: capacity
                )
            }
        }
        XCTAssertLessThanOrEqual(written, capacity)
        // And it should actually use most of the buffer, or the chunking is wasteful.
        XCTAssertGreaterThan(written, capacity - 16)
    }

    // MARK: - Rebuild behaviour

    func testResetAdoptsNewInputRateMidStream() {
        let resampler = RealtimeResampler(outputRate: 48_000)
        resampler.reset(inputRate: 48_000)

        let first = convert(resampler, [Float](repeating: 0.1, count: 48_000), chunk: 512)
        XCTAssertEqual(Double(first.count), 48_000, accuracy: 2)

        // The tap renegotiates to 16 kHz, exactly the Bluetooth case.
        resampler.reset(inputRate: 16_000)
        XCTAssertFalse(resampler.isPassThrough)

        let second = convert(resampler, [Float](repeating: 0.1, count: 16_000), chunk: 512)
        // One second of audio either way, so one second of output either way.
        XCTAssertEqual(Double(second.count), 48_000, accuracy: 4)
    }
}
