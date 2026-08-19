import XCTest
@testable import Recorder

final class AudioHandlingModeTests: XCTestCase {

    func testOnlyKeepAudioModesRetainAudio() {
        XCTAssertFalse(AudioHandlingMode.transcriptOnly.retainsAudio)
        XCTAssertTrue(AudioHandlingMode.keepAudio.retainsAudio)
        XCTAssertTrue(AudioHandlingMode.keepAudioAndPolish.retainsAudio)
    }

    func testOnlyThePolishModeRunsThePolishPass() {
        XCTAssertFalse(AudioHandlingMode.transcriptOnly.runsPolishPass)
        XCTAssertFalse(AudioHandlingMode.keepAudio.runsPolishPass)
        XCTAssertTrue(AudioHandlingMode.keepAudioAndPolish.runsPolishPass)
    }

    func testAPolishPassAlwaysImpliesRetainedAudio() {
        for mode in AudioHandlingMode.allCases where mode.runsPolishPass {
            XCTAssertTrue(mode.retainsAudio, "\(mode) polishes without keeping audio")
        }
    }

    func testTranscriptOnlyWithLiveOffWouldProduceNothing() {
        XCTAssertTrue(AudioHandlingMode.transcriptOnly.producesNothing(liveTranscriptionEnabled: false))
        XCTAssertFalse(AudioHandlingMode.transcriptOnly.producesNothing(liveTranscriptionEnabled: true))
    }

    func testOtherModesAlwaysProduceSomething() {
        for mode in AudioHandlingMode.allCases where mode != .transcriptOnly {
            XCTAssertFalse(mode.producesNothing(liveTranscriptionEnabled: false))
            XCTAssertFalse(mode.producesNothing(liveTranscriptionEnabled: true))
        }
    }

    func testRawValuesAreStableForPersistence() {
        XCTAssertEqual(AudioHandlingMode.transcriptOnly.rawValue, "transcriptOnly")
        XCTAssertEqual(AudioHandlingMode.keepAudio.rawValue, "keepAudio")
        XCTAssertEqual(AudioHandlingMode.keepAudioAndPolish.rawValue, "keepAudioAndPolish")
        XCTAssertNil(AudioHandlingMode(rawValue: "nonsense"))
    }

    func testDefaultKeepsAudioAndPolishes() {
        XCTAssertEqual(AudioHandlingMode.default, .keepAudioAndPolish)
    }

    func testEveryModeHasUserFacingText() {
        for mode in AudioHandlingMode.allCases {
            XCTAssertFalse(mode.label.isEmpty)
            XCTAssertFalse(mode.detail.isEmpty)
            XCTAssertFalse(mode.label.contains("\u{2014}"))
            XCTAssertFalse(mode.detail.contains("\u{2014}"))
        }
    }
}
