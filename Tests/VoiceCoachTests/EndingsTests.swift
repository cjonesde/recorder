import XCTest
@testable import VoiceCoach

final class EndingsTests: XCTestCase {
    private static let phraseSeconds = 1.5
    private static let gapSeconds = 0.8

    private func phrase(endSemitones: Double, endGainDB: Double = 0, seed: UInt64) -> [Float] {
        let length = Self.phraseSeconds
        let bendStart = length - 0.3
        return Synth.voice(
            f0: { t in t < bendStart ? 120 : 120 * pow(2, endSemitones * min(1, (t - bendStart) / 0.3) / 12) },
            syllablesPerSecond: 4,
            seconds: length,
            levelDB: -20,
            envelope: { t in t < bendStart ? 1 : pow(10, endGainDB / 20) },
            seed: seed
        )
    }

    private func talk(_ phrases: [(Double, Double)]) -> [Float] {
        var signal = Synth.noise(seconds: 1, db: -65, seed: 77)
        for (index, (semitones, gain)) in phrases.enumerated() {
            signal += phrase(endSemitones: semitones, endGainDB: gain, seed: UInt64(index + 1))
            signal += Synth.noise(seconds: Self.gapSeconds, db: -65, seed: UInt64(index + 100))
        }
        signal += Synth.noise(seconds: 4.5, db: -65, seed: 500)
        return signal
    }

    private func run(_ audio: [Float], lines: [CoachLine] = []) -> CoachRun {
        let seconds = Double(audio.count) / 48_000
        return feed(makeCoach { $0.transcriptCues = true }, mic: audio, desktop: quietDesktop(seconds: seconds + 0.5), lines: lines)
    }

    private func phraseStart(_ index: Int) -> Double { 1 + Double(index) * (Self.phraseSeconds + Self.gapSeconds) }

    func testSyntheticRisingStatementsTrigger() {
        let run = run(talk(Array(repeating: (4.5, 0), count: 6)))
        let last = run.samples(.risingEndings).last
        XCTAssertEqual(last?.values["measured"] ?? 0, 6, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(last?.values["rises"] ?? 0, 5)
        XCTAssertEqual(run.triggers(.risingEndings).count, 1)
        XCTAssertEqual(run.triggers(.risingEndings).first?.note, "shadow")
    }

    func testFallingStatementsDoNotTrigger() {
        let run = run(talk(Array(repeating: (-4, 0), count: 6)))
        XCTAssertTrue(run.triggers(.risingEndings).isEmpty)
        XCTAssertGreaterThanOrEqual(run.samples(.risingEndings).last?.values["falls"] ?? 0, 5)
    }

    func testQuestionLineExcludesPhrase() {
        let lines = (0..<6).map { CoachLine(time: phraseStart($0), text: "Is that right?", isOwn: true) }
        let run = run(talk(Array(repeating: (4.5, 0), count: 6)), lines: lines)
        XCTAssertTrue(run.triggers(.risingEndings).isEmpty)
        XCTAssertEqual(run.samples(.risingEndings).last?.values["measured"] ?? -1, 0)
        XCTAssertEqual(run.samples(.risingEndings).last?.values["questions"] ?? 0, 6, accuracy: 0.5)
    }

    func testTrailingOffDetected() {
        let pattern: [(Double, Double)] = [(0, -12), (0, 0), (0, -12), (0, -12), (0, 0), (0, -12)]
        let run = run(talk(pattern))
        XCTAssertGreaterThanOrEqual(run.samples(.trailingEndings).last?.values["trailing"] ?? 0, 3)
        XCTAssertEqual(run.triggers(.trailingEndings).count, 1)
    }

    func testSteadyEndingsDoNotTrail() {
        let run = run(talk(Array(repeating: (0, 0), count: 6)))
        XCTAssertTrue(run.triggers(.trailingEndings).isEmpty)
    }

    func testBleedFramesNeverMakePhrases() {
        var remote = Synth.noise(seconds: 1, db: -90, seed: 1)
        for index in 0..<5 {
            remote += Synth.voice(f0: { _ in 200 }, syllablesPerSecond: 4, seconds: 1.5, levelDB: -20, noiseDB: nil, seed: UInt64(index + 1))
            remote += Synth.noise(seconds: 0.8, db: -90, seed: UInt64(index + 20))
        }
        var mic = Synth.delayed(remote, seconds: 0.04, gainDB: -18)
        Synth.mix(&mic, Synth.noise(seconds: Double(remote.count) / 48_000, db: -65, seed: 3))
        let run = feed(makeCoach(), mic: mic, desktop: remote)
        XCTAssertEqual(run.samples(.risingEndings).last?.values["measured"] ?? -1, 0)
    }
}
