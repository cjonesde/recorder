import XCTest
@testable import VoiceCoach

final class DownsamplerTests: XCTestCase {
    private func run(rate: Double, chunks: [Int]) -> Int {
        var downsampler = Downsampler()
        var out: [Float] = []
        for size in chunks {
            let chunk = [Float](repeating: 0.1, count: size)
            chunk.withUnsafeBufferPointer { downsampler.process($0, rate: rate, into: &out) }
        }
        return out.count
    }

    func testDownsampling48kPreservesDuration() {
        let chunks = [1, 4095, 512, 10_000, 7, 13_385, 20_000]
        XCTAssertEqual(chunks.reduce(0, +), 48_000)
        XCTAssertEqual(Double(run(rate: 48_000, chunks: chunks)), 16_000, accuracy: 1)
    }

    func testDownsampling44_1kPreservesDuration() {
        let chunks = [441, 4410, 39_249]
        XCTAssertEqual(chunks.reduce(0, +), 44_100)
        XCTAssertEqual(Double(run(rate: 44_100, chunks: chunks)), 16_000, accuracy: 1)
    }

    func testSixteenKilohertzPassesThrough() {
        XCTAssertEqual(run(rate: 16_000, chunks: [1000, 15_000]), 16_000)
    }

    func testToneSurvivesDownsampling() {
        let tone = Synth.steady(f0: 200, seconds: 1, levelDB: -20)
        let out = Synth.downsampled(tone)
        let rms = sqrt(out.dropFirst(1000).map { Double($0 * $0) }.reduce(0, +) / Double(out.count - 1000))
        XCTAssertEqual(20 * log10(rms), -20, accuracy: 0.5)
    }
}
