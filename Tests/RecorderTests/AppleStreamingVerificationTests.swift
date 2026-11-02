import XCTest
import WhisperKit
import Darwin
@testable import Recorder

@MainActor
final class AppleStreamingVerificationTests: XCTestCase {
    func testRealTimeReplayThroughProductionStreaming() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["RECORDER_APPLE_STREAM"] == "1")
        let audio = try XCTUnwrap(env["RECORDER_TEST_AUDIO"])
        let output = try XCTUnwrap(env["RECORDER_STREAM_OUTPUT"])
        let language = env["RECORDER_STREAM_LANGUAGE"] ?? "de-DE"
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio)
        let engine = LocalTranscriptionEngine()
        engine.labelSpeakers = false
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await engine.beginSession(language: language)
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
        defer { engine.cancelSession() }
        let silence = [Float](repeating: 0, count: 1600)
        let start = ProcessInfo.processInfo.systemUptime
        var events: [[String: Any]] = []
        var revision = engine.revision
        for offset in stride(from: 0, to: samples.count, by: 1600) {
            let count = min(1600, samples.count - offset)
            let delay = start + Double(offset + count) / 16000 - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            samples.withUnsafeBufferPointer {
                engine.inbox.ingest(.desktop, $0.baseAddress! + offset, count: count, rate: 16000)
            }
            silence.withUnsafeBufferPointer {
                engine.inbox.ingest(.mic, $0.baseAddress!, count: count, rate: 16000)
            }
            if engine.revision != revision {
                events.append(["wallSeconds": ProcessInfo.processInfo.systemUptime - start,
                               "text": engine.transcript(includeHypothesis: true),
                               "confirmedLines": engine.confirmedLines.count])
                revision = engine.revision
            }
        }
        let finishStart = ProcessInfo.processInfo.systemUptime
        let final = await engine.endSession()
        let finishSeconds = ProcessInfo.processInfo.systemUptime - finishStart
        XCTAssertTrue(final.complete, engine.live.failureMessage ?? "incomplete")
        XCTAssertFalse(final.lines.isEmpty)
        XCTAssertEqual(engine.inbox.pendingFrames, 0)
        XCTAssertEqual(engine.engineState, .unloaded, "Live transcription must not load Whisper")
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let result: [String: Any] = [
            "backend": "app-apple-streaming", "language": language,
            "audioSeconds": Double(samples.count) / 16000, "loadSeconds": loadSeconds,
            "events": events, "finishSeconds": finishSeconds, "complete": final.complete,
            "peakRSSBytes": usage.ru_maxrss,
            "finalText": final.lines.map(\.text).joined(separator: " ")
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }

    func testCancelAndRestartRejectsOldTranscript() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RECORDER_APPLE_STREAM"] == "1")
        let live = AppleLiveTranscriber()
        try await live.start(language: "en-US")
        live.cancelSession()
        try await live.start(language: "en-US")
        let result = await live.endSession()
        XCTAssertTrue(result.complete, live.failureMessage ?? "incomplete")
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertEqual(live.inbox.pendingFrames, 0)
    }
}
