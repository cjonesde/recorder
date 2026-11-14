import Foundation
@testable import VoiceCoach

struct CoachRun {
    var events: [CoachEvent] = []
    var clips: [ClipRequest] = []
    var huds: [CoachHUDState] = []

    var last: CoachHUDState? { huds.last }

    func samples(_ detector: DetectorID) -> [CoachEvent] { events.filter { $0.kind == .sample && $0.detector == detector } }
    func triggers(_ detector: DetectorID) -> [CoachEvent] { events.filter { $0.kind == .trigger && $0.detector == detector } }
}

func makeCoach(_ configure: (inout CoachConfig) -> Void = { _ in }, seed: UInt64 = 11) -> VoiceCoach {
    var config = CoachConfig(language: "en")
    configure(&config)
    return VoiceCoach(config: config, random: SplitMix64(seed: seed))
}

@discardableResult
func feed(_ coach: VoiceCoach, mic: [Float], desktop: [Float]?, rate: Double = 48_000, chunk: Int = 4800, lines: [CoachLine] = [], into run: inout CoachRun) -> CoachRun {
    var pendingLines = lines.sorted { $0.time < $1.time }
    var offset = 0
    let total = max(mic.count, desktop?.count ?? 0)
    while offset < total {
        let end = min(offset + chunk, total)
        if offset < mic.count {
            mic[offset..<min(end, mic.count)].withUnsafeBufferPointer { coach.ingest(.mic, $0, sampleRate: rate) }
        }
        if let desktop, offset < desktop.count {
            desktop[offset..<min(end, desktop.count)].withUnsafeBufferPointer { coach.ingest(.desktop, $0, sampleRate: rate) }
        }
        let now = Double(end) / rate
        while let line = pendingLines.first, line.time <= now {
            coach.ingest(line)
            pendingLines.removeFirst()
        }
        let output = coach.advance()
        run.events += output.events
        run.clips += output.clips
        run.huds.append(output.hud)
        offset = end
    }
    return run
}

func feed(_ coach: VoiceCoach, mic: [Float], desktop: [Float]?, rate: Double = 48_000, lines: [CoachLine] = []) -> CoachRun {
    var run = CoachRun()
    return feed(coach, mic: mic, desktop: desktop, rate: rate, lines: lines, into: &run)
}

func quietDesktop(seconds: Double, rate: Double = 48_000) -> [Float] {
    Synth.noise(seconds: seconds, db: -90, rate: rate, seed: 99)
}

func speech(seconds: Double, syllables: Double = 4, levelDB: Double = -20, f0: Double = 130, seed: UInt64 = 1) -> [Float] {
    Synth.voice(f0: { t in f0 + 10 * sin(2 * .pi * 0.7 * t) }, syllablesPerSecond: syllables, seconds: seconds, levelDB: levelDB, seed: seed)
}
