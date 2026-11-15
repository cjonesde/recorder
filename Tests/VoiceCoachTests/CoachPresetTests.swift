import XCTest
@testable import VoiceCoach

final class CoachPresetTests: XCTestCase {
    func testPickFromAttendeeCount() {
        XCTAssertEqual(CoachPreset.pick(attendeeCount: nil), .presentation)
        XCTAssertEqual(CoachPreset.pick(attendeeCount: 0), .oneOnOne)
        XCTAssertEqual(CoachPreset.pick(attendeeCount: 1), .oneOnOne)
        XCTAssertEqual(CoachPreset.pick(attendeeCount: 2), .oneOnOne)
        XCTAssertEqual(CoachPreset.pick(attendeeCount: 3), .group)
        XCTAssertEqual(CoachPreset.pick(attendeeCount: 7), .group)
        XCTAssertEqual(CoachPreset.pick(attendeeCount: 8), .presentation)
        XCTAssertEqual(CoachPreset.pick(attendeeCount: 30), .presentation)
    }

    func testOverrideLogsPresetEvent() {
        let coach = makeCoach { $0.preset = .oneOnOne }
        XCTAssertTrue(coach.advance().events.first?.note?.contains("preset=oneOnOne") ?? false)
        coach.setPreset(.presentation)
        coach.setPreset(.presentation)
        let presets = coach.advance().events.filter { $0.kind == .preset }
        XCTAssertEqual(presets.map(\.note), ["override presentation"])
    }

    func testPresetChangesPaceRatio() {
        let audio = Synth.noise(seconds: 1, db: -65, seed: 5) + speech(seconds: 24, syllables: 4.6)
        let desktop = quietDesktop(seconds: 25.5)
        let probe = feed(makeCoach(), mic: audio, desktop: desktop)
        let rates = probe.samples(.pace).compactMap { $0.values["rate"] }.suffix(10)
        let measured = rates.reduce(0, +) / Double(rates.count)
        let baseline = measured / 1.15
        let presentation = feed(makeCoach { $0.baselineRate = baseline; $0.preset = .presentation }, mic: audio, desktop: desktop)
        let oneOnOne = feed(makeCoach { $0.baselineRate = baseline; $0.preset = .oneOnOne }, mic: audio, desktop: desktop)
        XCTAssertFalse(presentation.triggers(.pace).isEmpty)
        XCTAssertTrue(oneOnOne.triggers(.pace).isEmpty)
    }
}
