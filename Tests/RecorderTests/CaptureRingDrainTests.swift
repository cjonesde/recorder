import AVFoundation
import XCTest
@testable import Recorder

final class CaptureRingDrainTests: XCTestCase {

    private let rate = 48_000.0
    private let chunkFrames = 4096
    private var allocations: [UnsafeMutablePointer<Float>] = []

    override func tearDown() {
        for chunk in allocations { chunk.deallocate() }
        allocations = []
        super.tearDown()
    }

    private final class Sinks {
        var persisted: [Float] = []
        var forwarded: [Float] = []
        var forwardCalls: [Int] = []
    }

    private func frames(_ seconds: Double) -> Int { Int(seconds * rate) }

    private func produce(_ ring: FloatRingBuffer, seconds: Double, startingAt start: Int = 1) -> Int {
        var next = start
        let block = 480
        var remaining = frames(seconds)
        var samples = [Float](repeating: 0, count: block)
        while remaining > 0 {
            let n = min(block, remaining)
            for i in 0..<n { samples[i] = Float(next + i) }
            samples.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: n) }
            next += n
            remaining -= n
        }
        return next
    }

    private func drainAll(_ drain: CaptureRingDrain, persisting: Bool, into sinks: Sinks, chunk: UnsafeMutablePointer<Float>) throws -> CaptureRingDrain.Report {
        var total = CaptureRingDrain.Report()
        for _ in 0..<10_000 {
            let report = try drain.drainOnce(
                persisting: persisting,
                persist: { n in sinks.persisted.append(contentsOf: UnsafeBufferPointer(start: chunk, count: n)) },
                forward: { samples, n in
                    sinks.forwarded.append(contentsOf: UnsafeBufferPointer(start: samples, count: n))
                    sinks.forwardCalls.append(n)
                }
            )
            total.drainedFrames += report.drainedFrames
            total.paddedFrames += report.paddedFrames
            if let gap = report.gap {
                total.gap = CaptureRingDrain.Gap(
                    heldBackFromLiveFrames: (total.gap?.heldBackFromLiveFrames ?? 0) + gap.heldBackFromLiveFrames,
                    lostFrames: (total.gap?.lostFrames ?? 0) + gap.lostFrames
                )
            }
            if report.drainedFrames == 0 && report.paddedFrames == 0 { break }
        }
        return total
    }

    private func makeDrain(keepsAudio: Bool) -> (CaptureRingDrain, UnsafeMutablePointer<Float>) {
        let ring = FloatRingBuffer(capacityFrames: CaptureRingDrain.ringCapacity(sampleRate: rate, keepsAudio: keepsAudio))
        let chunk = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames)
        chunk.initialize(repeating: 0, count: chunkFrames)
        allocations.append(chunk)
        return (CaptureRingDrain(ring: ring, sampleRate: rate, chunk: chunk, chunkFrames: chunkFrames), chunk)
    }

    func testATwoSecondWriterStallDoesNotStopARecordingThatKeepsAudio() throws {
        let (drain, chunk) = makeDrain(keepsAudio: true)
        let sinks = Sinks()
        _ = produce(drain.ring, seconds: 2)

        let report = try drainAll(drain, persisting: true, into: sinks, chunk: chunk)

        XCTAssertEqual(sinks.persisted.count, frames(2), "desktop.caf lost audio")
        XCTAssertEqual(sinks.persisted.first, 1)
        XCTAssertEqual(sinks.persisted.last, Float(frames(2)))
    }

    func testOnlyTheFreshestQuarterSecondOfABacklogReachesLiveText() throws {
        let (drain, chunk) = makeDrain(keepsAudio: true)
        let sinks = Sinks()
        _ = produce(drain.ring, seconds: 2)

        let report = try drainAll(drain, persisting: true, into: sinks, chunk: chunk)

        XCTAssertEqual(sinks.forwarded.count, frames(0.25))
        XCTAssertEqual(sinks.forwarded.last, Float(frames(2)), "the newest samples were not the ones forwarded")
        XCTAssertEqual(report.gap?.heldBackFromLiveFrames, frames(1.75))
    }

    func testTheLiveHandoffSurvivesTheBurstAfterAStall() throws {
        let (drain, chunk) = makeDrain(keepsAudio: true)
        let input = StreamingAudioInput()
        input.begin(format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!)
        _ = produce(drain.ring, seconds: 2)

        for _ in 0..<10_000 {
            let report = try drain.drainOnce(
                persisting: true,
                persist: { _ in },
                forward: { samples, n in input.ingest(.desktop, samples, count: n, rate: self.rate) }
            )
            if report.drainedFrames == 0 && report.paddedFrames == 0 { break }
        }
        _ = chunk

        XCTAssertNoThrow(try input.drain(flush: true), "live text would stop after the stall")
    }

    func testAStallLongerThanTheRingKeepsTheFileInStepWithSilence() throws {
        let (drain, chunk) = makeDrain(keepsAudio: true)
        let sinks = Sinks()
        let capacity = CaptureRingDrain.ringCapacity(sampleRate: rate, keepsAudio: true)
        let stalled = Double(capacity) / rate + 1
        _ = produce(drain.ring, seconds: stalled)

        let report = try drainAll(drain, persisting: true, into: sinks, chunk: chunk)

        XCTAssertEqual(sinks.persisted.count, frames(stalled), "desktop.caf would drift against mic.caf")
        XCTAssertEqual(sinks.persisted[capacity - 1], Float(capacity))
        XCTAssertTrue(sinks.persisted[capacity...].allSatisfy { $0 == 0 }, "the dropped stretch was not silence")
        XCTAssertFalse(sinks.forwarded.contains(0), "padding silence reached live text")
        XCTAssertEqual(report.gap?.lostFrames, frames(stalled) - capacity)
        XCTAssertEqual(report.paddedFrames, frames(stalled) - capacity)
    }

    func testADrainThatKeepsUpForwardsEverythingAndReportsNoGap() throws {
        let (drain, chunk) = makeDrain(keepsAudio: true)
        let sinks = Sinks()
        _ = produce(drain.ring, seconds: 0.02)

        let report = try drainAll(drain, persisting: true, into: sinks, chunk: chunk)

        XCTAssertEqual(sinks.persisted, sinks.forwarded)
        XCTAssertEqual(sinks.forwarded.count, frames(0.02))
        XCTAssertNil(report.gap)
    }

    func testTranscriptOnlyHoldsAtMostHalfASecondAndKeepsGoingAfterAnOverflow() throws {
        XCTAssertEqual(CaptureRingDrain.ringCapacity(sampleRate: rate, keepsAudio: false), frames(0.5))
        let (drain, chunk) = makeDrain(keepsAudio: false)
        let sinks = Sinks()
        let next = produce(drain.ring, seconds: 0.6)

        let report = try drainAll(drain, persisting: false, into: sinks, chunk: chunk)

        XCTAssertTrue(sinks.persisted.isEmpty)
        XCTAssertEqual(sinks.forwarded.count, frames(0.25))
        XCTAssertEqual(report.gap?.lostFrames, frames(0.1))
        XCTAssertEqual(report.paddedFrames, 0, "transcript-only wrote silence somewhere")

        _ = produce(drain.ring, seconds: 0.02, startingAt: next)
        let after = try drainAll(drain, persisting: false, into: sinks, chunk: chunk)
        XCTAssertEqual(after.drainedFrames, frames(0.02), "capture did not continue after the overflow")
        XCTAssertNil(after.gap)
    }

    func testARecordingDowngradedToTranscriptOnlyDropsTheStaleBacklogInsteadOfStopping() throws {
        let (drain, chunk) = makeDrain(keepsAudio: true)
        let sinks = Sinks()
        _ = produce(drain.ring, seconds: 2)

        let report = try drainAll(drain, persisting: false, into: sinks, chunk: chunk)

        XCTAssertTrue(sinks.persisted.isEmpty)
        XCTAssertEqual(sinks.forwarded.count, frames(0.25))
        XCTAssertEqual(report.gap?.heldBackFromLiveFrames, frames(1.75))
        XCTAssertEqual(drain.ring.availableFrames, 0, "audio stayed in memory")
    }

    func testATapOutageIsWrittenAsSilenceEvenWhenItIsLongerThanTheRing() throws {
        let (drain, chunk) = makeDrain(keepsAudio: true)
        let sinks = Sinks()
        let silence = UnsafeMutablePointer<Float>.allocate(capacity: 16_384)
        silence.initialize(repeating: 0, count: 16_384)
        allocations.append(silence)
        let next = produce(drain.ring, seconds: 1)

        SystemAudioTap.enqueueSilence(frames: frames(12), into: drain.ring, from: silence, chunk: 16_384)
        _ = produce(drain.ring, seconds: 0.1, startingAt: next)
        _ = try drainAll(drain, persisting: true, into: sinks, chunk: chunk)

        XCTAssertEqual(sinks.persisted.count, frames(13.1), "desktop.caf would drift against mic.caf")
        XCTAssertEqual(sinks.persisted[frames(1) - 1], Float(frames(1)))
        XCTAssertTrue(sinks.persisted[frames(1)...].allSatisfy { $0 == 0 })
    }

    func testMicSilenceFillsTheGapInTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mic-gap-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        var written: AVAudioFramePosition = 0
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            written = try MicCapture.writeSilence(seconds: 1.5, to: file, format: format)
        }
        XCTAssertEqual(written, 72_000)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 72_000)
    }

    func testMicHostTimeConversionRoundTrips() {
        let ticks = MicCapture.hostTime(fromSeconds: 2.5)
        XCTAssertEqual(MicCapture.seconds(fromHostTime: ticks), 2.5, accuracy: 0.000_001)
    }
}
