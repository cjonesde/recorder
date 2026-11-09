import AVFoundation
import CoreMedia
import XCTest
@testable import Recorder

final class AppleStreamingTests: XCTestCase {
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private func feed(_ inbox: StreamingAudioInput, _ source: StreamingAudioInput.Source, value: Float, count: Int) {
        let samples = [Float](repeating: value, count: count)
        samples.withUnsafeBufferPointer { inbox.ingest(source, $0.baseAddress!, count: $0.count, rate: 16000) }
    }

    func testConsumedInputIsRemovedAndSilentMicDoesNotHalveSpeech() throws {
        let inbox = StreamingAudioInput()
        inbox.begin(format: format)
        feed(inbox, .desktop, value: 0.4, count: 1600)
        feed(inbox, .mic, value: 0, count: 1600)
        let chunk = try XCTUnwrap(inbox.drain())
        XCTAssertEqual(chunk.buffer.frameLength, 1600)
        XCTAssertEqual(chunk.buffer.floatChannelData![0][0], 0.4, accuracy: 0.0001)
        XCTAssertEqual(chunk.start, 0)
        XCTAssertEqual(inbox.pendingFrames, 0)
        XCTAssertNil(try inbox.drain())
        inbox.discard()
    }

    func testHalfSecondLimitFailsClosedAndErasesBacklog() throws {
        let inbox = StreamingAudioInput()
        inbox.begin(format: format)
        feed(inbox, .mic, value: 0.4, count: 8001)
        XCTAssertEqual(inbox.pendingFrames, 0)
        XCTAssertThrowsError(try inbox.drain())
        feed(inbox, .desktop, value: 0.4, count: 1600)
        XCTAssertEqual(inbox.pendingFrames, 0)
    }

    func testCancelRejectsLateCallbacksAndRestartHasNoOldSamples() throws {
        let inbox = StreamingAudioInput()
        inbox.begin(format: format)
        feed(inbox, .mic, value: 0.8, count: 1600)
        inbox.discard()
        feed(inbox, .mic, value: 0.8, count: 1600)
        XCTAssertEqual(inbox.pendingFrames, 0)
        inbox.begin(format: format)
        feed(inbox, .mic, value: 0.2, count: 1600)
        let chunk = try XCTUnwrap(inbox.drain(flush: true))
        XCTAssertEqual(chunk.start, 0)
        XCTAssertEqual(chunk.buffer.floatChannelData![0][1599], 0.2, accuracy: 0.0001)
        inbox.discard()
    }

    func testStopFlushesTailAndRejectsNewInput() throws {
        let inbox = StreamingAudioInput()
        inbox.begin(format: format)
        feed(inbox, .desktop, value: 0.2, count: 1800)
        feed(inbox, .mic, value: 0.3, count: 1700)
        inbox.end()
        feed(inbox, .mic, value: 0.8, count: 1600)
        let first = try XCTUnwrap(inbox.drain(flush: true))
        let tail = try XCTUnwrap(inbox.drain(flush: true))
        XCTAssertEqual(first.buffer.frameLength, 1600)
        XCTAssertEqual(tail.buffer.frameLength, 200)
        XCTAssertEqual(tail.start, 0.1, accuracy: 0.0001)
        XCTAssertEqual(tail.buffer.floatChannelData![0][199], 0.2, accuracy: 0.0001)
        XCTAssertEqual(inbox.pendingFrames, 0)
    }

    func testInt16ConversionClipsWithoutOverflow() throws {
        let inbox = StreamingAudioInput()
        inbox.begin(format: AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!)
        feed(inbox, .desktop, value: 0.8, count: 1600)
        feed(inbox, .mic, value: 0.8, count: 1600)
        let chunk = try XCTUnwrap(inbox.drain())
        withExtendedLifetime(chunk) {
            XCTAssertEqual(chunk.buffer.int16ChannelData![0][0], 32767)
        }
    }

    func testAdjacentInputsHaveExactNonOverlappingSampleTimes() throws {
        let inbox = StreamingAudioInput()
        inbox.begin(format: format)
        var expected = CMTime.zero
        for _ in 0..<50 {
            feed(inbox, .mic, value: 0.1, count: 1600)
            let chunk = try XCTUnwrap(inbox.drain(flush: true))
            XCTAssertEqual(CMTimeCompare(chunk.startTime, expected), 0)
            expected = CMTimeAdd(chunk.startTime, CMTime(value: Int64(chunk.buffer.frameLength), timescale: 16000))
        }
    }

    func testProvisionalCorrectionsDoNotDuplicateCommittedText() {
        var transcript = StreamingTranscript()
        transcript.update(text: "hello", start: 0, end: 1, final: false, speaker: nil)
        transcript.update(text: "hello world", start: 0, end: 2, final: false, speaker: nil)
        XCTAssertEqual(transcript.hypothesis, "hello world")
        transcript.update(text: "Hello world.", start: 0, end: 2, final: true, speaker: "You")
        transcript.update(text: "stale", start: 0, end: 2, final: false, speaker: nil)
        transcript.update(text: "Hello world.", start: 0, end: 2, final: true, speaker: nil)
        XCTAssertEqual(transcript.lines.count, 1)
        XCTAssertEqual(transcript.lines.first?.speaker, "You")
        XCTAssertEqual(transcript.hypothesis, "")
        transcript.update(text: "next", start: 2, end: 3, final: false, speaker: nil)
        transcript.markIncomplete("capture failed")
        XCTAssertTrue(transcript.lines.contains { $0.text == "[unconfirmed] next" })
        XCTAssertTrue(transcript.lines.last!.text.contains("capture failed"))
    }

    func testLanguageMigrationNeverLeavesAutoSelected() {
        XCTAssertEqual(TranscriptionLanguage.selection(for: "auto", preferred: "de-AT"), "de-DE")
        XCTAssertEqual(TranscriptionLanguage.selection(for: "en"), "en-US")
        XCTAssertEqual(TranscriptionLanguage.selection(for: "fr-FR"), "fr-FR")
        XCTAssertEqual(TranscriptionLanguage.selection(for: "auto", preferred: "ja-JP"), "en-US")
        XCTAssertFalse(TranscriptionLanguage.options.contains { $0.id == "auto" })
    }

    @MainActor
    func testCancelBeforePreparationTaskRunsNeverStartsCapture() async {
        let model = RecorderModel()
        model.startRecording(meeting: nil)
        XCTAssertEqual(model.state, .preparing)
        XCTAssertNil(model.currentSession)
        model.trashAndStop()
        await Task.yield()
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.currentSession)
        XCTAssertFalse(model.live.isSessionActive)
        XCTAssertTrue(model.canStartRecording)
    }

    @MainActor
    func testLanguageAndLiveToggleStayFixedDuringPreparation() {
        let model = RecorderModel()
        let language = model.transcriptionLanguage
        model.state = .preparing
        model.transcriptionLanguage = language == "en-US" ? "de-DE" : "en-US"
        model.liveTranscriptionEnabled = false
        XCTAssertEqual(model.transcriptionLanguage, language)
        XCTAssertTrue(model.liveTranscriptionEnabled)
        XCTAssertFalse(model.changeAudioHandling(to: .keepAudio))
        XCTAssertFalse(model.canStartRecording)
    }
}
