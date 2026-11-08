import XCTest
import WhisperKit
import Darwin
@testable import Recorder

@MainActor
final class LiveStreamingBenchmarkTests: XCTestCase {
    func testReplayThroughTheLegacyWhisperTranscriber() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RECORDER_STREAM_BENCHMARK"] == "1")
        let audio = try XCTUnwrap(ProcessInfo.processInfo.environment["RECORDER_TEST_AUDIO"])
        let output = try XCTUnwrap(ProcessInfo.processInfo.environment["RECORDER_STREAM_OUTPUT"])
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio)
        let host = WhisperModelStorage.makeHost()
        let engine = LiveTranscriber(host: host)
        engine.labelSpeakers = false
        engine.language = nil
        engine.maxWindowSamples = LiveTranscriber.windowCap(for: .transcriptOnly)
        await host.loadModel(WhisperModelOption.defaultModelID, downloadIfNeeded: false)
        XCTAssertEqual(host.state, .ready)

        let silence = [Float](repeating: 0, count: 1600)
        let start = ProcessInfo.processInfo.systemUptime
        var events: [[String: Any]] = []
        var revision = engine.revision
        engine.beginSession()
        defer { engine.cancelSession() }
        for offset in stride(from: 0, to: samples.count, by: 1600) {
            let count = min(1600, samples.count - offset)
            let delay = start + Double(offset + count) / 16000 - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            samples.withUnsafeBufferPointer { source in
                engine.inbox.ingest(.desktop, source.baseAddress! + offset, count: count, rate: 16000)
            }
            silence.withUnsafeBufferPointer { source in
                engine.inbox.ingest(.mic, source.baseAddress!, count: count, rate: 16000)
            }
            if engine.revision != revision {
                let text = engine.transcript(includeHypothesis: true)
                if !text.isEmpty {
                    events.append(["wallSeconds": ProcessInfo.processInfo.systemUptime - start,
                                   "text": text, "confirmedLines": engine.confirmedLines.count])
                }
                revision = engine.revision
            }
        }
        let finishStart = ProcessInfo.processInfo.systemUptime
        let final = await engine.endSession()
        let finishSeconds = ProcessInfo.processInfo.systemUptime - finishStart
        XCTAssertTrue(final.complete)
        XCTAssertFalse(final.lines.isEmpty)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let result: [String: Any] = [
            "backend": "app-whisper-base-auto", "audioSeconds": Double(samples.count) / 16000,
            "events": events, "finishSeconds": finishSeconds, "complete": final.complete,
            "peakRSSBytes": usage.ru_maxrss,
            "finalText": final.lines.map(\.text).joined(separator: " ")
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output))
        print("Live baseline: first text \(events.first?["wallSeconds"] ?? "none"), finalization \(finishSeconds)s")
    }
}
