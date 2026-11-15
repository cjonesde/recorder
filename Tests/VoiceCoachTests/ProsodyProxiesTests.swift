import XCTest
@testable import VoiceCoach

final class ProsodyProxiesTests: XCTestCase {
    private let rate = 16_000.0

    private func steady(_ f0: Double, _ levelDB: Double, _ seconds: Double) -> [Float] {
        var signal = Synth.steady(f0: f0, seconds: seconds, rate: rate, levelDB: levelDB)
        Synth.mix(&signal, Synth.noise(seconds: seconds, db: -65, rate: rate, seed: UInt64(f0)))
        return signal
    }

    private func run(raisedLevelDB: Double) -> CoachRun {
        let raised = 120 * pow(2, 3.0 / 12)
        let mic = Synth.noise(seconds: 1, db: -65, rate: rate, seed: 1) + steady(120, -26, 20) + steady(raised, raisedLevelDB, 10)
        let coach = makeCoach {
            $0.baselineLevelDB = -26
            $0.promoted = Set(DetectorID.allCases)
            $0.withholding = false
        }
        return feed(coach, mic: mic, desktop: Synth.noise(seconds: 31.5, db: -90, rate: rate, seed: 2), rate: rate)
    }

    func testRaisedPitchAndLevelTriggersShadowOnly() {
        let run = run(raisedLevelDB: -20)
        let triggers = run.triggers(.raisedVoice)
        XCTAssertEqual(triggers.count, 1)
        XCTAssertEqual(triggers.first?.shown, false)
        XCTAssertEqual(triggers.first?.note, "shadow")
        XCTAssertGreaterThan(triggers.first?.t ?? 0, 21)
        let last = run.samples(.raisedVoice).last?.values ?? [:]
        XCTAssertEqual(last["pitchOffsetST"] ?? 0, 3, accuracy: 0.4)
        XCTAssertEqual(last["levelOffsetDB"] ?? 0, 6, accuracy: 0.5)
        XCTAssertFalse(run.huds.contains { $0.litCues.contains(.raisedVoice) })
    }

    func testPitchAloneDoesNotTrigger() {
        XCTAssertTrue(run(raisedLevelDB: -26).triggers(.raisedVoice).isEmpty)
    }

    func testOnsetSlopeLoggedFromSyllables() {
        let mic = Synth.noise(seconds: 1, db: -65, seed: 3) + speech(seconds: 8, syllables: 4)
        let run = feed(makeCoach(), mic: mic, desktop: quietDesktop(seconds: 9.5))
        XCTAssertGreaterThan(run.samples(.raisedVoice).last?.values["onsetSlope"] ?? 0, 2)
    }
}
