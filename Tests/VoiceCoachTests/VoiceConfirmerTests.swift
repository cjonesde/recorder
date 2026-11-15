import XCTest
@testable import VoiceCoach

final class VoiceConfirmerTests: XCTestCase {
    private let rate = 48_000.0

    private func typing(seconds: Double, first: Double = 0.5, every: Double = 0.35, clickSeconds: Double = 0.03, levelDB: Double = -22, seed: UInt64 = 40) -> [Float] {
        var signal = Synth.noise(seconds: seconds, db: -65, seed: seed)
        var start = first
        var index: UInt64 = 0
        while start + clickSeconds < seconds {
            Synth.mix(&signal, Synth.noise(seconds: clickSeconds, db: levelDB, seed: seed + 1 + index), at: Int(start * rate))
            start += every
            index += 1
        }
        return signal
    }

    private func phrases(withTyping: Bool) -> [Float] {
        var mic = Synth.noise(seconds: 1, db: -65, seed: 1)
        for index in 0..<12 {
            mic += speech(seconds: 3, syllables: 4, seed: UInt64(index + 1))
            let seed = UInt64(200 + index * 50)
            mic += withTyping ? typing(seconds: 1.2, first: 0.1, every: 0.25, seed: seed) : Synth.noise(seconds: 1.2, db: -65, seed: seed)
        }
        return mic
    }

    func testTypingWithoutVoicingIsNotOwnSpeech() {
        let coach = makeCoach()
        let run = feed(coach, mic: typing(seconds: 20), desktop: quietDesktop(seconds: 20))
        XCTAssertEqual(coach.ownSpeechSeconds, 0, accuracy: 0.05)
        let shares = run.gateShares(from: 0, to: 20)
        XCTAssertFalse(shares.isEmpty)
        XCTAssertTrue(shares.allSatisfy { ($0.values["own"] ?? 0) == 0 })
        XCTAssertTrue(run.huds.allSatisfy { $0.gate != .own })
    }

    func testTypingBetweenPhrasesLeavesThePaceRateAlone() throws {
        let clean = phrases(withTyping: false)
        let typed = phrases(withTyping: true)
        let seconds = Double(clean.count) / rate
        let cleanCoach = makeCoach()
        feed(cleanCoach, mic: clean, desktop: quietDesktop(seconds: seconds))
        let typedCoach = makeCoach()
        feed(typedCoach, mic: typed, desktop: quietDesktop(seconds: seconds))
        let cleanRate = try XCTUnwrap(cleanCoach.finish().articulationRate)
        let typedRate = try XCTUnwrap(typedCoach.finish().articulationRate)
        XCTAssertEqual(typedRate / cleanRate, 1, accuracy: 0.1)
        XCTAssertEqual(typedCoach.ownSpeechSeconds, cleanCoach.ownSpeechSeconds, accuracy: 1.5)
    }

    func testUnvoicedOnsetBeforeAVowelStillCountsAsOwn() {
        var mic = Synth.noise(seconds: 1, db: -65, seed: 3)
        mic += Synth.noise(seconds: 0.08, db: -30, seed: 4)
        mic += Synth.steady(f0: 130, seconds: 0.4, levelDB: -20)
        mic += Synth.noise(seconds: 2, db: -65, seed: 5)
        let coach = makeCoach()
        feed(coach, mic: mic, desktop: quietDesktop(seconds: Double(mic.count) / rate))
        XCTAssertGreaterThan(coach.ownSpeechSeconds, 0.45)
    }

    func testLongUnvoicedRunIsReleasedAsSilenceWithinTheHoldLimit() {
        var confirmer = VoiceConfirmer()
        var released: [FrameAnalysis] = []
        for index in 0..<80 {
            released += confirmer.push(FrameAnalysis(index: index, t: Double(index + 1) * 0.01, micDB: -20, gate: .own, f0: 0, floorDB: -60))
        }
        XCTAssertGreaterThanOrEqual(released.count, 80 - VoiceConfirmer.maxHoldFrames)
        XCTAssertTrue(released.allSatisfy { $0.gate == .silence && $0.f0 == 0 })
        XCTAssertEqual(released.map(\.index), Array(0..<released.count))
    }

    func testVoicingConfirmsTheHeldRunInOrder() {
        var confirmer = VoiceConfirmer()
        var released: [FrameAnalysis] = []
        for index in 0..<10 {
            released += confirmer.push(FrameAnalysis(index: index, t: Double(index + 1) * 0.01, micDB: -25, gate: .own, f0: 0, floorDB: -60))
        }
        XCTAssertTrue(released.isEmpty)
        for index in 10..<20 {
            released += confirmer.push(FrameAnalysis(index: index, t: Double(index + 1) * 0.01, micDB: -20, gate: .own, f0: 130, floorDB: -60))
        }
        XCTAssertEqual(released.map(\.index), Array(0..<20))
        XCTAssertTrue(released.allSatisfy { $0.gate == .own })
        XCTAssertEqual(confirmer.push(FrameAnalysis(index: 20, t: 0.21, micDB: -25, gate: .own, f0: 0, floorDB: -60)).map(\.gate), [.own])
    }

    func testUnvoicedRunAfterADipIsReleasedAsSilence() {
        var confirmer = VoiceConfirmer()
        for index in 0..<5 {
            _ = confirmer.push(FrameAnalysis(index: index, t: Double(index + 1) * 0.01, micDB: -20, gate: .own, f0: 130, floorDB: -60))
        }
        XCTAssertEqual(confirmer.push(FrameAnalysis(index: 5, t: 0.06, micDB: -70, gate: .silence, f0: 0, floorDB: -60)).map(\.gate), [.silence])
        XCTAssertTrue(confirmer.push(FrameAnalysis(index: 6, t: 0.07, micDB: -25, gate: .own, f0: 0, floorDB: -60)).isEmpty)
        let flushed = confirmer.push(FrameAnalysis(index: 7, t: 0.08, micDB: -70, gate: .silence, f0: 0, floorDB: -60))
        XCTAssertEqual(flushed.map(\.index), [6, 7])
        XCTAssertEqual(flushed.map(\.gate), [.silence, .silence])
    }

    func testOtherStatesPassStraightThroughWhenNothingIsHeld() {
        var confirmer = VoiceConfirmer()
        for (index, state) in [GateState.them, .silence, .overlap, .unknown].enumerated() {
            let out = confirmer.push(FrameAnalysis(index: index, t: Double(index + 1) * 0.01, micDB: -30, gate: state, f0: 0, floorDB: -60))
            XCTAssertEqual(out.map(\.gate), [state])
        }
    }
}
