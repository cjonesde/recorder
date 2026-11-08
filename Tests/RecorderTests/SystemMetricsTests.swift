import XCTest
@testable import Recorder

final class SystemMetricsTests: XCTestCase {
    private func blockCurrentThread(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    func testLiveMetricsReadsNonZeroFootprintAndAValidPressure() {
        let r = LiveSystemMetrics().read(includeSpeechService: false)
        XCTAssertGreaterThan(r.footprintBytes ?? 0, 1_000_000)
        XCTAssertNotNil(r.pressure)
        XCTAssertNotNil(r.swapUsedBytes)
        XCTAssertNotNil(r.swapIns)
        XCTAssertNotNil(r.swapOuts)
        XCTAssertNil(r.speechServiceFootprintBytes)
    }

    func testPressureLevelsMapToTheKernelValues() {
        XCTAssertEqual(MemoryPressure(kernelLevel: 1), .normal)
        XCTAssertEqual(MemoryPressure(kernelLevel: 2), .warning)
        XCTAssertEqual(MemoryPressure(kernelLevel: 4), .critical)
        XCTAssertEqual(MemoryPressure(kernelLevel: 0), .normal)
        XCTAssertEqual(MemoryPressure(kernelLevel: 3), .warning)
        XCTAssertEqual(MemoryPressure(kernelLevel: 8), .critical)
    }

    func testSpeechServiceIsUnknownWhenTheProcessIsNotRunning() {
        let metrics = LiveSystemMetrics(speechServiceName: "no-such-process-\(UUID().uuidString.prefix(6))")
        XCTAssertNil(metrics.read(includeSpeechService: true).speechServiceFootprintBytes)
    }

    func testFootprintOfARunningProcessIsReadByName() {
        let own = LiveSystemMetrics(speechServiceName: ProcessInfo.processInfo.processName)
        let ownFootprint = own.read(includeSpeechService: true).speechServiceFootprintBytes
        XCTAssertNotNil(ownFootprint)
        XCTAssertGreaterThan(ownFootprint ?? 0, 1_000_000)
    }

    @MainActor
    func testHeartbeatSeesABlockedMainThread() async throws {
        let heartbeat = MainThreadHeartbeat()
        heartbeat.start()
        defer { heartbeat.stop() }
        try await Task.sleep(for: .milliseconds(150))
        heartbeat.resetLongest()
        blockCurrentThread(0.5)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThanOrEqual(heartbeat.longestStall, 0.4)
    }

    @MainActor
    func testHeartbeatResetClearsTheLongestStall() async throws {
        let heartbeat = MainThreadHeartbeat()
        heartbeat.start()
        defer { heartbeat.stop() }
        blockCurrentThread(0.3)
        try await Task.sleep(for: .milliseconds(250))
        heartbeat.resetLongest()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertLessThan(heartbeat.longestStall, 0.25)
    }

    @MainActor
    func testSpeechServiceOptInFindsTheAppleProcessDuringASession() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RECORDER_APPLE_STREAM"] == "1")
        let live = AppleLiveTranscriber()
        _ = try await live.prepare(language: "en-US", progress: { _ in })
        try live.startSession()
        try await Task.sleep(for: .seconds(1))
        let footprint = LiveSystemMetrics().read(includeSpeechService: true).speechServiceFootprintBytes
        live.cancelSession()
        XCTAssertNotNil(footprint)
        XCTAssertGreaterThan(footprint ?? 0, 1_000_000)
    }
}
