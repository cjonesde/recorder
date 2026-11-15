import XCTest
@testable import VoiceCoach

final class VoiceCoachEngineTests: XCTestCase {
    func testFirstAdvanceLogsSession() {
        let coach = makeCoach()
        let output = coach.advance()
        XCTAssertEqual(output.events.first?.kind, .session)
        XCTAssertEqual(output.events.first?.note, "language=en preset=presentation promoted=pace")
        XCTAssertEqual(coach.advance().events.filter { $0.kind == .session }.count, 0)
    }

    func testSamplesLoggedOncePerSecond() {
        let coach = makeCoach()
        let run = feed(coach, mic: speech(seconds: 10.5), desktop: quietDesktop(seconds: 10.5))
        XCTAssertEqual(run.events.filter { $0.kind == .sample && $0.note == "gate" }.count, 10)
    }

    func testOwnSpeechWithQuietTapCountsAsOwn() {
        let coach = makeCoach()
        let run = feed(coach, mic: speech(seconds: 6), desktop: quietDesktop(seconds: 6))
        XCTAssertGreaterThan(coach.ownSpeechSeconds, 2.5)
        XCTAssertNotEqual(run.last?.gate, .them)
    }

    func testRemoteSpeechThroughSpeakersProducesNoOwnSpeech() {
        let remote = Synth.voice(f0: { _ in 210 }, syllablesPerSecond: 4.5, seconds: 10, levelDB: -20, envelope: { t in (3...4).contains(t) ? 0 : 1 }, noiseDB: -80)
        var mic = Synth.delayed(remote, seconds: 0.04, gainDB: -18)
        Synth.mix(&mic, Synth.noise(seconds: 10, db: -65, seed: 4))
        let coach = makeCoach()
        let run = feed(coach, mic: mic, desktop: remote)
        XCTAssertEqual(coach.ownSpeechSeconds, 0)
        XCTAssertTrue(run.huds.allSatisfy { $0.gate != .own })
    }

    func testDesktopStallMarksUnknownAfterTwoSeconds() {
        let coach = makeCoach()
        let run = feed(coach, mic: speech(seconds: 5), desktop: quietDesktop(seconds: 1))
        XCTAssertEqual(run.last?.gate, .unknown)
        XCTAssertEqual(run.events.filter { $0.kind == .gap }.count, 1)
        let firstGap = run.events.first { $0.kind == .gap }!
        XCTAssertEqual(firstGap.t, 0.71, accuracy: 0.015)
    }

    func testEventsRoundTripAsJSONLines() throws {
        let event = CoachEvent(t: 1.23456, kind: .trigger, detector: .pace, values: ["rate": 5.123456789, "bad": .nan], shown: false, note: "withheld", id: "pace-1235")
        let data = try JSONEncoder().encode(event)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\n"))
        let decoded = try JSONDecoder().decode(CoachEvent.self, from: data)
        XCTAssertEqual(decoded, event)
        XCTAssertNil(decoded.values["bad"])
        XCTAssertEqual(decoded.t, 1.235)
    }

    func testPresetOverrideLogged() {
        let coach = makeCoach()
        _ = coach.advance()
        coach.setPreset(.group)
        let events = coach.advance().events
        XCTAssertEqual(events.map(\.kind), [.preset])
        XCTAssertEqual(coach.advance().hud.preset, .group)
    }

    func testClearCuesTurnsLitCuesOff() {
        let coach = makeCoach { $0.withholding = false }
        feed(coach, mic: Synth.noise(seconds: 2, db: -65, seed: 3), desktop: quietDesktop(seconds: 2.5))
        coach.fire(.pace, at: 2)
        XCTAssertTrue(coach.advance().hud.litCues.contains(.pace))
        coach.clearCues()
        XCTAssertTrue(coach.advance().hud.litCues.isEmpty)
    }
}
