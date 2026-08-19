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

    @MainActor
    func testTranscriptOnlyUsesTheShorterLiveWindow() {
        XCTAssertEqual(
            LiveTranscriber.windowCap(for: .transcriptOnly),
            90 * Int(SampleInbox.targetRate)
        )
        for mode in [AudioHandlingMode.keepAudio, .keepAudioAndPolish] {
            XCTAssertEqual(
                LiveTranscriber.windowCap(for: mode),
                15 * 60 * Int(SampleInbox.targetRate)
            )
        }
    }

    // MARK: - Mid-recording changes

    func testDowngradingToTranscriptOnlyIsAllowedAndDeletesPartialAudio() {
        for active in [AudioHandlingMode.keepAudio, .keepAudioAndPolish] {
            XCTAssertEqual(
                AudioHandlingChange.decide(
                    from: active, to: .transcriptOnly, liveTranscriptionEnabled: true
                ),
                .apply
            )
            XCTAssertTrue(
                AudioHandlingChange.deletesPartialAudio(from: active, to: .transcriptOnly)
            )
        }
    }

    func testUpgradingMidRecordingIsRefused() {
        for requested in [AudioHandlingMode.keepAudio, .keepAudioAndPolish] {
            XCTAssertEqual(
                AudioHandlingChange.decide(
                    from: .transcriptOnly, to: requested, liveTranscriptionEnabled: true
                ),
                .refuseUpgrade,
                "audio that was never written cannot be recovered"
            )
        }
    }

    func testSwitchingBetweenKeepAudioModesKeepsTheAudio() {
        XCTAssertEqual(
            AudioHandlingChange.decide(
                from: .keepAudio, to: .keepAudioAndPolish, liveTranscriptionEnabled: true
            ),
            .apply
        )
        XCTAssertFalse(
            AudioHandlingChange.deletesPartialAudio(from: .keepAudio, to: .keepAudioAndPolish)
        )
    }

    func testTranscriptOnlyIsRefusedWhenNothingWouldBeSaved() {
        XCTAssertEqual(
            AudioHandlingChange.decide(
                from: .keepAudio, to: .transcriptOnly, liveTranscriptionEnabled: false
            ),
            .refuseNothingProduced
        )
    }

    func testStayingInTranscriptOnlyDeletesNothingFurther() {
        XCTAssertEqual(
            AudioHandlingChange.decide(
                from: .transcriptOnly, to: .transcriptOnly, liveTranscriptionEnabled: true
            ),
            .apply
        )
        XCTAssertFalse(
            AudioHandlingChange.deletesPartialAudio(from: .transcriptOnly, to: .transcriptOnly)
        )
    }
}
