import XCTest
@testable import Recorder

@MainActor
final class LiveRecordingStaysUpTests: XCTestCase {
    func testTranscriptOnlyRecordingKeepsRunningOnRealDevices() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RECORDER_LIVE_MODES"] == "1",
            "set RECORDER_LIVE_MODES=1 to record from the real microphone and desktop tap"
        )
        let model = RecorderModel()
        model.configureCaptures()
        model.silenceAutoStopEnabled = false
        model.liveTranscriptionEnabled = true
        model.audioHandlingMode = .transcriptOnly
        model.transcriptionLanguage = "en-US"

        model.startRecording(meeting: nil)
        while model.state == .preparing { try await Task.sleep(for: .milliseconds(50)) }
        let folder = try XCTUnwrap(model.currentSession?.folderURL, "did not start: \(model.statusMessage ?? "-")")
        defer { try? FileManager.default.removeItem(at: folder) }

        try await Task.sleep(for: .seconds(6))
        let failure = model.live.live.failureMessage
        let state = model.state
        model.saveAndStop()
        try await Task.sleep(for: .seconds(4))

        XCTAssertNil(failure, "live transcription failed while recording")
        XCTAssertEqual(state, .recording, "recording stopped on its own: \(model.statusMessage ?? "-")")
    }
}
