import XCTest
import AVFoundation
@testable import Recorder

/// Verification against a real recording, gated because it downloads models and needs a
/// stereo file produced by the app.
///
/// This is the check that reading the SpeakerKit source was right: centroids are only
/// useful if `centroidSource` really does populate them by default, and "You" is only
/// structural if the microphone channel really is ch1.
///
///     RECORDER_LIVE_SPEAKERS=1 \
///     RECORDER_AUDIO=~/Documents/Recordings/<folder>/audio.m4a \
///     swift test --filter SpeakerDiarizationVerificationTests
@MainActor
final class SpeakerDiarizationVerificationTests: XCTestCase {

    private func audioURL() throws -> URL {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RECORDER_LIVE_SPEAKERS"] == "1",
            "set RECORDER_LIVE_SPEAKERS=1 to run the real diarization check"
        )
        let path = try XCTUnwrap(
            ProcessInfo.processInfo.environment["RECORDER_AUDIO"],
            "set RECORDER_AUDIO to a stereo audio.m4a recorded by the app"
        )
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "RECORDER_AUDIO does not exist: \(url.path)"
        )
        return url
    }

    func testRealRecordingProducesCentroidsAndAYouSpeaker() async throws {
        let url = try audioURL()

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(
            file.fileFormat.channelCount, 2,
            "the app writes desktop to ch0 and mic to ch1"
        )

        let engine = LocalTranscriptionEngine()
        engine.labelSpeakers = true
        await engine.loadModel(WhisperModelOption.defaultModelID, downloadIfNeeded: true)

        let result = try await engine.transcribeFile(url)

        XCTAssertFalse(result.lines.isEmpty, "the recording produced no transcript at all")

        let speakers = Set(result.lines.compactMap(\.speaker))
        XCTAssertTrue(
            speakers.contains(SpeakerNaming.micSpeakerID),
            "no line came from the microphone channel; check the recording actually has mic audio"
        )

        for (id, evidence) in result.clusters {
            XCTAssertFalse(
                evidence.centroid.isEmpty,
                "cluster \(id) has no centroid, so centroidSource is not populating them"
            )
            XCTAssertGreaterThan(evidence.speechSeconds, 0)
        }

        XCTAssertNil(
            result.clusters[SpeakerNaming.micSpeakerID],
            "the microphone must never produce a voiceprint"
        )

        print("speakers: \(speakers.sorted()), clusters with centroids: \(result.clusters.count)")
    }
}
