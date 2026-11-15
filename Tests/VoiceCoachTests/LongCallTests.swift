import XCTest
@testable import VoiceCoach

final class LongCallTests: XCTestCase {
    private let rate = 16_000.0

    private func mine(_ seconds: Double, syllables: Double = 4, seed: UInt64 = 7) -> [Float] {
        Synth.voice(f0: { t in 125 + 8 * sin(t) }, syllablesPerSecond: syllables, seconds: seconds, rate: rate, levelDB: -20, seed: seed)
    }

    private func room(_ seconds: Double, seed: UInt64 = 10) -> [Float] {
        Synth.noise(seconds: seconds, db: -65, rate: rate, seed: seed)
    }

    private func silence(_ seconds: Double) -> [Float] {
        Synth.noise(seconds: seconds, db: -90, rate: rate, seed: 9)
    }

    private func remoteTurn(_ seconds: Double) -> (mic: [Float], desktop: [Float]) {
        let remote = Synth.voice(f0: { _ in 210 }, syllablesPerSecond: 4.5, seconds: seconds, rate: rate, levelDB: -20, noiseDB: nil, seed: 8)
        var bleed = Synth.delayed(remote, seconds: 0.04, gainDB: -18, rate: rate)
        Synth.mix(&bleed, room(seconds, seed: 11))
        return (bleed, remote)
    }

    func testGateStaysOpenThroughLongCall() {
        var mic = room(1)
        for index in 0..<30 {
            mic += mine(4, seed: UInt64(index + 1))
            mic += room(0.6, seed: UInt64(index + 40))
        }
        let seconds = Double(mic.count) / rate
        let coach = makeCoach()
        let run = feed(coach, mic: mic, desktop: silence(seconds + 0.5), rate: rate)
        let late = run.gateShares(from: 60, to: seconds)
        XCTAssertGreaterThan(late.count, 70)
        XCTAssertTrue(late.allSatisfy { ($0.values["unknown"] ?? 0) == 0 }, "gate went unknown late in the call")
        XCTAssertTrue(late.allSatisfy { ($0.values["own"] ?? 0) > 0.3 }, "own voice stopped counting late in the call")
        XCTAssertGreaterThan(coach.ownSpeechSeconds, 100)
    }

    func testLostDesktopAudioRealigns() {
        let turn = remoteTurn(10)
        let mic = room(1) + mine(10) + turn.mic + room(3)
        let desktop = silence(11) + turn.desktop + silence(3.5)
        let run = feed(makeCoach(), mic: mic, desktop: desktop, rate: rate, desktopGaps: [5.0...5.95])
        let theirTurn = run.gateShares(from: 11.5, to: 21.5)
        XCTAssertFalse(theirTurn.isEmpty)
        for sample in theirTurn {
            XCTAssertEqual(sample.values["own"] ?? 0, 0, "own voice during their turn at \(sample.t)")
        }
        XCTAssertTrue(run.events.contains { $0.kind == .gap && ($0.note ?? "").hasPrefix("system audio realigned") })
    }

    func testLongDesktopLossRecovers() {
        let mic = room(1) + mine(25)
        let run = feed(makeCoach(), mic: mic, desktop: silence(26.5), rate: rate, desktopGaps: [5.0...7.95])
        let after = run.gateShares(from: 12, to: 25)
        XCTAssertFalse(after.isEmpty)
        XCTAssertTrue(after.allSatisfy { ($0.values["own"] ?? 0) > 0.3 }, "gate did not recover after the loss")
    }

    func testPaceDoesNotRetriggerWhileSilent() {
        let mic = room(1) + mine(20, syllables: 6) + room(70, seed: 12)
        let run = feed(makeCoach { $0.baselineRate = 4 }, mic: mic, desktop: silence(91.5), rate: rate)
        XCTAssertEqual(run.triggers(.pace).count, 1)
        XCTAssertTrue(run.samples(.pace).filter { $0.t > 25 }.allSatisfy { $0.values["ratio"] == nil })
    }

    func testPaceDoesNotRetriggerWhileTheyTalk() {
        let turn = remoteTurn(70)
        let mic = room(1) + mine(20, syllables: 6) + turn.mic
        let desktop = silence(21) + turn.desktop + silence(0.5)
        let run = feed(makeCoach { $0.baselineRate = 4 }, mic: mic, desktop: desktop, rate: rate)
        XCTAssertEqual(run.triggers(.pace).count, 1)
    }

    func testEndingsDoNotRetriggerWithoutNewPhrases() {
        var mic = room(1)
        for index in 0..<6 {
            mic += Synth.voice(
                f0: { t in t < 1.2 ? 120 : 120 * pow(2, 4.5 * min(1, (t - 1.2) / 0.3) / 12) },
                syllablesPerSecond: 4, seconds: 1.5, rate: rate, levelDB: -20, seed: UInt64(index + 1)
            )
            mic += room(0.8, seed: UInt64(index + 100))
        }
        mic += room(100, seed: 500)
        let seconds = Double(mic.count) / rate
        let run = feed(makeCoach(), mic: mic, desktop: silence(seconds + 0.5), rate: rate)
        XCTAssertEqual(run.triggers(.risingEndings).count, 1)
    }

    func testDrainingDesktopBeforeMicDoesNotRealign() {
        let mic = room(1) + mine(20)
        let desktop = silence(Double(mic.count) / rate)
        let coach = makeCoach()
        var events: [CoachEvent] = []
        let batch = Int(rate / 2)
        var offset = 0
        while offset < mic.count {
            let end = min(offset + batch, mic.count)
            for (source, samples) in [(CoachSource.desktop, desktop), (.mic, mic)] {
                var start = offset
                while start < end {
                    let stop = min(start + 4096, end)
                    samples[start..<stop].withUnsafeBufferPointer { coach.ingest(source, $0, sampleRate: rate) }
                    start = stop
                }
            }
            events += coach.advance().events
            offset = end
        }
        let gaps = events.filter { $0.kind == .gap }.compactMap(\.note)
        XCTAssertEqual(gaps, [])
        XCTAssertGreaterThan(coach.ownSpeechSeconds, 15)
    }
}
