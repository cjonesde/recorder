import XCTest
@testable import Recorder

final class RecordingSessionTests: XCTestCase {

    private func cleanUp(_ session: RecordingSession) {
        try? FileManager.default.removeItem(at: session.folderURL)
    }

    func testKeepAudioModesGetAudioPaths() throws {
        for mode in [AudioHandlingMode.keepAudio, .keepAudioAndPolish] {
            let session = try RecordingSession.create(
                now: Date(), meetingTitle: "PathTest-\(mode.rawValue)", mode: mode
            )
            defer { cleanUp(session) }
            XCTAssertNotNil(session.desktopURL)
            XCTAssertNotNil(session.micURL)
            XCTAssertNotNil(session.outputURL)
        }
    }

    func testTranscriptOnlyHasNoAudioPathsButStillHasAFolder() throws {
        let session = try RecordingSession.create(
            now: Date(), meetingTitle: "PathTestTranscriptOnly", mode: .transcriptOnly
        )
        defer { cleanUp(session) }
        XCTAssertNil(session.desktopURL)
        XCTAssertNil(session.micURL)
        XCTAssertNil(session.outputURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: session.folderURL.path),
            "the folder must exist so the transcript has a home"
        )
    }
}
