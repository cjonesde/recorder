import AVFoundation
import XCTest
@testable import Recorder
import VoiceCoach

private func harmonicVoice(seconds: Double, syllables: Double, rate: Double = 48_000, levelDB: Double = -20) -> [Float] {
    let amplitude = pow(10, levelDB / 20) / sqrt((1...5).reduce(0.0) { $0 + 1.0 / Double($1 * $1) } / 2)
    var phase = 0.0
    var noise = UInt64(12345)
    return (0..<Int(seconds * rate)).map { i in
        let t = Double(i) / rate
        phase += 2 * .pi * (130 + 10 * sin(2 * .pi * 0.7 * t)) / rate
        var tone = 0.0
        for k in 1...5 { tone += sin(Double(k) * phase) / Double(k) }
        let u = t.truncatingRemainder(dividingBy: 1 / syllables) * syllables
        let burst = u < 0.6 ? 0.5 * (1 - cos(2 * .pi * u / 0.6)) : 0
        noise = noise &* 6364136223846793005 &+ 1442695040888963407
        let hiss = (Double(noise >> 11) / Double(1 << 53) - 0.5) * 0.001
        return Float(amplitude * tone * (0.1 + 0.9 * burst) + hiss)
    }
}

private func quiet(seconds: Double, rate: Double = 48_000) -> [Float] {
    [Float](repeating: 0.00001, count: Int(seconds * rate))
}

final class CoachAdapterTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("coach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func pump(_ configure: (inout CoachConfig) -> Void = { _ in }, retainsAudio: Bool = false) -> CoachPump {
        var config = CoachConfig(language: "en")
        configure(&config)
        return CoachPump(folder: folder, config: config, retainsAudio: retainsAudio)
    }

    private func push(_ pump: CoachPump, mic: [Float], desktop: [Float], chunk: Int = 4800) {
        var offset = 0
        while offset < max(mic.count, desktop.count) {
            let end = offset + chunk
            if offset < mic.count {
                mic[offset..<min(end, mic.count)].withUnsafeBufferPointer { pump.ingest(.mic, $0.baseAddress!, count: $0.count, rate: 48_000) }
            }
            if offset < desktop.count {
                desktop[offset..<min(end, desktop.count)].withUnsafeBufferPointer { pump.ingest(.desktop, $0.baseAddress!, count: $0.count, rate: 48_000) }
            }
            pump.drainNow()
            offset = end
        }
    }

    private func events() throws -> [CoachEvent] {
        let text = try String(contentsOf: folder.appendingPathComponent(CoachPump.logName), encoding: .utf8)
        return try text.split(separator: "\n").map { try JSONDecoder().decode(CoachEvent.self, from: Data($0.utf8)) }
    }

    func testPumpWritesSessionAndSampleLines() throws {
        let pump = pump()
        push(pump, mic: harmonicVoice(seconds: 3.5, syllables: 4), desktop: quiet(seconds: 3.5))
        _ = pump.stop()
        let events = try events()
        XCTAssertEqual(events.first?.kind, .session)
        XCTAssertEqual(events.filter { $0.kind == .sample && $0.note == "gate" }.count, 3)
        XCTAssertEqual(events.filter { $0.kind == .sample && $0.detector == .pace }.count, 3)
        XCTAssertEqual(events.filter { $0.kind == .sample && $0.detector == .energy }.count, 3)
    }

    func testStopIsSynchronousBeforeFolderRemoval() throws {
        let pump = pump()
        pump.start()
        push(pump, mic: harmonicVoice(seconds: 1, syllables: 4), desktop: quiet(seconds: 1))
        _ = pump.stop()
        try FileManager.default.removeItem(at: folder)
        let settled = expectation(description: "timer would have fired")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testRelayIgnoresSamplesWithoutPump() {
        let relay = CoachRelay()
        let samples = [Float](repeating: 0.1, count: 480)
        samples.withUnsafeBufferPointer { relay.ingest(.mic, $0.baseAddress!, count: 480, rate: 48_000) }
        XCTAssertNil(relay.current)
    }

    func testControllerDisabledByDefault() {
        UserDefaults.standard.removeObject(forKey: "coachEnabled")
        UserDefaults.standard.removeObject(forKey: "coachWithholding")
        UserDefaults.standard.removeObject(forKey: "coachPromoted")
        XCTAssertFalse(Preferences.coachEnabled)
        XCTAssertTrue(Preferences.coachWithholding)
        XCTAssertEqual(Preferences.coachPromoted, [.pace])
    }

    func testPromotedRoundTrips() {
        let before = Preferences.coachPromoted
        defer { Preferences.coachPromoted = before }
        Preferences.coachPromoted = [.pace, .soStarts]
        XCTAssertEqual(Preferences.coachPromoted, [.pace, .soStarts])
    }

    @MainActor
    func testControllerRecordsBaselineUnlessDiscarded() throws {
        let store = CoachStore(directory: folder.appendingPathComponent("support", isDirectory: true))
        let controller = CoachController(store: store)
        controller.showsPanel = false
        controller.start(folder: folder, language: "en", engine: .apple, attendeeCount: nil, retainsAudio: false, lines: { [] })
        XCTAssertTrue(controller.isActive)
        XCTAssertNotNil(controller.relay.current)
        controller.stop(discard: true)
        XCTAssertFalse(controller.isActive)
        XCTAssertNil(controller.relay.current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.baselineURL.path))
    }

    private func fastTalk() -> (mic: [Float], desktop: [Float]) {
        (quiet(seconds: 1) + harmonicVoice(seconds: 14, syllables: 6), quiet(seconds: 15.5))
    }

    private func clipFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent(CoachPump.clipsFolderName), includingPropertiesForKeys: nil)) ?? []
    }

    func testTranscriptOnlyWritesNoClips() throws {
        let pump = pump({ $0.baselineRate = 4 }, retainsAudio: false)
        let audio = fastTalk()
        push(pump, mic: audio.mic, desktop: audio.desktop)
        _ = pump.stop()
        let events = try events()
        XCTAssertFalse(events.filter { $0.kind == .trigger }.isEmpty)
        XCTAssertTrue(events.contains { $0.kind == .clip && $0.note == "transcript only" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(CoachPump.clipsFolderName).path))
    }

    func testClipFileHoldsEightSeconds() throws {
        let pump = pump({ $0.baselineRate = 4 }, retainsAudio: true)
        let audio = fastTalk()
        push(pump, mic: audio.mic, desktop: audio.desktop)
        _ = pump.stop()
        let trigger = try XCTUnwrap(try events().first { $0.kind == .trigger })
        let clip = try XCTUnwrap(clipFiles().first)
        XCTAssertEqual(clip.deletingPathExtension().lastPathComponent, trigger.id)
        let file = try AVAudioFile(forReading: clip)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        XCTAssertEqual(seconds, 8, accuracy: 0.1)
    }

    func testDowngradeDeletesClips() throws {
        let pump = pump({ $0.baselineRate = 4 }, retainsAudio: true)
        let audio = fastTalk()
        push(pump, mic: audio.mic, desktop: audio.desktop)
        XCTAssertFalse(clipFiles().isEmpty)
        pump.audioRetentionChanged(retains: false)
        pump.drainNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(CoachPump.clipsFolderName).path))
        _ = pump.stop()
    }
}
