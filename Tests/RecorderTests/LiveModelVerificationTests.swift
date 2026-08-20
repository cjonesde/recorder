import XCTest
import AVFoundation
@testable import Recorder

/// Exercises the real WhisperKit path through `ModelHost.withPipe`, which the unit
/// tests deliberately cannot reach because they substitute a fake pipe.
///
/// Needs a downloaded model, so it is opt-in:
///
///     RECORDER_LIVE_MODEL=1 swift test --filter LiveModelVerificationTests
@MainActor
final class LiveModelVerificationTests: XCTestCase {

    func testTranscribesRealAudioThroughTheModelHost() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RECORDER_LIVE_MODEL"] == "1",
            "set RECORDER_LIVE_MODEL=1 to run the real model check"
        )
        let fixture = ProcessInfo.processInfo.environment["RECORDER_TEST_AUDIO"]
        let path = try XCTUnwrap(fixture, "set RECORDER_TEST_AUDIO to a speech audio file")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: path),
            "RECORDER_TEST_AUDIO does not exist: \(path)"
        )

        let engine = LocalTranscriptionEngine()
        engine.labelSpeakers = false
        await engine.loadModel(WhisperModelOption.defaultModelID, downloadIfNeeded: false)
        XCTAssertEqual(engine.engineState, .ready, "model did not load")
        XCTAssertEqual(engine.loadedModelName, WhisperModelOption.defaultModelID)

        let result = try await engine.transcribeFile(URL(fileURLWithPath: path))
        let body = result.spokenText
        XCTAssertFalse(body.isEmpty, "the model returned no text")
        print("transcribed \(body.count) characters through the host")
    }

    func testConcurrentTranscriptionsDoNotInterleaveOnOneHost() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RECORDER_LIVE_MODEL"] == "1",
            "set RECORDER_LIVE_MODEL=1 to run the real model check"
        )
        let fixture = ProcessInfo.processInfo.environment["RECORDER_TEST_AUDIO"]
        let path = try XCTUnwrap(fixture, "set RECORDER_TEST_AUDIO to a speech audio file")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: path),
            "RECORDER_TEST_AUDIO does not exist: \(path)"
        )

        let engine = LocalTranscriptionEngine()
        engine.labelSpeakers = false
        await engine.loadModel(WhisperModelOption.defaultModelID, downloadIfNeeded: false)

        let url = URL(fileURLWithPath: path)
        async let first = engine.transcribeFile(url)
        async let second = engine.transcribeFile(url)
        let bodies = try await [first, second].map(\.spokenText)

        // Both must return usable text: an interleaved decode on a shared pipe yields
        // truncated or empty output. Byte equality is not asserted, because
        // temperatureFallbackCount lets low-confidence segments resample.
        for body in bodies {
            XCTAssertFalse(body.isEmpty, "a concurrent decode returned nothing")
        }
        let shorter = Double(min(bodies[0].count, bodies[1].count))
        let longer = Double(max(bodies[0].count, bodies[1].count))
        XCTAssertGreaterThan(
            shorter / longer, 0.5,
            "concurrent decodes differ wildly in length, which suggests interleaving: \(bodies)"
        )
    }
}
