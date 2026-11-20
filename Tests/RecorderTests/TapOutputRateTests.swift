import AVFoundation
import AudioToolbox
import CoreAudio
import XCTest
import os
@testable import Recorder

final class TapOutputRateTests: XCTestCase {

    func testDeclaredRateMatchesDeliveryWhenOutputStartsBelowTheMixRate() throws {
        let device = try Self.loopbackDevice()
        let originalRate = Self.nominalSampleRate(device)
        defer { Self.setNominalSampleRate(device, originalRate) }
        Self.setNominalSampleRate(device, 24_000)

        let run = try Self.record(on: device, firstSeconds: 6, thenSwitchTo: nil, forSeconds: 0)
        Self.assertTruthful(run)
    }

    func testDeclaredRateHoldsWhenOutputDropsRateMidRecording() throws {
        let device = try Self.loopbackDevice()
        let originalRate = Self.nominalSampleRate(device)
        defer { Self.setNominalSampleRate(device, originalRate) }
        Self.setNominalSampleRate(device, 48_000)

        let run = try Self.record(on: device, firstSeconds: 3, thenSwitchTo: 24_000, forSeconds: 4)
        Self.assertTruthful(run)
        XCTAssertEqual(run.declared, 48_000, "the recording keeps the rate it started with")
    }

    private struct Run {
        let declared: Double
        let fileFrames: AVAudioFramePosition
        let elapsed: Double
        let reported: [Double: Int]
        let result: CaptureResult
    }

    private static func assertTruthful(_ run: Run, file: StaticString = #filePath, line: UInt = #line) {
        let measured = Double(run.fileFrames) / run.elapsed
        print("declared \(run.declared) Hz, file holds \(Int(measured)) frames/s, onSamples \(run.reported)")
        XCTAssertGreaterThan(run.fileFrames, 0, "tap produced no audio", file: file, line: line)
        XCTAssertEqual(measured / run.declared, 1.0, accuracy: 0.05,
                       "file declares \(run.declared) Hz but holds \(measured) frames/s", file: file, line: line)
        XCTAssertEqual(Array(run.reported.keys), [run.declared], "onSamples rates \(run.reported)", file: file, line: line)
        if let streamed = run.reported[run.declared] {
            XCTAssertEqual(Double(streamed) / run.elapsed / run.declared, 1.0, accuracy: 0.05,
                           "onSamples streamed \(Double(streamed) / run.elapsed) frames/s", file: file, line: line)
        }
        XCTAssertEqual(run.result.sampleRate, run.declared, file: file, line: line)
        XCTAssertEqual(run.result.frameCount, run.fileFrames, file: file, line: line)
    }

    private static func record(on device: AudioObjectID, firstSeconds: Double, thenSwitchTo rate: Double?, forSeconds: Double) throws -> Run {
        let tone = try TonePlayer(device: device)
        defer { tone.stop() }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("taprate-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let tap = SystemAudioTap(outputDevice: { device })
        let reported = OSAllocatedUnfairLock<[Double: Int]>(initialState: [:])
        tap.onSamples = { _, count, rate in reported.withLock { $0[rate, default: 0] += count } }
        var fatal: Error?
        tap.onCaptureError = { fatal = $0 }

        try tap.start(writingTo: url)
        Thread.sleep(forTimeInterval: firstSeconds)
        if let rate {
            setNominalSampleRate(device, rate)
            Thread.sleep(forTimeInterval: forSeconds)
        }
        let stoppedAt = mach_absolute_time()
        let result = tap.stop()
        if let fatal { throw fatal }

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let first = try XCTUnwrap(result.firstHostTime, "tap never recorded a first sample")
        let elapsed = Double(stoppedAt - first) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        let audio = try AVAudioFile(forReading: url)
        return Run(declared: audio.fileFormat.sampleRate, fileFrames: audio.length, elapsed: elapsed,
                   reported: reported.withLock { $0 }, result: result)
    }

    private static func loopbackDevice() throws -> AudioObjectID {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RECORDER_LIVE_ROUTE"] == "1",
                          "set RECORDER_LIVE_ROUTE=1 to run the output-rate check (it changes BlackHole's sample rate)")
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
        guard let device = devices.first(where: { name($0).hasPrefix("BlackHole") }) else {
            throw XCTSkip("needs the BlackHole loopback driver")
        }
        return device
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func name(_ device: AudioObjectID) -> String {
        var address = Self.address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return "" }
        return (name?.takeRetainedValue() as String?) ?? ""
    }

    private static func nominalSampleRate(_ device: AudioObjectID) -> Double {
        var address = Self.address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return rate
    }

    private static func setNominalSampleRate(_ device: AudioObjectID, _ rate: Double) {
        var address = Self.address(kAudioDevicePropertyNominalSampleRate)
        var value: Float64 = rate
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        let deadline = Date().addingTimeInterval(3)
        while nominalSampleRate(device) != rate && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    }
}

private final class TonePlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var phase = 0.0

    init(device: AudioObjectID) throws {
        var device = device
        let status = AudioUnitSetProperty(engine.outputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioObjectID>.size))
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let source = AVAudioSourceNode { [unowned self] _, _, frameCount, list -> OSStatus in
            for buffer in UnsafeMutableAudioBufferListPointer(list) {
                guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                var phase = self.phase
                for frame in 0..<Int(frameCount) {
                    samples[frame] = Float(sin(phase) * 0.2)
                    phase += 2 * .pi * 440 / 48_000
                }
                self.phase = phase.truncatingRemainder(dividingBy: 2 * .pi)
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            try? self?.engine.start()
        }
        try engine.start()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine.stop()
    }
}
