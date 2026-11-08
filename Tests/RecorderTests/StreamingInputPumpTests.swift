import AVFoundation
import XCTest
@testable import Recorder

private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var error: Error?

    func add(_ n: Int) { lock.withLock { frames += n } }
    func fail(_ e: Error) { lock.withLock { error = e } }
    var deliveredFrames: Int { lock.withLock { frames } }
    var failure: Error? { lock.withLock { error } }
}

final class StreamingInputPumpTests: XCTestCase {
    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private static func feedDesktopInRealTime(_ inbox: StreamingAudioInput, callbacks: Int, frames: Int) {
        let samples = [Float](repeating: 0.1, count: frames)
        for _ in 0..<callbacks {
            samples.withUnsafeBufferPointer { inbox.ingest(.desktop, $0.baseAddress!, count: frames, rate: 16000) }
            usleep(UInt32(frames) * 1_000_000 / 16000)
        }
    }

    @MainActor
    func testKeepsDrainingWhileTheMainThreadIsBlockedByDeviceStartup() throws {
        let inbox = StreamingAudioInput()
        inbox.begin(format: Self.format)
        let tally = Tally()
        let pump = StreamingInputPump(
            inbox: inbox,
            deliver: { chunk in tally.add(Int(chunk.buffer.frameLength)) },
            onFailure: { tally.fail($0) }
        )
        pump.start()

        let callbacks = 40, frames = 512
        let fed = expectation(description: "feeder finished")
        Thread.detachNewThread {
            Self.feedDesktopInRealTime(inbox, callbacks: callbacks, frames: frames)
            fed.fulfill()
        }
        Thread.sleep(forTimeInterval: 1.3)
        wait(for: [fed], timeout: 5)

        XCTAssertNil(pump.finish())
        XCTAssertNil(tally.failure, "pump failed while the main thread was blocked")
        XCTAssertEqual(tally.deliveredFrames, callbacks * frames)
        XCTAssertEqual(inbox.pendingFrames, 0)
        inbox.discard()
    }

    @MainActor
    func testStopsDeliveringAfterTheFirstFailure() throws {
        let inbox = StreamingAudioInput()
        inbox.begin(format: Self.format)
        let tally = Tally()
        let pump = StreamingInputPump(
            inbox: inbox,
            deliver: { chunk in
                tally.add(Int(chunk.buffer.frameLength))
                throw StreamingSpeechError.inputOverrun
            },
            onFailure: { tally.fail($0) }
        )
        let samples = [Float](repeating: 0.1, count: 3200)
        samples.withUnsafeBufferPointer { inbox.ingest(.desktop, $0.baseAddress!, count: 3200, rate: 16000) }

        XCTAssertNotNil(pump.finish())
        XCTAssertEqual(tally.deliveredFrames, 1600, "kept delivering after the first error")
        XCTAssertNil(pump.finish(), "a failed pump should not drain again")
        inbox.discard()
    }
}
