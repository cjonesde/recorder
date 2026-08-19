import XCTest
import AVFoundation
@testable import Recorder

/// Drives a real `RecorderModel` through record and save for each audio-handling mode
/// and asserts what actually lands on disk. This is the central claim of the feature:
/// transcript-only must never leave audio behind.
///
/// Records into the real recordings folder, so it is opt-in and cleans up after itself:
///
///     RECORDER_LIVE_MODES=1 swift test --filter ModeMatrixIntegrationTests
@MainActor
final class ModeMatrixIntegrationTests: XCTestCase {

    /// Folders this test created, removed in teardown. Recordings land in the real
    /// library, so nothing may be left behind.
    private var created: [URL] = []

    override func tearDown() async throws {
        cleanUp()
    }

    /// Remove every folder this test created. Called explicitly at the end of each test
    /// as well as from teardown, because the save path finishes asynchronously and a
    /// teardown-only cleanup has been observed to race it.
    private func cleanUp() {
        for folder in created {
            try? FileManager.default.removeItem(at: folder)
        }
        created = []
    }

    private func makeModel(mode: AudioHandlingMode) -> RecorderModel {
        let model = RecorderModel()
        model.configureCaptures()
        model.silenceAutoStopEnabled = false
        model.liveTranscriptionEnabled = true
        model.audioHandlingMode = mode
        return model
    }

    private func record(
        mode: AudioHandlingMode,
        seconds: TimeInterval
    ) async throws -> URL {
        let model = makeModel(mode: mode)

        // No meeting: scheduling a meeting-end notification needs a real app bundle.
        model.startRecording(meeting: nil)
        let session = try XCTUnwrap(
            model.currentSession,
            "recording did not start: \(model.statusMessage ?? "no message")"
        )
        let folder = session.folderURL
        created.append(folder)

        XCTAssertEqual(mode.retainsAudio, session.outputURL != nil)

        try await Task.sleep(for: .seconds(seconds))
        model.saveAndStop()

        // Let the mix and transcript work finish.
        try await Task.sleep(for: .seconds(20))
        return folder
    }

    private func contents(_ folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    func testTranscriptOnlyLeavesNoAudioOnDisk() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RECORDER_LIVE_MODES"] == "1",
            "set RECORDER_LIVE_MODES=1 to run the mode matrix check"
        )

        let folder = try await record(mode: .transcriptOnly, seconds: 8)
        let files = contents(folder)
        print("transcriptOnly produced: \(files.sorted())")

        for audio in ["audio.m4a", "desktop.caf", "mic.caf"] {
            XCTAssertFalse(files.contains(audio), "transcript-only wrote \(audio)")
        }
        XCTAssertTrue(
            files.allSatisfy { $0.hasSuffix(".md") || $0.hasSuffix(".json") },
            "transcript-only left non-transcript files: \(files.sorted())"
        )
        cleanUp()
    }

    func testKeepAudioWritesTheAudioFiles() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RECORDER_LIVE_MODES"] == "1",
            "set RECORDER_LIVE_MODES=1 to run the mode matrix check"
        )

        let folder = try await record(mode: .keepAudio, seconds: 8)
        let files = contents(folder)
        print("keepAudio produced: \(files.sorted())")

        XCTAssertTrue(files.contains("desktop.caf"), "missing desktop.caf")
        XCTAssertTrue(files.contains("mic.caf"), "missing mic.caf")
        XCTAssertTrue(files.contains("audio.m4a"), "the mixer did not run")
        cleanUp()
    }

    func testDowngradingMidRecordingDeletesThePartialAudio() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RECORDER_LIVE_MODES"] == "1",
            "set RECORDER_LIVE_MODES=1 to run the mode matrix check"
        )

        let model = makeModel(mode: .keepAudioAndPolish)
        model.startRecording(meeting: nil)
        let session = try XCTUnwrap(model.currentSession)
        let folder = session.folderURL
        created.append(folder)

        try await Task.sleep(for: .seconds(5))
        XCTAssertTrue(contents(folder).contains("desktop.caf"), "audio was not being written")

        // Upgrading is refused, downgrading is applied and deletes what was written.
        XCTAssertTrue(model.changeAudioHandling(to: .transcriptOnly))
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(model.changeAudioHandling(to: .keepAudio), "upgrade should be refused")

        try await Task.sleep(for: .seconds(4))
        model.saveAndStop()
        try await Task.sleep(for: .seconds(20))

        let files = contents(folder)
        print("downgrade produced: \(files.sorted())")
        for audio in ["audio.m4a", "desktop.caf", "mic.caf"] {
            XCTAssertFalse(files.contains(audio), "downgrade left \(audio) behind")
        }
        cleanUp()
    }
}
