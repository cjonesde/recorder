import AVFoundation
import XCTest
@testable import Recorder

final class LiveStopReasonTests: XCTestCase {
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private func feed(_ inbox: StreamingAudioInput, _ source: StreamingAudioInput.Source, value: Float, count: Int) {
        let samples = [Float](repeating: value, count: count)
        samples.withUnsafeBufferPointer { inbox.ingest(source, $0.baseAddress!, count: $0.count, rate: 16000) }
    }

    func testDesktopOverCapacityIsHandoffFull() throws {
        let inbox = StreamingAudioInput()
        inbox.begin(format: format)
        feed(inbox, .desktop, value: 0.4, count: 8001)
        XCTAssertThrowsError(try inbox.drain()) { error in
            XCTAssertEqual((error as? LiveStopError)?.reason, .handoffFull)
        }
    }

    func testStaleDesktopAudioNamesTheDesktopChannel() throws {
        let inbox = StreamingAudioInput()
        inbox.begin(format: format)
        feed(inbox, .desktop, value: 0.4, count: 1600)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertThrowsError(try inbox.drain()) { error in
            XCTAssertEqual((error as? LiveStopError)?.reason, .desktopAudioAged)
        }
    }

    func testStaleMicAudioNamesTheMicChannel() throws {
        let inbox = StreamingAudioInput()
        inbox.begin(format: format)
        feed(inbox, .mic, value: 0.4, count: 1600)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertThrowsError(try inbox.drain()) { error in
            XCTAssertEqual((error as? LiveStopError)?.reason, .micAudioAged)
        }
    }

    func testEveryReasonHasDistinctUserMessage() {
        let messages = LiveStopReason.allCases.map(\.message)
        XCTAssertEqual(Set(messages).count, messages.count)
        XCTAssertFalse(messages.contains { $0.contains("\u{2014}") })
    }

    func testDetailIsAppendedToTheDescription() {
        let error = LiveStopError(reason: .engineError, detail: "boom")
        XCTAssertEqual(error.errorDescription, "\(LiveStopReason.engineError.message) (boom)")
        XCTAssertEqual(LiveStopError(reason: .engineError, detail: nil).errorDescription, LiveStopReason.engineError.message)
    }

    @MainActor
    func testFailureCarriesReasonIntoIncompleteMarker() async {
        var text = StreamingTranscript()
        text.markIncomplete(LiveStopError(reason: .engineQueueFull, detail: nil).localizedDescription)
        XCTAssertTrue(text.lines.last!.text.contains(LiveStopReason.engineQueueFull.message))
    }
}
