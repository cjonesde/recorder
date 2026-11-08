import XCTest
import WhisperKit
import Darwin
@testable import Recorder

@MainActor
final class FluidEngineVerificationTests: XCTestCase {
    func testNemotronRealTimeReplay() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["RECORDER_FLUID_STREAM"] == "1" && env["RECORDER_FLUID_ENGINE"] == "nemotron")
        let audio = try XCTUnwrap(env["RECORDER_TEST_AUDIO"])
        let language = env["RECORDER_STREAM_LANGUAGE"] ?? "de-DE"
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio)
        let engine = LocalTranscriptionEngine()
        await engine.select(.nemotron)
        XCTAssertEqual(engine.engine.kind, .nemotron)
        engine.labelSpeakers = false
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await engine.beginSession(language: language)
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
        defer { engine.cancelSession() }
        let silence = [Float](repeating: 0, count: 1600)
        let start = ProcessInfo.processInfo.systemUptime
        var events: [[String: Any]] = []
        var revision = engine.revision
        var confirmedBeforeFinish = 0
        var peakHeld = 0.0
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
            peakHeld = max(peakHeld, engine.engine.diagnostics().heldAudioSeconds ?? 0)
            if engine.revision != revision {
                confirmedBeforeFinish = engine.confirmedLines.count
                events.append(["wallSeconds": ProcessInfo.processInfo.systemUptime - start,
                               "text": engine.transcript(includeHypothesis: true),
                               "confirmedLines": engine.confirmedLines.count])
                revision = engine.revision
            }
        }
        let finishStart = ProcessInfo.processInfo.systemUptime
        let final = await engine.endSession()
        let finishSeconds = ProcessInfo.processInfo.systemUptime - finishStart
        XCTAssertTrue(final.complete, engine.engine.failureMessage ?? "incomplete")
        XCTAssertGreaterThan(confirmedBeforeFinish, 0, "No line was confirmed before finish")
        XCTAssertFalse(final.lines.isEmpty)
        XCTAssertEqual(engine.inbox.pendingFrames, 0)
        guard let output = env["RECORDER_STREAM_OUTPUT"] else { return }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let result: [String: Any] = [
            "backend": "app-nemotron-streaming", "language": language,
            "audioSeconds": Double(samples.count) / 16000, "loadSeconds": loadSeconds,
            "events": events, "finishSeconds": finishSeconds, "complete": final.complete,
            "peakRSSBytes": usage.ru_maxrss, "peakHeldAudioSecondsEstimated": peakHeld,
            "finalText": final.lines.map(\.text).joined(separator: "\n")
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }

    func testParakeetRealTimeReplay() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["RECORDER_FLUID_STREAM"] == "1" && env["RECORDER_FLUID_ENGINE"] == "parakeet")
        let audio = try XCTUnwrap(env["RECORDER_TEST_AUDIO"])
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio)
        let engine = LocalTranscriptionEngine()
        await engine.select(.parakeet)
        XCTAssertEqual(engine.engine.kind, .parakeet)
        engine.labelSpeakers = false
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await engine.beginSession(language: "de-DE")
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
        defer { engine.cancelSession() }
        let silence = [Float](repeating: 0, count: 1600)
        let start = ProcessInfo.processInfo.systemUptime
        var events: [[String: Any]] = []
        var revision = engine.revision
        var firstHypothesis: Double?
        var firstConfirmed: Double?
        var peakHeld = 0.0
        var peakHandoff = "0.0 s"
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
            let diagnostics = engine.engine.diagnostics()
            peakHeld = max(peakHeld, diagnostics.heldAudioSeconds ?? 0)
            peakHandoff = diagnostics.rows.first { $0.label == "Handoff peak" }?.value ?? peakHandoff
            if engine.revision != revision {
                let now = ProcessInfo.processInfo.systemUptime - start
                if firstHypothesis == nil, !engine.engine.hypothesis.isEmpty || !engine.confirmedLines.isEmpty {
                    firstHypothesis = now
                }
                if firstConfirmed == nil, !engine.confirmedLines.isEmpty { firstConfirmed = now }
                events.append(["wallSeconds": now,
                               "text": engine.transcript(includeHypothesis: true),
                               "confirmedLines": engine.confirmedLines.count])
                revision = engine.revision
            }
        }
        let finishStart = ProcessInfo.processInfo.systemUptime
        let final = await engine.endSession()
        let finishSeconds = ProcessInfo.processInfo.systemUptime - finishStart
        print("Parakeet replay: firstHypothesis=\(firstHypothesis.map { String(format: "%.2f", $0) } ?? "none") "
              + "firstConfirmed=\(firstConfirmed.map { String(format: "%.2f", $0) } ?? "none") "
              + "complete=\(final.complete) peakHeldEstimated=\(String(format: "%.1f", peakHeld)) "
              + "handoffPeak=\(peakHandoff) finish=\(String(format: "%.2f", finishSeconds)) load=\(String(format: "%.1f", loadSeconds))")
        print("Parakeet replay text:\n" + final.lines.map(\.text).joined(separator: "\n"))
        XCTAssertTrue(final.complete, engine.engine.failureMessage ?? "incomplete")
        XCTAssertFalse(final.lines.isEmpty)
        XCTAssertLessThanOrEqual(firstHypothesis ?? .infinity, 16,
                                 "No provisional hypothesis within 16 s of the stream start")
        XCTAssertEqual(engine.inbox.pendingFrames, 0)
        guard let output = env["RECORDER_STREAM_OUTPUT"] else { return }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let result: [String: Any] = [
            "backend": "app-parakeet-streaming",
            "audioSeconds": Double(samples.count) / 16000, "loadSeconds": loadSeconds,
            "events": events, "finishSeconds": finishSeconds, "complete": final.complete,
            "firstHypothesisSeconds": firstHypothesis ?? -1, "firstConfirmedSeconds": firstConfirmed ?? -1,
            "peakRSSBytes": usage.ru_maxrss, "peakHeldAudioSecondsEstimated": peakHeld, "handoffPeak": peakHandoff,
            "finalText": final.lines.map(\.text).joined(separator: "\n")
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }
}
