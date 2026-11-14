import XCTest
@testable import VoiceCoach

final class GateTests: XCTestCase {
    private let tuning = CoachTuning.default

    private func classify(_ gate: inout OwnVoiceGate, mic: Double, desktop: (Int) -> Double?, at index: Int) -> GateState {
        let window = ((index - tuning.hangoverFrames)...(index + tuning.leadFrames)).map { desktop($0) }
        return gate.classify(micDB: mic, desktopDB: window, currentDesktopDB: desktop(index))
    }

    private func primed() -> OwnVoiceGate {
        var gate = OwnVoiceGate(tuning: tuning)
        for _ in 0..<50 { _ = gate.classify(micDB: -70, desktopDB: [-90], currentDesktopDB: -90) }
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
            _ = gate.classify(micDB: -55 + Double.random(in: -0.5...0.5, using: &rng), desktopDB: [-90], currentDesktopDB: -90)
        }
        XCTAssertEqual(gate.micFloorDB, -55, accuracy: 1.5)
        _ = gate.classify(micDB: -70, desktopDB: [-90], currentDesktopDB: -90)
        XCTAssertEqual(gate.micFloorDB, -70, accuracy: 0.01)
    }

    func testFloorFrozenWhileTapActive() {
        var gate = primed()
        let before = gate.micFloorDB
        for _ in 0..<1000 { _ = gate.classify(micDB: -30, desktopDB: [-20], currentDesktopDB: -20) }
        XCTAssertEqual(gate.micFloorDB, before, accuracy: 0.01)
    }

    func testDesktopStallMarksUnknownAfterTwoSeconds() throws {
        throw XCTSkip("engine-level, enabled in VoiceCoachEngineTests")
    }
}
