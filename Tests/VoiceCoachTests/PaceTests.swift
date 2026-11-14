import XCTest
@testable import VoiceCoach

final class PaceTests: XCTestCase {
    private func talk(_ seconds: Double, syllables: Double, pauses: Bool = false) -> [Float] {
        var signal = Synth.noise(seconds: 1, db: -65, seed: 5)
        if pauses {
            var t = 0.0
            while t < seconds {
                signal += speech(seconds: 3, syllables: syllables, seed: UInt64(t + 2))
                signal += Synth.noise(seconds: 2, db: -65, seed: UInt64(t + 50))
                t += 5
            }
        } else {
            signal += speech(seconds: seconds, syllables: syllables)
        }
        return signal
    }

    private func lastRate(_ run: CoachRun) -> Double? {
        run.samples(.pace).last { $0.values["rate"] != nil }?.values["rate"]
    }

    func testSyllableCountMatchesSyntheticTrain() {
        let audio = talk(20, syllables: 4)
        let run = feed(makeCoach(), mic: audio, desktop: quietDesktop(seconds: 21))
        let rate = lastRate(run)
        XCTAssertNotNil(rate)
        XCTAssertEqual(rate ?? 0, 4.0, accuracy: 0.4)
    }

    func testFastTrainMeasuresFaster() {
        let audio = talk(15, syllables: 6)
        let run = feed(makeCoach(), mic: audio, desktop: quietDesktop(seconds: 16))
        XCTAssertEqual(lastRate(run) ?? 0, 6.0, accuracy: 0.6)
    }

    func testRateIgnoresPauses() {
        let audio = talk(30, syllables: 4, pauses: true)
        let run = feed(makeCoach(), mic: audio, desktop: quietDesktop(seconds: 31))
        XCTAssertEqual(lastRate(run) ?? 0, 4.0, accuracy: 0.45)
    }

    func testNoTriggerBeforeBaseline() {
        let audio = talk(100, syllables: 7)
        let run = feed(makeCoach(), mic: audio, desktop: quietDesktop(seconds: 101))
        XCTAssertTrue(run.triggers(.pace).isEmpty)
        XCTAssertTrue(run.samples(.pace).allSatisfy { $0.values["ratio"] == nil })
        XCTAssertTrue(run.samples(.pace).contains { $0.note == "no baseline" })
    }

    func testTriggersWhenFasterThanBaseline() {
        let audio = talk(25, syllables: 6)
        let run = feed(makeCoach { $0.baselineRate = 4.0 }, mic: audio, desktop: quietDesktop(seconds: 26))
        let triggers = run.triggers(.pace)
        XCTAssertEqual(triggers.count, 1)
        XCTAssertLessThan(triggers.first?.t ?? 99, 15)
        XCTAssertNotNil(triggers.first?.id)
    }

    func testNoTriggerAtBaselinePace() {
        let audio = talk(25, syllables: 4)
        let run = feed(makeCoach { $0.baselineRate = 4.0 }, mic: audio, desktop: quietDesktop(seconds: 26))
        XCTAssertTrue(run.triggers(.pace).isEmpty)
    }

    func testShownTriggerLightsCue() {
        let audio = talk(12, syllables: 6)
        let run = feed(makeCoach { $0.baselineRate = 4.0; $0.withholding = false }, mic: audio, desktop: quietDesktop(seconds: 13))
        XCTAssertEqual(run.triggers(.pace).first?.shown, true)
        XCTAssertTrue(run.huds.contains { $0.litCues.contains(.pace) })
    }

    func testSummaryCarriesSessionMedians() {
        let coach = makeCoach()
        _ = feed(coach, mic: talk(20, syllables: 4), desktop: quietDesktop(seconds: 21))
        let summary = coach.finish()
        XCTAssertEqual(summary.articulationRate ?? 0, 4.0, accuracy: 0.5)
        XCTAssertNotNil(summary.levelDB)
        XCTAssertGreaterThan(summary.ownSpeechSeconds, 15)
    }
}
