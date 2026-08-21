import XCTest
@testable import Recorder

final class OfflineTranscriptionTests: XCTestCase {

    private func text(_ start: TimeInterval, _ end: TimeInterval, _ body: String) -> TimedText {
        TimedText(start: start, end: end, text: body)
    }

    func testMicLinesAreLabelledYouWithoutDiarization() {
        let result = OfflineTranscription.build(
            mic: [text(0, 2, "hello")],
            desktop: [],
            diarized: [],
            centroids: [:]
        )
        XCTAssertEqual(result.lines.map(\.speaker), [SpeakerNaming.micSpeakerID])
        XCTAssertEqual(result.speakerNames[SpeakerNaming.micSpeakerID], "You")
        XCTAssertTrue(result.clusters.isEmpty, "the microphone never produces a voiceprint")
    }

    func testBothChannelsMergeInStartTimeOrder() {
        let result = OfflineTranscription.build(
            mic: [text(0, 1, "first"), text(4, 5, "third")],
            desktop: [text(2, 3, "second")],
            diarized: [DiarizedSpan(start: 2, end: 3, clusterID: 0)],
            centroids: [0: [1, 0]]
        )
        XCTAssertEqual(result.lines.map(\.text), ["first", "second", "third"])
        XCTAssertEqual(result.lines.map(\.time), [0, 2, 4])
    }

    func testDesktopClustersAreNumberedByFirstSpeech() {
        let result = OfflineTranscription.build(
            mic: [],
            desktop: [text(0, 1, "a"), text(5, 6, "b"), text(10, 11, "c")],
            diarized: [
                DiarizedSpan(start: 0, end: 1, clusterID: 7),
                DiarizedSpan(start: 5, end: 6, clusterID: 3),
                DiarizedSpan(start: 10, end: 11, clusterID: 7),
            ],
            centroids: [7: [1, 0], 3: [0, 1]]
        )
        XCTAssertEqual(result.lines.map(\.speaker), ["s1", "s2", "s1"])
        XCTAssertEqual(result.speakerNames["s1"], "Speaker 1")
        XCTAssertEqual(result.speakerNames["s2"], "Speaker 2")
    }

    func testClusterEvidenceSumsSpeechAndCarriesTheCentroid() {
        let result = OfflineTranscription.build(
            mic: [],
            desktop: [text(0, 1, "a")],
            diarized: [
                DiarizedSpan(start: 0, end: 4, clusterID: 7),
                DiarizedSpan(start: 10, end: 13, clusterID: 7),
            ],
            centroids: [7: [1, 0]]
        )
        XCTAssertEqual(result.clusters["s1"]?.speechSeconds, 7)
        XCTAssertEqual(result.clusters["s1"]?.centroid, [1, 0])
    }

    func testADesktopLineWithNoOverlapIsLeftUnattributed() {
        let result = OfflineTranscription.build(
            mic: [],
            desktop: [text(50, 51, "orphan")],
            diarized: [DiarizedSpan(start: 0, end: 1, clusterID: 0)],
            centroids: [0: [1, 0]]
        )
        XCTAssertNil(result.lines.first?.speaker)
    }

    func testALineTakesTheClusterItOverlapsMost() {
        let result = OfflineTranscription.build(
            mic: [],
            desktop: [text(0, 10, "mostly the second speaker")],
            diarized: [
                DiarizedSpan(start: 0, end: 2, clusterID: 4),
                DiarizedSpan(start: 2, end: 10, clusterID: 9),
            ],
            centroids: [4: [1, 0], 9: [0, 1]]
        )
        XCTAssertEqual(result.lines.first?.speaker, "s2")
    }

    func testAClusterWithNoCentroidStillLabelsButProducesNoEvidence() {
        let result = OfflineTranscription.build(
            mic: [],
            desktop: [text(0, 1, "a")],
            diarized: [DiarizedSpan(start: 0, end: 1, clusterID: 7)],
            centroids: [:]
        )
        XCTAssertEqual(result.lines.first?.speaker, "s1")
        XCTAssertNil(result.clusters["s1"], "no centroid means nothing to enroll")
    }
}
