import XCTest
@testable import Recorder

final class TranscriptDocumentTests: XCTestCase {

    private func sample() -> TranscriptDocument {
        TranscriptDocument(
            meetingTitle: "Weekly",
            attendees: ["Anna", "Ben"],
            startedAt: Date(timeIntervalSince1970: 0),
            audioName: "audio.m4a",
            model: "openai_whisper-base",
            isPolished: false,
            lines: [
                TranscriptDocument.StoredLine(time: 0, text: "hello", speakerID: "you"),
                TranscriptDocument.StoredLine(time: 5, text: "hi there", speakerID: "s1"),
                TranscriptDocument.StoredLine(time: 9, text: "unattributed", speakerID: nil),
            ],
            speakerNames: ["you": "You", "s1": "Speaker 1"]
        )
    }

    func testSpeakerIDsAreInOrderOfFirstAppearance() {
        XCTAssertEqual(sample().speakerIDs, ["you", "s1"])
    }

    func testRenderIncludesHeaderAndTimestampedLines() {
        let markdown = sample().renderMarkdown()
        XCTAssertTrue(markdown.contains("# Transcript: Weekly"))
        XCTAssertFalse(markdown.contains("\u{2014}"), "em dashes are not allowed anywhere")
        XCTAssertTrue(markdown.contains("**Invited attendees:** Anna, Ben"))
        XCTAssertTrue(markdown.contains("[00:00] **You**: hello"))
        XCTAssertTrue(markdown.contains("[00:05] **Speaker 1**: hi there"))
        XCTAssertTrue(markdown.contains("[00:09] unattributed"))
    }

    func testRenamingChangesEveryLineForThatSpeaker() {
        let renamed = sample().renamingSpeaker("s1", to: "Ben")
        let markdown = renamed.renderMarkdown()
        XCTAssertTrue(markdown.contains("[00:05] **Ben**: hi there"))
        XCTAssertFalse(markdown.contains("Speaker 1"))
        XCTAssertTrue(markdown.contains("[00:00] **You**: hello"), "other speakers untouched")
    }

    func testRenamingIsIdempotent() {
        let once = sample().renamingSpeaker("s1", to: "Ben")
        let twice = once.renamingSpeaker("s1", to: "Ben")
        XCTAssertEqual(once, twice)
        XCTAssertEqual(once.renderMarkdown(), twice.renderMarkdown())
    }

    func testRenamingAnUnknownSpeakerChangesNothing() {
        let doc = sample()
        XCTAssertEqual(doc.renamingSpeaker("nope", to: "X"), doc)
    }

    func testRoundTripsThroughJSON() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doc-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let original = sample()
        try original.write(jsonTo: url)
        let loaded = try TranscriptDocument.load(from: url)
        XCTAssertEqual(loaded, original)
    }

    func testPolishedFlagIsRenderedSoTheSourceIsObvious() {
        var doc = sample()
        doc.isPolished = true
        XCTAssertTrue(doc.renderMarkdown().contains("high-quality pass"))
        doc.isPolished = false
        XCTAssertTrue(doc.renderMarkdown().contains("live transcription"))
    }

    func testNoAudioIsStatedExplicitlyWhenNoneWasRetained() {
        var doc = sample()
        doc.audioName = nil
        XCTAssertTrue(doc.renderMarkdown().contains("not retained"))
    }

    func testLinesFromTranscriptLinesPreserveSpeakerIdentity() {
        let lines = [
            TranscriptLine(time: 0, text: "hello", speaker: "You"),
            TranscriptLine(time: 4, text: "hi", speaker: "Them"),
            TranscriptLine(time: 8, text: "quiet", speaker: nil),
        ]
        let doc = TranscriptDocument(
            live: lines,
            meetingTitle: nil,
            attendees: [],
            startedAt: Date(timeIntervalSince1970: 0),
            audioName: nil,
            model: "openai_whisper-base"
        )
        XCTAssertEqual(doc.speakerIDs, ["You", "Them"])
        XCTAssertEqual(doc.displayName(for: "You"), "You")
        XCTAssertFalse(doc.isPolished)
        XCTAssertTrue(doc.renderMarkdown().contains("[00:08] quiet"))
    }
}
