import XCTest
@testable import VoiceCoach

final class GateTests: XCTestCase {
    private let tuning = CoachTuning.default

    private func classify(_ gate: inout OwnVoiceGate, mic: Double, desktop: (Int) -> Double?, at index: Int) -> GateState {
        let window = ((index - tuning.hangoverFrames)...(index + tuning.leadFrames)).map { desktop($0) }
        return gate.classify(micDB: mic, desktopDB: window)
    }

    private func primed() -> OwnVoiceGate {
        var gate = OwnVoiceGate(tuning: tuning)
        for _ in 0..<50 { _ = gate.classify(micDB: -70, desktopDB: [-90]) }
        return gate
    }

    func testOwnSpeechWithQuietTapIsOwn() {
        var gate = primed()
        XCTAssertEqual(classify(&gate, mic: -25, desktop: { _ in -90 }, at: 100), .own)
        XCTAssertEqual(classify(&gate, mic: -68, desktop: { _ in -90 }, at: 101), .silence)
    }

    func testTapActiveClosesGateFromLeadToHangover() {
        let desktop: (Int) -> Double? = { (100...199).contains($0) ? -20 : -90 }
        for index in 0..<300 {
            var gate = primed()
            let state = classify(&gate, mic: -25, desktop: desktop, at: index)
            if (70...249).contains(index) {
                XCTAssertNotEqual(state, .own, "frame \(index)")
            }
            if index == 60 || index == 260 {
                XCTAssertEqual(state, .own, "frame \(index)")
            }
        }
    }

    func testBleedNeverOpensGate() {
        var gate = primed()
        let desktop: (Int) -> Double? = { $0 % 50 < 40 ? -20 : -90 }
        for index in 0..<1000 {
            let deskNow = desktop(index) ?? -90
            let bleed = deskNow > -50 ? deskNow - 18 : -70
            let state = classify(&gate, mic: bleed, desktop: desktop, at: index)
            XCTAssertNotEqual(state, .own, "frame \(index)")
            XCTAssertNotEqual(state, .overlap, "frame \(index)")
        }
    }

    func testLoudOwnVoiceOverTapIsOverlap() {
        var gate = primed()
        XCTAssertEqual(classify(&gate, mic: -12, desktop: { _ in -25 }, at: 100), .overlap)
        XCTAssertEqual(classify(&gate, mic: -22, desktop: { _ in -25 }, at: 101), .them)
    }

    func testMissingDesktopIsUnknown() {
        var gate = primed()
        XCTAssertEqual(classify(&gate, mic: -25, desktop: { $0 > 105 ? nil : -90 }, at: 100), .unknown)
    }

    func testFloorTracksRoomNoise() {
        var gate = OwnVoiceGate(tuning: tuning)
        var rng = SplitMix64(seed: 3)
        for _ in 0..<1000 {
            _ = gate.classify(micDB: -55 + Double.random(in: -0.5...0.5, using: &rng), desktopDB: [-90])
        }
        XCTAssertEqual(gate.micFloorDB, -55, accuracy: 1.5)
        _ = gate.classify(micDB: -70, desktopDB: [-90])
        XCTAssertEqual(gate.micFloorDB, -70, accuracy: 0.01)
    }

    func testFloorFrozenWhileTapActive() {
        var gate = primed()
        let before = gate.micFloorDB
        for _ in 0..<1000 { _ = gate.classify(micDB: -30, desktopDB: [-20]) }
        XCTAssertEqual(gate.micFloorDB, before, accuracy: 0.01)
    }

    func testSpeechOverTheirCurrentAudioIsOverlap() {
        var gate = primed()
        XCTAssertEqual(classify(&gate, mic: -12, desktop: { _ in -30 }, at: 30), .overlap)
    }

    private func syllables(_ index: Int) -> Double { index % 30 < 20 ? -20 : -90 }

    func testSpeakerEchoIsNeverOverlapWhateverItsDelay() {
        for delay in [-10, 0, 10, 25, 45] {
            var gate = primed()
            var overlaps = 0
            for index in 0..<2000 where classify(&gate, mic: syllables(index - delay), desktop: syllables, at: index) == .overlap {
                overlaps += 1
            }
            XCTAssertEqual(overlaps, 0, "echo shifted \(delay * 10) ms against the call audio")
        }
    }

    func testEchoLouderThanTheCallAudioIsLearned() {
        var gate = primed()
        var lateOverlaps = 0
        for index in 0..<2000 {
            let state = classify(&gate, mic: syllables(index - 10) + 6, desktop: syllables, at: index)
            if index >= 500, state == .overlap { lateOverlaps += 1 }
        }
        XCTAssertEqual(lateOverlaps, 0)
        XCTAssertEqual(try XCTUnwrap(gate.echoGainDB), 6, accuracy: 0.5)
    }

    func testOwnVoiceAboveTheLearnedEchoIsOverlap() {
        var gate = primed()
        for index in 0..<1000 { _ = classify(&gate, mic: syllables(index - 10), desktop: syllables, at: index) }
        XCTAssertEqual(classify(&gate, mic: -8, desktop: syllables, at: 1000), .overlap)
        XCTAssertEqual(classify(&gate, mic: -18, desktop: syllables, at: 1001), .them)
    }

    func testHeadphonesLearnNoEchoAndCatchQuieterTalkingOver() {
        var gate = primed()
        for index in 0..<1000 { _ = classify(&gate, mic: -70, desktop: { _ in -20 }, at: index) }
        XCTAssertEqual(try XCTUnwrap(gate.echoGainDB), -50, accuracy: 0.5)
        XCTAssertEqual(classify(&gate, mic: -21, desktop: { _ in -20 }, at: 1000), .overlap)
    }
}
