import AVFoundation
import Speech
import XCTest
@testable import Recorder

@MainActor
final class LiveFailureHandlingTests: XCTestCase {
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!

    private func chunk() throws -> AnalyzerInput {
        AnalyzerInput(buffer: try ErasingPCMBuffer.make(format: format, count: 800))
    }

    func testAnalyzerQueueAbsorbsTwoSecondsOfFiftyMillisecondChunks() throws {
        let (stream, continuation) = AppleLiveTranscriber.makeAnalyzerInputs()
        try withExtendedLifetime(stream) {
            for index in 0..<40 {
                guard case .enqueued = continuation.yield(try chunk()) else {
                    return XCTFail("chunk \(index) should have been queued")
                }
            }
            guard case .dropped = continuation.yield(try chunk()) else {
                return XCTFail("the forty-first chunk should overflow the queue")
            }
        }
    }

    func testOverflowDetailSaysWhetherTheQueueFilledOrTheStreamEnded() throws {
        XCTAssertEqual(AppleLiveTranscriber.overflowDetail(.dropped(try chunk())), "analyzer queue full, a chunk was dropped")
        XCTAssertEqual(AppleLiveTranscriber.overflowDetail(.terminated), "analyzer input stream had already ended")
    }
}
