import XCTest
@testable import VoiceCoach

final class EnergyTests: XCTestCase {
    private func steadyVoice(levelDB: Double, seconds: Double = 6) -> [Float] {
        var signal = Synth.steady(f0: 140, seconds: seconds, levelDB: levelDB)
        Synth.mix(&signal, Synth.noise(seconds: seconds, db: -65, seed: 8))
        return Synth.noise(seconds: 1, db: -65, seed: 9) + signal
    }

    private func energy(levelDB: Double) -> Double? {
        let run = feed(makeCoach { $0.baselineLevelDB = -26 }, mic: steadyVoice(levelDB: levelDB), desktop: quietDesktop(seconds: 7))
        return run.last?.energy
    }

    func testEnergyRisesWithLevel() {
        XCTAssertEqual(energy(levelDB: -26) ?? -1, 0.6, accuracy: 0.05)
        XCTAssertEqual(energy(levelDB: -17) ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(energy(levelDB: -35) ?? -1, 0.0, accuracy: 0.001)
    }

    func testEnergyNilWithoutBaseline() {
        let run = feed(makeCoach(), mic: steadyVoice(levelDB: -26), desktop: quietDesktop(seconds: 7))
        XCTAssertNil(run.last?.energy)
    }

    func testEnergyNilAfterTwentySecondsQuiet() {
        let audio = steadyVoice(levelDB: -26) + Synth.noise(seconds: 22, db: -65, seed: 3)
        let run = feed(makeCoach { $0.baselineLevelDB = -26 }, mic: audio, desktop: quietDesktop(seconds: 29.5))
        XCTAssertTrue(run.huds.contains { $0.energy != nil })
        XCTAssertNil(run.last?.energy)
    }

    func testEnergyHoldsWhileThemSpeaks() {
        let mine = steadyVoice(levelDB: -26)
        let remote = Synth.voice(f0: { _ in 200 }, syllablesPerSecond: 4, seconds: 5, levelDB: -20, noiseDB: nil)
        let mic = mine + Synth.delayed(remote, seconds: 0.04, gainDB: -10)
        let desktop = quietDesktop(seconds: 7) + remote
        let run = feed(makeCoach { $0.baselineLevelDB = -26 }, mic: mic, desktop: desktop)
        XCTAssertEqual(run.last?.energy ?? -1, 0.6, accuracy: 0.05)
    }
}
