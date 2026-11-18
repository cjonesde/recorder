import XCTest
@testable import Recorder

@MainActor
final class RecordingNeverStopsTests: XCTestCase {

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition never became true", file: file, line: line)
    }

    private func recordingModel() async throws -> (RecorderModel, FakeLiveEngine) {
        let model = RecorderModel(engineFactory: { FakeLiveEngine(kind: $0) })
        model.configureCaptures()
        model.liveRestartDelay = { _ in .milliseconds(20) }
        try await model.live.beginSession(language: "en-US")
        model.state = .recording
        let fake = try XCTUnwrap(model.live.engine as? FakeLiveEngine)
        return (model, fake)
    }

    func testALiveEngineFailureRestartsLiveTextInsteadOfEndingTheRecording() async throws {
        let (model, fake) = try await recordingModel()
        XCTAssertEqual(fake.startSessionCalls, 1)

        fake.captureFailed(LiveStopError(reason: .engineQueueFull, detail: nil))

        try await waitUntil { fake.startSessionCalls == 2 }
        XCTAssertEqual(model.state, .recording)
        XCTAssertTrue(model.live.inRecordingSession)
        XCTAssertTrue(fake.isSessionActive)
        XCTAssertEqual(model.live.restarts, 1)
    }

    func testARestartThatFailsIsRetriedUntilLiveTextComesBack() async throws {
        let (model, fake) = try await recordingModel()
        fake.nextPrepareError = URLError(.cannotConnectToHost)

        fake.captureFailed(LiveStopError(reason: .engineQueueFull, detail: nil))

        try await waitUntil { fake.isSessionActive && fake.prepareCalls == 3 }
        XCTAssertEqual(model.state, .recording)
        XCTAssertEqual(model.live.restarts, 1)
    }

    func testLinesFromBeforeTheRestartAreKeptAndLaterLinesContinueTheTimeline() async throws {
        let (model, fake) = try await recordingModel()
        fake.confirmedLines = [TranscriptLine(time: 1, text: "before", speaker: nil)]
        fake.submittedThrough = 120

        fake.captureFailed(LiveStopError(reason: .engineQueueFull, detail: nil))
        try await waitUntil { fake.startSessionCalls == 2 }
        fake.confirmedLines = [TranscriptLine(time: 3, text: "after", speaker: nil)]

        let shown = model.live.confirmedLines
        XCTAssertEqual(shown.map(\.text), ["before", "after"])
        XCTAssertEqual(shown[0].time, 1)
        XCTAssertGreaterThanOrEqual(shown[1].time, 123)
        XCTAssertLessThan(shown[1].time, 125)

        let result = await model.live.endSession()
        XCTAssertEqual(result.lines.map(\.text), ["before", "after"])
        XCTAssertEqual(result.restarts, 1)
        XCTAssertFalse(model.live.inRecordingSession)
        XCTAssertEqual(model.live.confirmedLines.map(\.text), ["after"], "lines from the finished recording leaked into the next one")
    }

    func testLiveRestartsBackOffWhenTheEngineKeepsFailing() {
        XCTAssertEqual(RecorderModel.liveRestartDelay(attempt: 1), .seconds(2))
        XCTAssertEqual(RecorderModel.liveRestartDelay(attempt: 3), .seconds(8))
        XCTAssertEqual(RecorderModel.liveRestartDelay(attempt: 9), .seconds(30))
    }

    func testACaptureErrorLeavesTheRecordingAndLiveTextRunning() async throws {
        let (model, fake) = try await recordingModel()

        model.reportCaptureErrorForTesting(LiveStopError(reason: .desktopRingOverflow, detail: nil))

        XCTAssertEqual(model.state, .recording)
        XCTAssertTrue(fake.capturedErrors.isEmpty, "the capture error was forwarded to live text and ended it")
        XCTAssertNil(fake.failureMessage)
        XCTAssertTrue(model.statusMessage?.contains("Recording continues") == true)
    }

    func testTrashDuringARestartLeavesNothingRunning() async throws {
        let (model, fake) = try await recordingModel()
        fake.nextPrepareError = URLError(.cannotConnectToHost)
        model.liveRestartDelay = { _ in .seconds(5) }
        fake.captureFailed(LiveStopError(reason: .engineQueueFull, detail: nil))
        try await waitUntil { fake.prepareCalls == 2 }

        model.trashAndStop()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.live.inRecordingSession)
        XCTAssertFalse(fake.isSessionActive)
        XCTAssertEqual(fake.prepareCalls, 2)
    }
}
