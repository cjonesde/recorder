import XCTest
@testable import Recorder

final class TranscriptLineTests: XCTestCase {

    func testTimestampLabelUsesMinutesAndSecondsUnderAnHour() {
        XCTAssertEqual(TranscriptLine(time: 0, text: "a", speaker: nil).timestampLabel, "00:00")
        XCTAssertEqual(TranscriptLine(time: 5, text: "a", speaker: nil).timestampLabel, "00:05")
        XCTAssertEqual(TranscriptLine(time: 61, text: "a", speaker: nil).timestampLabel, "01:01")
        XCTAssertEqual(TranscriptLine(time: 3599, text: "a", speaker: nil).timestampLabel, "59:59")
    }

    func testTimestampLabelAddsHoursPastAnHour() {
        XCTAssertEqual(TranscriptLine(time: 3600, text: "a", speaker: nil).timestampLabel, "1:00:00")
        XCTAssertEqual(TranscriptLine(time: 3725, text: "a", speaker: nil).timestampLabel, "1:02:05")
    }

    func testMarkdownOmitsTheSpeakerPrefixWhenUnknown() {
        let line = TranscriptLine(time: 65, text: "hello there", speaker: nil)
        XCTAssertEqual(line.markdown, "[01:05] hello there")
    }

    func testMarkdownBoldsTheSpeakerWhenKnown() {
        let line = TranscriptLine(time: 65, text: "hello there", speaker: "You")
        XCTAssertEqual(line.markdown, "[01:05] **You**: hello there")
    }
}
