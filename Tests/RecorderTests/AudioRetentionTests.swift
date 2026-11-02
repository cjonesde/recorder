import XCTest
@testable import Recorder

@MainActor
final class AudioRetentionTests: XCTestCase {
    func testEndingWithoutAReadyModelStillDiscardsItsAudio() async throws {
        let live = LiveTranscriber(host: WhisperModelStorage.makeHost())
        live.beginSession()
        let samples = [Float](repeating: 0.25, count: 1600)
        samples.withUnsafeBufferPointer { buffer in
            live.inbox.ingest(.mic, buffer.baseAddress!, count: buffer.count, rate: 16000)
        }
        let result = await live.endSession()
        XCTAssertFalse(result.complete)
        XCTAssertTrue(live.inbox.drain(flush: true).isEmpty)
        let window = try XCTUnwrap(Mirror(reflecting: live).children.first {
            $0.label == "windowSamples" || $0.label == "_windowSamples"
        }?.value as? [Float])
        XCTAssertTrue(window.isEmpty, "a failed final decode must not retain audio after the session ends")
    }

    func testCancellingASessionDiscardsAudioStillWaitingInTheInbox() {
        let live = LiveTranscriber(host: WhisperModelStorage.makeHost())
        live.beginSession()
        let samples = [Float](repeating: 0.25, count: 1600)
        samples.withUnsafeBufferPointer { buffer in
            live.inbox.ingest(.mic, buffer.baseAddress!, count: buffer.count, rate: 16000)
        }
        live.cancelSession()
        XCTAssertTrue(live.inbox.drain(flush: true).isEmpty,
                      "cancel must discard pending input even when the model never loaded")
    }

    func testConsumedRingSlotsAreErasedBeforeTheyAreReused() throws {
        let ring = FloatRingBuffer(capacityFrames: 8)
        let input: [Float] = [1, 2, 3, 4, 5, 6]
        input.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: $0.count) }
        var output = [Float](repeating: 0, count: 4)
        let read = output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxCount: $0.count) }
        XCTAssertEqual(read, 4)
        XCTAssertEqual(output, [1, 2, 3, 4])
        // Inspect the owned allocation: correct output alone cannot prove erasure.
        let storage = try XCTUnwrap(Mirror(reflecting: ring).children.first { $0.label == "storage" }?.value as? UnsafeMutablePointer<Float>)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: storage, count: 6)), [0, 0, 0, 0, 5, 6])
        input.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: $0.count) }
        var wrapped = [Float](repeating: 0, count: 8)
        _ = wrapped.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxCount: $0.count) }
        XCTAssertEqual(wrapped, [5, 6, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: storage, count: 8)), Array(repeating: 0, count: 8))
    }
}
