import XCTest
@testable import VoiceCoach

final class BaselineTests: XCTestCase {
    private func summary(_ rate: Double, level: Double = -25, seconds: Double = 300, language: String = "en") -> CoachSessionSummary {
        CoachSessionSummary(language: language, ownSpeechSeconds: seconds, articulationRate: rate, levelDB: level)
    }

    func testBaselineNeedsThreeLongSessions() {
        var baseline = CoachBaseline()
        baseline.record(summary(4.0), mic: "MacBook")
        baseline.record(summary(9.0, seconds: 60), mic: "MacBook")
        baseline.record(summary(5.0), mic: "MacBook")
        XCTAssertNil(baseline.rate(language: "en"))
        baseline.record(summary(4.5), mic: "MacBook")
        XCTAssertEqual(baseline.rate(language: "en"), 4.5)
        XCTAssertEqual(baseline.level(mic: "MacBook"), -25)
        XCTAssertNil(baseline.rate(language: "de"))
        XCTAssertNil(baseline.level(mic: "AirPods"))
    }

    func testBaselineKeepsLastTen() {
        var baseline = CoachBaseline()
        for i in 0..<15 { baseline.record(summary(Double(i)), mic: "m") }
        XCTAssertEqual(baseline.rates["en"], (5..<15).map(Double.init))
        XCTAssertEqual(baseline.rate(language: "en"), 9.5)
    }

    func testBaselineRoundTrips() throws {
        var baseline = CoachBaseline()
        for rate in [4.0, 4.2, 4.4] { baseline.record(summary(rate), mic: "m") }
        let decoded = try JSONDecoder().decode(CoachBaseline.self, from: JSONEncoder().encode(baseline))
        XCTAssertEqual(decoded, baseline)
    }
}
