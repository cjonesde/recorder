import XCTest
@testable import VoiceCoach

final class SentenceStartTests: XCTestCase {
    private func run(lines: [CoachLine], seconds: Double, transcriptCues: Bool = true) -> CoachRun {
        let coach = makeCoach { $0.transcriptCues = transcriptCues; $0.promoted = [.pace, .soStarts]; $0.withholding = false }
        let mic = Synth.noise(seconds: seconds, db: -65, seed: 2)
        return feed(coach, mic: mic, desktop: quietDesktop(seconds: seconds), lines: lines)
    }

    func testCountsSoAtSentenceStartsOnly() {
        var counter = SentenceStartCounter(language: "en")
        let result = counter.observe(CoachLine(time: 1, text: "So we start. Not so fast. So, next.", isOwn: true))
        XCTAssertEqual(result.sentences, 3)
        XCTAssertEqual(result.starts, 2)
        XCTAssertEqual(result.matched, ["so", "so"])
    }

    func testLineWithoutPunctuationIsOneSentence() {
        var counter = SentenceStartCounter(language: "en")
        let result = counter.observe(CoachLine(time: 1, text: "so the numbers look fine", isOwn: true))
        XCTAssertEqual(result.sentences, 1)
        XCTAssertEqual(result.starts, 1)
    }

    func testGermanAlsoCounts() {
        var counter = SentenceStartCounter(language: "de")
        let result = counter.observe(CoachLine(time: 1, text: "Also, wir fangen an. So machen wir das. Dann weiter.", isOwn: true))
        XCTAssertEqual(result.sentences, 3)
        XCTAssertEqual(result.starts, 2)
        XCTAssertEqual(result.matched, ["also", "so"])
    }

    func testEnglishDoesNotCountAlso() {
        var counter = SentenceStartCounter(language: "en")
        XCTAssertEqual(counter.observe(CoachLine(time: 1, text: "Also this matters.", isOwn: true)).starts, 0)
    }

    func testOtherSpeakersLinesIgnored() {
        let lines = (1...8).map { CoachLine(time: Double($0), text: "So here we go.", isOwn: false) }
        let run = run(lines: lines, seconds: 10)
        XCTAssertTrue(run.triggers(.soStarts).isEmpty)
        XCTAssertEqual(run.samples(.soStarts).last?.values["sentences"], 0)
    }

    func testTriggerAfterThreeOfTen() {
        let texts = ["So first.", "So second.", "So third.", "Fourth.", "Fifth.", "Sixth.", "Seventh."]
        let lines = texts.enumerated().map { CoachLine(time: Double($0.offset + 1), text: $0.element, isOwn: true) }
        let run = run(lines: lines, seconds: 10)
        let triggers = run.triggers(.soStarts)
        XCTAssertEqual(triggers.count, 1)
        XCTAssertEqual(triggers.first?.shown, true)
        XCTAssertTrue(run.huds.contains { $0.litCues.contains(.soStarts) })
    }

    func testNoTriggerBelowFiveSentences() {
        let lines = (1...4).map { CoachLine(time: Double($0), text: "So yes.", isOwn: true) }
        XCTAssertTrue(run(lines: lines, seconds: 6).triggers(.soStarts).isEmpty)
    }

    func testRefractorySixtySeconds() {
        let lines = (1...70).map { CoachLine(time: Double($0), text: "So again.", isOwn: true) }
        let triggers = run(lines: lines, seconds: 72).triggers(.soStarts)
        XCTAssertEqual(triggers.count, 2)
        XCTAssertGreaterThanOrEqual((triggers.last?.t ?? 0) - (triggers.first?.t ?? 0), 60)
    }

    func testDisabledWhenEngineLags() {
        let lines = (1...8).map { CoachLine(time: Double($0), text: "So here we go.", isOwn: true) }
        let run = run(lines: lines, seconds: 10, transcriptCues: false)
        XCTAssertTrue(run.triggers(.soStarts).isEmpty)
        XCTAssertEqual(run.samples(.soStarts).last?.note, "engine lags")
    }

    func testLogNeverContainsText() throws {
        let lines = (1...8).map { CoachLine(time: Double($0), text: "So the secret plan works.", isOwn: true) }
        let run = run(lines: lines, seconds: 10)
        let encoder = JSONEncoder()
        for event in run.events {
            let json = String(decoding: try encoder.encode(event), as: UTF8.self)
            XCTAssertFalse(json.contains("secret"))
        }
    }

    func testSoClipCoversTheWholeLine() throws {
        let lines = (0..<7).map { index -> CoachLine in
            let start = 1 + Double(index) * 4
            return CoachLine(time: start, text: index < 3 ? "So here we go." : "Fine.", isOwn: true, end: start + 3)
        }
        let coach = makeCoach { $0.transcriptCues = true; $0.promoted = [.pace, .soStarts]; $0.withholding = false }
        let run = feed(coach, mic: Synth.noise(seconds: 36, db: -65, seed: 2), desktop: quietDesktop(seconds: 36), lines: lines, lineLag: 2)
        let trigger = try XCTUnwrap(run.triggers(.soStarts).first)
        let line = try XCTUnwrap(lines.first { abs($0.time - trigger.t) < 1e-9 })
        let clip = try XCTUnwrap(run.clips.first { $0.id == trigger.id })
        XCTAssertEqual(clip.start, line.time - 1, accuracy: 1e-9)
        XCTAssertEqual(clip.end, (line.end ?? 0) + 0.5, accuracy: 1e-9)
    }
}
