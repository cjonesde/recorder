import XCTest
import AVFoundation
import CoreAudio
import os
@testable import Recorder

/// Verifies the mic survives an input route change mid-recording, which is what a
/// Bluetooth headset renegotiating (or a device being switched) does to the engine.
///
/// Two failure modes are checked, both of which existed before:
///  - the graph is torn down and buffers stop arriving, leaving a silently dead mic
///  - the new hardware rate differs, so the file header and the rate handed to
///    `onSamples` describe audio that no longer arrives at that rate
///
/// This one temporarily changes the system's default input device, so it is opt-in
/// separately from the other live checks:
///
///     RECORDER_LIVE_ROUTE=1 swift test --filter MicRouteChangeTests
final class MicRouteChangeTests: XCTestCase {

    func testMicKeepsRecordingAtOneRateAcrossAnInputRouteChange() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RECORDER_LIVE_ROUTE"] == "1",
            "set RECORDER_LIVE_ROUTE=1 to run the route-change check (it switches the default input device)"
        )

        let original = try XCTUnwrap(Self.defaultInputDevice(), "no default input device")
        let originalRate = Self.nominalSampleRate(original) ?? 0

        // Prefer a device whose rate differs, so the resampling path is exercised.
        let candidates = Self.inputDevices().filter { $0 != original }
        try XCTSkipIf(candidates.isEmpty, "need a second input device to switch to")
        let target = candidates.first(where: { Self.nominalSampleRate($0) != originalRate }) ?? candidates[0]
        let targetRate = Self.nominalSampleRate(target) ?? 0

        print("route change: device \(original) @ \(originalRate) Hz -> \(target) @ \(targetRate) Hz")

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("liveroute-\(UUID().uuidString).caf")
        defer {
            try? FileManager.default.removeItem(at: url)
            Self.setDefaultInputDevice(original)
        }

        let mic = MicCapture()
        let reported = OSAllocatedUnfairLock<[Double: Int]>(initialState: [:])
        mic.onSamples = { _, count, rate in
            reported.withLock { $0[rate, default: 0] += count }
        }
        var fatal: Error?
        mic.onFatalError = { fatal = $0 }

        try mic.start(writingTo: url)
        Thread.sleep(forTimeInterval: 3.0)

        let beforeSwitch = reported.withLock { $0.values.reduce(0, +) }
        XCTAssertGreaterThan(beforeSwitch, 0, "no audio before the route change")

        Self.setDefaultInputDevice(target)
        // Give the engine time to post the notification and be rebuilt.
        Thread.sleep(forTimeInterval: 5.0)

        let result = mic.stop()
        if let fatal { throw fatal }

        let afterSwitch = reported.withLock { $0.values.reduce(0, +) } - beforeSwitch

        // 1. The mic must not have gone deaf.
        XCTAssertGreaterThan(
            afterSwitch, 0,
            "mic delivered nothing after the route change: the graph was not rebuilt"
        )

        // 2. Exactly one rate for the whole recording, matching the file and the
        //    CaptureResult that StereoMixer aligns with.
        let file = try AVAudioFile(forReading: url)
        let declared = file.fileFormat.sampleRate
        let rates = reported.withLock { $0 }
        XCTAssertEqual(rates.count, 1, "onSamples reported multiple rates across the switch: \(rates)")
        XCTAssertEqual(rates.keys.first, declared)
        XCTAssertEqual(result.sampleRate, declared)
        XCTAssertEqual(result.frameCount, file.length)

        print("after switch: \(afterSwitch) samples, single rate \(declared) Hz, file \(file.length) frames")
    }

    /// The Bluetooth case proper: the *same* device renegotiates to a different sample
    /// rate mid-recording. The recording must keep its original rate end to end and
    /// keep receiving audio, with the new hardware rate resampled up to it.
    func testMicKeepsOneRateWhenTheDeviceChangesItsSampleRate() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RECORDER_LIVE_ROUTE"] == "1",
            "set RECORDER_LIVE_ROUTE=1 to run the rate-change check (it changes a device's sample rate)"
        )

        let originalDefault = try XCTUnwrap(Self.defaultInputDevice(), "no default input device")

        // Find an input device that can actually change rate. A device offering both
        // 48 kHz and 16 kHz reproduces the Bluetooth voice-profile switch exactly.
        let multiRate = Self.inputDevices()
            .map { ($0, Self.availableSampleRates($0)) }
            .filter { $0.1.count >= 2 }
        guard let (device, available) = multiRate.first(where: { $0.1.contains(48_000) && $0.1.contains(16_000) })
            ?? multiRate.first
        else {
            throw XCTSkip("no input device supports more than one sample rate")
        }

        let startRate = available.contains(48_000) ? 48_000 : available.max()!
        let otherRate = available.filter { abs($0 - startRate) > 1 }.min()!
        let originalRate = Self.nominalSampleRate(device) ?? startRate

        print("rate change: device \(device) \(startRate) Hz -> \(otherRate) Hz (available: \(available))")

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("liverate-\(UUID().uuidString).caf")
        defer {
            try? FileManager.default.removeItem(at: url)
            Self.setNominalSampleRate(device, originalRate)
            Self.setDefaultInputDevice(originalDefault)
        }

        // Route recording at this device, pinned to `startRate` before we begin.
        XCTAssertTrue(Self.setDefaultInputDevice(device), "could not make device \(device) the default input")
        XCTAssertTrue(Self.setNominalSampleRate(device, startRate), "could not set \(startRate) Hz")
        Thread.sleep(forTimeInterval: 1.0)

        let mic = MicCapture()
        let reported = OSAllocatedUnfairLock<[Double: Int]>(initialState: [:])
        mic.onSamples = { _, count, rate in
            reported.withLock { $0[rate, default: 0] += count }
        }
        var fatal: Error?
        mic.onFatalError = { fatal = $0 }

        try mic.start(writingTo: url)
        Thread.sleep(forTimeInterval: 3.0)

        let beforeSwitch = reported.withLock { $0.values.reduce(0, +) }
        XCTAssertGreaterThan(beforeSwitch, 0, "no audio before the rate change")

        XCTAssertTrue(Self.setNominalSampleRate(device, otherRate), "could not set \(otherRate) Hz")
        Thread.sleep(forTimeInterval: 5.0)

        let result = mic.stop()
        if let fatal { throw fatal }

        let afterSwitch = reported.withLock { $0.values.reduce(0, +) } - beforeSwitch
        XCTAssertGreaterThan(
            afterSwitch, 0,
            "mic delivered nothing after the device changed rate"
        )

        let file = try AVAudioFile(forReading: url)
        let declared = file.fileFormat.sampleRate
        let rates = reported.withLock { $0 }

        // The whole point: one rate for the recording, and it is the rate we started at.
        XCTAssertEqual(declared, startRate, "the file's rate changed mid-recording")
        XCTAssertEqual(rates.count, 1, "onSamples reported multiple rates: \(rates)")
        XCTAssertEqual(rates.keys.first, declared)
        XCTAssertEqual(result.sampleRate, declared)
        XCTAssertEqual(result.frameCount, file.length)

        print("after rate change: \(afterSwitch) samples, single rate \(declared) Hz, file \(file.length) frames")
    }

    // MARK: - CoreAudio device helpers

    private static func availableSampleRates(_ device: AudioObjectID) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: count)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ranges) == noErr else {
            return []
        }
        // Discrete devices report min == max per supported rate.
        return ranges.map { $0.mMinimum }
    }

    @discardableResult
    private static func setNominalSampleRate(_ device: AudioObjectID, _ rate: Double) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = rate
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value
        ) == noErr
    }

    private static func defaultInputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    @discardableResult
    private static func setDefaultInputDevice(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = device
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &value
        )
        return status == noErr
    }

    private static func inputDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.filter { hasInputChannels($0) }
    }

    private static func hasInputChannels(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else {
            return false
        }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return status == noErr ? rate : nil
    }
}
