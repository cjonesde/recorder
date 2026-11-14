import XCTest
@testable import VoiceCoach

final class PitchTrackerTests: XCTestCase {
    private func f0s(_ samples48k: [Float]) -> [Double] {
        let samples = Synth.downsampled(samples48k)
        let tracker = PitchTracker(tuning: .default)
        let span = CoachTuning.default.yinWindow + tracker.maxLag
        return stride(from: span, to: samples.count, by: 160).map { end in
            tracker.f0(samples[(end - span)..<end])
        }
    }

    func testYINFindsHarmonicPitch() {
        let values = f0s(Synth.steady(f0: 150, seconds: 0.5))
        XCTAssertFalse(values.isEmpty)
        for value in values { XCTAssertEqual(value, 150, accuracy: 3) }
    }

    func testYINFindsLowAndHighPitch() {
        for target in [80.0, 300.0] {
            let values = f0s(Synth.steady(f0: target, seconds: 0.5))
            for value in values { XCTAssertEqual(value, target, accuracy: target * 0.03) }
        }
    }

    func testYINReturnsZeroOnNoise() {
        let values = f0s(Synth.noise(seconds: 1, db: -30))
        let unvoiced = values.filter { $0 == 0 }.count
        XCTAssertGreaterThanOrEqual(Double(unvoiced) / Double(values.count), 0.9)
    }
}
