import XCTest
@testable import Recorder

@MainActor
final class StopSourceTests: XCTestCase {
    func testEverySourceNamesItselfInPlainWords() {
        XCTAssertEqual(StopSource.panelSave.label, "panel save button")
        XCTAssertEqual(StopSource.meetingEndNotification.label, "meeting-end notification")
        XCTAssertEqual(StopSource.silenceTimeout.label, "silence timeout")
        XCTAssertEqual(StopSource.liveEngineFailure("engineFellBehind").label, "live engine failure: engineFellBehind")
        XCTAssertEqual(StopSource.captureFailure("mic route unusable").label, "capture failure: mic route unusable")
    }

    func testStopRequestIsRecordedWithItsSource() {
        var clock = 0.0
        let recorder = DiagnosticsRecorder(source: FakeMetrics([reading()]), now: { clock }, engine: .apple, settings: [:])
        recorder.setPhase(.recording)
        clock = 902
        recorder.recordStopRequest(.silenceTimeout)

        let event = recorder.events.last
        XCTAssertEqual(event?.kind, "stop requested")
        XCTAssertEqual(event?.detail, "silence timeout")
        XCTAssertEqual(event?.phase, .recording)
        XCTAssertEqual(event?.t, 902)
    }

    func testFirstStopRequestWinsWhenSeveralArrive() {
        let recorder = DiagnosticsRecorder(source: FakeMetrics([reading()]), now: { 0 }, engine: .apple, settings: [:])
        recorder.recordStopRequest(.liveEngineFailure("engineError"))
        recorder.recordStopRequest(.panelSave)

        XCTAssertEqual(recorder.events.filter { $0.kind == "stop requested" }.map(\.detail), ["live engine failure: engineError"])
    }
}
