import XCTest
import AVFoundation
import os
@testable import Recorder

/// Drives the real Core Audio process tap and checks the invariant that the
/// garbled-transcript bug broke: the samples a recording produces per second of
/// wall clock must match the rate it declares, both in the CAF header and in the
/// rate handed to `onSamples`.
///
/// Needs "Screen & System Audio Recording" permission for the test runner and a
/// live audio device, so it is opt-in:
///
///     RECORDER_LIVE_TAP=1 swift test --filter LiveTapVerificationTests
///
/// The desktop tap only delivers buffers while the output device is actually playing,
/// so play continuous audio for the duration or the tap tests see silence and report
/// zero samples. A tone long enough to cover the whole run is the simplest way.
final class LiveTapVerificationTests: XCTestCase {

    func testDeclaredRateMatchesProducedSamplesPerWallSecond() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RECORDER_LIVE_TAP"] == "1",
            "set RECORDER_LIVE_TAP=1 to run the live tap check"
        )

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("livetap-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let tap = SystemAudioTap()

        // Every rate the writer thread reports alongside samples.
        let reported = OSAllocatedUnfairLock<[Double: Int]>(initialState: [:])
        tap.onSamples = { _, count, rate in
            reported.withLock { $0[rate, default: 0] += count }
        }

        var fatal: Error?
        tap.onFatalError = { fatal = $0 }

        try tap.start(writingTo: url)
        Thread.sleep(forTimeInterval: 8.0)
        let stoppedAtHostTime = mach_absolute_time()
        let result = tap.stop()

        if let fatal { throw fatal }

        // Measure the capture window from the tap's own first sample, so building the
        // aggregate device and draining the ring don't count against throughput.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let firstHostTime = try XCTUnwrap(result.firstHostTime, "tap never recorded a first sample")
        let nanos = Double(stoppedAtHostTime - firstHostTime)
            * Double(timebase.numer) / Double(timebase.denom)
        let elapsed = nanos / 1_000_000_000

        // 1. The file header must describe the samples actually in it.
        let file = try AVAudioFile(forReading: url)
        let declared = file.fileFormat.sampleRate
        let frames = file.length
        let measured = Double(frames) / elapsed

        XCTAssertGreaterThan(frames, 0, "tap produced no audio")
        XCTAssertEqual(
            measured / declared, 1.0, accuracy: 0.05,
            "file declares \(declared) Hz but holds \(measured) samples/sec"
        )

        // 2. The rate reported to the transcription inbox must be that same rate,
        //    and there must be exactly one of them for the whole recording.
        let rates = reported.withLock { $0 }
        XCTAssertEqual(rates.count, 1, "onSamples reported multiple rates: \(rates)")
        if let onlyRate = rates.keys.first {
            XCTAssertEqual(onlyRate, declared, "onSamples said \(onlyRate), file says \(declared)")
            let streamed = Double(rates[onlyRate]!) / elapsed
            XCTAssertEqual(
                streamed / declared, 1.0, accuracy: 0.05,
                "onSamples streamed \(streamed) samples/sec at a declared \(declared) Hz"
            )
        }

        // 3. CaptureResult must agree, since StereoMixer aligns channels with it.
        XCTAssertEqual(result.sampleRate, declared)
        XCTAssertEqual(result.frameCount, frames)
    }

    func testMicDeclaredRateMatchesProducedSamplesPerWallSecond() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RECORDER_LIVE_TAP"] == "1",
            "set RECORDER_LIVE_TAP=1 to run the live mic check"
        )

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("livemic-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let mic = MicCapture()
        let reported = OSAllocatedUnfairLock<[Double: Int]>(initialState: [:])
        mic.onSamples = { _, count, rate in
            reported.withLock { $0[rate, default: 0] += count }
        }
        var fatal: Error?
        mic.onFatalError = { fatal = $0 }

        try mic.start(writingTo: url)
        Thread.sleep(forTimeInterval: 6.0)
        let stoppedAtHostTime = mach_absolute_time()
        let result = mic.stop()

        if let fatal { throw fatal }

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let firstHostTime = try XCTUnwrap(result.firstHostTime, "mic never recorded a first sample")
        let elapsed = Double(stoppedAtHostTime - firstHostTime)
            * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000

        let file = try AVAudioFile(forReading: url)
        let declared = file.fileFormat.sampleRate
        XCTAssertGreaterThan(file.length, 0, "mic produced no audio")
        XCTAssertEqual(
            (Double(file.length) / elapsed) / declared, 1.0, accuracy: 0.05,
            "mic file declares \(declared) Hz but holds \(Double(file.length) / elapsed) samples/sec"
        )

        // The canonical rate must be the only rate the inbox ever hears, whatever the
        // hardware did in between.
        let rates = reported.withLock { $0 }
        XCTAssertEqual(rates.count, 1, "onSamples reported multiple rates: \(rates)")
        XCTAssertEqual(rates.keys.first, declared)
        XCTAssertEqual(result.sampleRate, declared)
    }

    func testNilDestinationWritesNoFileButStillStreamsSamples() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RECORDER_LIVE_TAP"] == "1",
            "set RECORDER_LIVE_TAP=1 to run the no-retention check"
        )

        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noretain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let mic = MicCapture()
        let streamed = OSAllocatedUnfairLock<Int>(initialState: 0)
        mic.onSamples = { _, count, _ in
            streamed.withLock { $0 += count }
        }

        try mic.start(writingTo: nil)
        Thread.sleep(forTimeInterval: 3.0)
        let result = mic.stop()

        XCTAssertGreaterThan(streamed.withLock { $0 }, 0, "no samples reached the inbox")
        XCTAssertGreaterThan(result.frameCount, 0, "frames were not counted")

        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(contents.isEmpty, "transcript-only mode wrote \(contents)")
    }

    func testTapWithNilDestinationWritesNoFileButStillStreamsSamples() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RECORDER_LIVE_TAP"] == "1",
            "set RECORDER_LIVE_TAP=1 to run the no-retention check"
        )

        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noretaintap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let tap = SystemAudioTap()
        let streamed = OSAllocatedUnfairLock<Int>(initialState: 0)
        tap.onSamples = { _, count, _ in
            streamed.withLock { $0 += count }
        }

        try tap.start(writingTo: nil)
        Thread.sleep(forTimeInterval: 4.0)
        let result = tap.stop()

        XCTAssertGreaterThan(streamed.withLock { $0 }, 0, "no samples reached the inbox")
        XCTAssertGreaterThan(result.frameCount, 0, "frames were not counted")

        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(contents.isEmpty, "transcript-only mode wrote \(contents)")
    }
}
