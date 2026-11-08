import AVFoundation
import Speech
import XCTest
@testable import Recorder

final class AppleHeldAudioTests: XCTestCase {

    private func format() throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
    }

    func testLifetimeLogReportsMedianAndLongest() {
        let log = BufferLifetimeLog()
        let epoch = log.begin()
        XCTAssertNil(log.summary)
        for seconds in [0.1, 0.3, 0.2, 0.9] { log.record(seconds, epoch: epoch) }
        XCTAssertEqual(log.summary, BufferLifetimeLog.Summary(median: 0.25, longest: 0.9, released: 4))
    }

    func testLifetimeLogIgnoresBuffersFromAnEarlierSession() {
        let log = BufferLifetimeLog()
        let old = log.begin()
        _ = log.begin()
        log.record(5, epoch: old)
        XCTAssertNil(log.summary)
    }

    func testLifetimeLogKeepsTheLongestBeyondTheRecentWindow() {
        let log = BufferLifetimeLog()
        let epoch = log.begin()
        log.record(7, epoch: epoch)
        for _ in 0..<BufferLifetimeLog.recentCapacity { log.record(0.1, epoch: epoch) }
        let summary = log.summary
        XCTAssertEqual(summary?.median ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(summary?.longest, 7)
        XCTAssertEqual(summary?.released, BufferLifetimeLog.recentCapacity + 1)
    }

    func testErasingBufferRecordsItsLifetimeWhenReleased() throws {
        let log = BufferLifetimeLog()
        _ = log.begin()
        var buffer: AVAudioPCMBuffer? = try ErasingPCMBuffer.make(format: format(), count: 160, lifetimes: log)
        XCTAssertNotNil(buffer)
        XCTAssertNil(log.summary)
        buffer = nil
        XCTAssertEqual(log.summary?.released, 1)
    }

    func testDrainedChunksFeedTheInboxLifetimeLog() throws {
        let inbox = StreamingAudioInput()
        inbox.begin(format: try format())
        let samples = [Float](repeating: 0.1, count: 1_600)
        samples.withUnsafeBufferPointer { inbox.ingest(.desktop, $0.baseAddress!, count: $0.count, rate: 16_000) }
        samples.withUnsafeBufferPointer { inbox.ingest(.mic, $0.baseAddress!, count: $0.count, rate: 16_000) }
        var chunk = try inbox.drain(flush: true)
        XCTAssertNotNil(chunk)
        chunk = nil
        XCTAssertEqual(inbox.bufferLifetimes.summary?.released, 1)
    }

    func testMeteredInputsCountChunksUntilTheAnalyzerTakesThem() async throws {
        let meter = QueuedAudioMeter()
        meter.reset(rate: 16_000)
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let int16 = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try ErasingPCMBuffer.make(format: int16, count: 1_600)
        meter.add(1_600)
        continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: .zero))
        continuation.finish()
        XCTAssertEqual(meter.seconds, 0.1, accuracy: 1e-9)
        var iterator = MeteredAnalyzerInputs(base: stream, meter: meter).makeAsyncIterator()
        let taken = await iterator.next()
        XCTAssertNotNil(taken)
        XCTAssertEqual(meter.seconds, 0, accuracy: 1e-9)
    }

    func testBufferReleaseRowIsUnknownUntilABufferIsReleased() {
        XCTAssertEqual(AppleLiveTranscriber.bufferReleaseRow(nil),
                       DiagnosticRow(label: "Buffer release", value: "none yet", quality: .unknown))
        XCTAssertEqual(AppleLiveTranscriber.bufferReleaseRow(.init(median: 0.12, longest: 0.4, released: 3)),
                       DiagnosticRow(label: "Buffer release", value: "median 0.12 s, max 0.40 s", quality: .measured))
    }

    @MainActor
    func testAppleDiagnosticsListInboxQueueAndBufferRelease() {
        let labels = AppleLiveTranscriber().diagnostics().rows.map(\.label)
        XCTAssertEqual(labels, ["App inbox", "Queued for Apple", "Buffer release", "Inside Apple"])
    }
}
