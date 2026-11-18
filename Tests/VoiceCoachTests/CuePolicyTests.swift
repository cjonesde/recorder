import XCTest
@testable import VoiceCoach

final class CuePolicyTests: XCTestCase {
    func testCueOffScheduleFades() {
        for off in [5, 10, 12, 15, 18, 22, 24] { XCTAssertTrue(CuePolicy.isCueOffSession(index: off, withholding: true), "\(off)") }
        for on in [1, 2, 4, 11, 13, 21, 23] { XCTAssertFalse(CuePolicy.isCueOffSession(index: on, withholding: true), "\(on)") }
    }

    func testNoCueOffSessionsOnceSkippingIsSwitchedOff() {
        for index in 1...40 { XCTAssertFalse(CuePolicy.isCueOffSession(index: index, withholding: false), "\(index)") }
    }

    func testShadowWhenNotPromoted() {
        var rng = SplitMix64(seed: 1)
        let config = CoachConfig(language: "en")
        XCTAssertEqual(CuePolicy.decide(.soStarts, config: config, random: &rng).note, "shadow")
        XCTAssertEqual(CuePolicy.decide(.raisedVoice, config: config, random: &rng).note, "shadow")
    }

    func testCoinFlipIsAboutHalf() {
        var rng = SplitMix64(seed: 7)
        let config = CoachConfig(language: "en")
        let shown = (0..<1000).filter { _ in CuePolicy.decide(.pace, config: config, random: &rng).shown }.count
        XCTAssertTrue((450...550).contains(shown), "\(shown)")
    }

    func testWithholdingOffAlwaysShows() {
        var rng = SplitMix64(seed: 7)
        var config = CoachConfig(language: "en")
        config.withholding = false
        XCTAssertTrue((0..<100).allSatisfy { _ in CuePolicy.decide(.pace, config: config, random: &rng).shown })
    }

    func testCueOffSessionWithholdsAll() {
        var rng = SplitMix64(seed: 7)
        var config = CoachConfig(language: "en")
        config.cueOffSession = true
        config.withholding = false
        let decision = CuePolicy.decide(.pace, config: config, random: &rng)
        XCTAssertFalse(decision.shown)
        XCTAssertEqual(decision.note, "cue-off session")
    }

    func testRaisedVoiceNeverPromotable() {
        var rng = SplitMix64(seed: 7)
        var config = CoachConfig(language: "en")
        config.promoted = Set(DetectorID.allCases)
        config.withholding = false
        XCTAssertFalse(CuePolicy.decide(.raisedVoice, config: config, random: &rng).shown)
    }
}
