import XCTest
@testable import VoiceCoach

final class TurnTakingTests: XCTestCase {
    private let rate = 16_000.0

    private func mine(_ seconds: Double, levelDB: Double = -20) -> [Float] {
        Synth.voice(f0: { _ in 125 }, syllablesPerSecond: 4, seconds: seconds, rate: rate, levelDB: levelDB, seed: 7)
    }

    private func theirs(_ seconds: Double, levelDB: Double = -20) -> [Float] {
        Synth.voice(f0: { _ in 210 }, syllablesPerSecond: 4.5, seconds: seconds, rate: rate, levelDB: levelDB, noiseDB: nil, seed: 8)
    }

    private func silence(_ seconds: Double) -> [Float] {
        Synth.noise(seconds: seconds, db: -90, rate: rate, seed: 9)
    }

    private func room(_ seconds: Double) -> [Float] {
        Synth.noise(seconds: seconds, db: -65, rate: rate, seed: 10)
    }

    private func conversation(cycles: Int) -> (mic: [Float], desktop: [Float]) {
        var mic = room(1)
        var desktop = silence(1)
        for _ in 0..<cycles {
            mic += mine(10)
            desktop += silence(10)
            let remote = theirs(10)
            var bleed = Synth.delayed(remote, seconds: 0.04, gainDB: -18, rate: rate)
            Synth.mix(&bleed, room(10))
            mic += bleed
            desktop += remote
        }
        return (mic, desktop)
    }

    func testTalkShareHalf() {
        let audio = conversation(cycles: 6)
        let run = feed(makeCoach { $0.promoted = [.pace, .talkShare] }, mic: audio.mic, desktop: audio.desktop, rate: rate)
        let share = run.samples(.talkShare).last?.values["talkShare"]
        XCTAssertEqual(share ?? 0, 0.5, accuracy: 0.06)
        XCTAssertEqual(run.last?.talkShare ?? 0, share ?? -1, accuracy: 0.01)
    }

    func testTalkShareHiddenUnlessPromoted() {
        let audio = conversation(cycles: 2)
        let hidden = feed(makeCoach(), mic: audio.mic, desktop: audio.desktop, rate: rate)
        XCTAssertNil(hidden.last?.talkShare)
        XCTAssertNotNil(hidden.samples(.talkShare).last?.values["talkShare"])
        let shown = feed(makeCoach { $0.promoted = [.talkShare]; $0.preset = .group }, mic: audio.mic, desktop: audio.desktop, rate: rate)
        XCTAssertNotNil(shown.last?.talkShare)
        XCTAssertEqual(shown.last?.talkShareHigh, true)
    }

    func testInterruptionCounted() {
        let remote = theirs(6, levelDB: -30)
        var mic = room(1) + Synth.delayed(Array(remote.prefix(Int(3 * rate))), seconds: 0.04, gainDB: -18, rate: rate)
        mic += mine(1.5, levelDB: -12)
        mic += room(2.5)
        let desktop = silence(1) + remote
        let run = feed(makeCoach(), mic: mic, desktop: desktop, rate: rate)
        XCTAssertEqual(run.samples(.interruptions).last?.values["interruptedThem"], 1)
        XCTAssertEqual(run.samples(.interruptions).last?.values["wasInterrupted"], 0)
    }

    func testBeingInterruptedCounted() {
        let remote = theirs(3)
        var bleed = Synth.delayed(remote, seconds: 0.04, gainDB: -18, rate: rate)
        Synth.mix(&bleed, room(3))
        let mic = room(1) + mine(4) + bleed + room(2)
        let desktop = silence(5) + remote + silence(2)
        let run = feed(makeCoach(), mic: mic, desktop: desktop, rate: rate)
        XCTAssertEqual(run.samples(.interruptions).last?.values["wasInterrupted"], 1)
        XCTAssertEqual(run.samples(.interruptions).last?.values["interruptedThem"], 0)
    }

    func testNoTextOrPitchOfOthersInSamples() {
        let audio = conversation(cycles: 2)
        let run = feed(makeCoach(), mic: audio.mic, desktop: audio.desktop, rate: rate)
        let allowed: Set<String> = ["talkShare", "interruptedThem", "wasInterrupted"]
        for event in run.samples(.talkShare) + run.samples(.interruptions) {
            XCTAssertTrue(Set(event.values.keys).isSubset(of: allowed), "\(event.values.keys)")
        }
    }
}
