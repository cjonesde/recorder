import XCTest
@testable import Recorder

final class FakeMetrics: SystemMetricsSource, @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [MetricsReading]
    private(set) var includeSpeechServiceRequests: [Bool] = []

    init(_ readings: [MetricsReading]) {
        self.readings = readings
    }

    func read(includeSpeechService: Bool) -> MetricsReading {
        lock.withLock {
            includeSpeechServiceRequests.append(includeSpeechService)
            return readings.count > 1 ? readings.removeFirst() : readings[0]
        }
    }
}

func reading(footprint: UInt64 = 500, speech: UInt64? = nil, swap: UInt64 = 0, swapIns: UInt64 = 0, swapOuts: UInt64 = 0) -> MetricsReading {
    MetricsReading(
        footprintBytes: footprint,
        speechServiceFootprintBytes: speech,
        pressure: .normal,
        swapUsedBytes: swap,
        swapIns: swapIns,
        swapOuts: swapOuts
    )
}

func diag(submitted: Double = 0, provisional: Double? = nil, final: Double? = nil, held: Double? = nil) -> EngineDiagnostics {
    EngineDiagnostics(
        submittedThroughSeconds: submitted,
        latestProvisionalEnd: provisional,
        latestFinalEnd: final,
        heldAudioSeconds: held,
        heldAudioQuality: held == nil ? .unknown : .measured,
        rows: []
    )
}

@MainActor
final class DiagnosticsRecorderTests: XCTestCase {
    private func tempFolder(files: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testBaselineIsTakenAtRecordPressAndPhasesAreTagged() {
        let metrics = FakeMetrics([reading(swap: 1_000), reading(swap: 1_000), reading(swap: 5_000)])
        var clock = 0.0
        let rec = DiagnosticsRecorder(source: metrics, now: { clock }, engine: .parakeet, settings: [:])
        clock = 1; rec.sample(engine: diag(), stall: 0, folder: nil)
        rec.setPhase(.recording)
        clock = 2; rec.sample(engine: diag(), stall: 0, folder: nil)
        XCTAssertEqual(rec.samples.map(\.phase), [.preparing, .recording])
        XCTAssertEqual(rec.samples.last?.swapGrowthBytes, 4_000)
    }

    func testSwapCountersAreRelativeToRecordPress() {
        let metrics = FakeMetrics([reading(swap: 5_000, swapIns: 10, swapOuts: 20), reading(swap: 3_000, swapIns: 13, swapOuts: 27)])
        var clock = 0.0
        let rec = DiagnosticsRecorder(source: metrics, now: { clock }, engine: .nemotron, settings: [:])
        clock = 1; rec.sample(engine: diag(), stall: 0.25, folder: nil)
        XCTAssertEqual(rec.samples[0].swapGrowthBytes, -2_000)
        XCTAssertEqual(rec.samples[0].swapInsSinceStart, 3)
        XCTAssertEqual(rec.samples[0].swapOutsSinceStart, 7)
        XCTAssertEqual(rec.samples[0].longestMainThreadStall, 0.25)
        XCTAssertEqual(rec.samples[0].t, 1)
    }

    func testTextBehindUsesSubmittedPositionMinusResultEnds() {
        let rec = DiagnosticsRecorder(source: FakeMetrics([reading()]), now: { 0 }, engine: .apple, settings: [:])
        rec.sample(engine: diag(submitted: 30, provisional: 28.2, final: 19), stall: 0, folder: nil)
        XCTAssertEqual(rec.samples[0].textBehindRough!, 1.8, accuracy: 0.001)
        XCTAssertEqual(rec.samples[0].textBehindFinal!, 11, accuracy: 0.001)
    }

    func testTextBehindIsUnknownWithoutResults() {
        let rec = DiagnosticsRecorder(source: FakeMetrics([reading()]), now: { 0 }, engine: .apple, settings: [:])
        rec.sample(engine: diag(submitted: 30, held: 0.4), stall: 0, folder: nil)
        XCTAssertNil(rec.samples[0].textBehindRough)
        XCTAssertNil(rec.samples[0].textBehindFinal)
        XCTAssertEqual(rec.samples[0].heldAudioSeconds, 0.4)
        XCTAssertEqual(rec.samples[0].heldAudioQuality, .measured)
    }

    func testUnreadableSpeechServiceStaysUnknownNotRecorderMemory() {
        let rec = DiagnosticsRecorder(source: FakeMetrics([reading(footprint: 600, speech: nil)]), now: { 0 }, engine: .apple, settings: [:])
        rec.sample(engine: diag(), stall: 0, folder: nil)
        XCTAssertNil(rec.samples[0].reading.speechServiceFootprintBytes)
    }

    func testSpeechServiceIsOnlyAskedForWithApple() {
        let apple = FakeMetrics([reading()])
        DiagnosticsRecorder(source: apple, now: { 0 }, engine: .apple, settings: [:]).sample(engine: diag(), stall: 0, folder: nil)
        let parakeet = FakeMetrics([reading()])
        DiagnosticsRecorder(source: parakeet, now: { 0 }, engine: .parakeet, settings: [:]).sample(engine: diag(), stall: 0, folder: nil)
        XCTAssertEqual(apple.includeSpeechServiceRequests, [true, true])
        XCTAssertEqual(parakeet.includeSpeechServiceRequests, [false, false])
    }

    func testAudioFilesIgnoreTranscriptAndDebugFiles() throws {
        let folder = try tempFolder(files: ["transcript.md", "transcript.json", "debug.json", "mic.caf"])
        let rec = DiagnosticsRecorder(source: FakeMetrics([reading()]), now: { 0 }, engine: .apple, settings: [:])
        rec.sample(engine: diag(), stall: 0, folder: folder)
        XCTAssertEqual(rec.samples[0].audioFilesOnDisk, ["mic.caf"])
    }

    func testEventsCarryTimeAndPhase() {
        var clock = 10.0
        let rec = DiagnosticsRecorder(source: FakeMetrics([reading()]), now: { clock }, engine: .apple, settings: ["language": "en-US"])
        rec.record("record pressed", detail: nil)
        clock = 12.5
        rec.setPhase(.recording)
        rec.record("capture started", detail: "stall 0.1 s")
        XCTAssertEqual(rec.events, [
            DebugEvent(t: 0, phase: .preparing, kind: "record pressed", detail: nil),
            DebugEvent(t: 2.5, phase: .recording, kind: "capture started", detail: "stall 0.1 s"),
        ])
        XCTAssertEqual(rec.engine, .apple)
        XCTAssertEqual(rec.settings, ["language": "en-US"])
    }

    func testPreparationAndStopsAreKept() {
        let rec = DiagnosticsRecorder(source: FakeMetrics([reading()]), now: { 0 }, engine: .nemotron, settings: [:])
        let info = PreparationInfo(loadSeconds: 2, firstLoad: true, modelBytesOnDisk: 10, computeUnits: "ANE")
        rec.setPreparation(info)
        rec.recordStop(.desktopRingOverflow)
        XCTAssertEqual(rec.preparation, info)
        XCTAssertEqual(rec.stops, [.desktopRingOverflow])
        XCTAssertEqual(rec.events.last?.kind, "safety stop")
        XCTAssertEqual(rec.events.last?.detail, LiveStopReason.desktopRingOverflow.rawValue)
    }

    func testRecordStopIgnoresTheSameReasonTwice() {
        let rec = DiagnosticsRecorder(source: FakeMetrics([reading()]), now: { 0 }, engine: .apple, settings: [:])
        rec.recordStop(.engineFellBehind)
        rec.recordStop(.engineFellBehind)
        XCTAssertEqual(rec.stops, [.engineFellBehind])
    }

    func testFirstTextAndFirstFinalAreRecordedOnceRelativeToCaptureStart() {
        var clock = 0.0
        let rec = DiagnosticsRecorder(source: FakeMetrics([reading()]), now: { clock }, engine: .apple, settings: [:])
        clock = 2
        rec.captureStarted(stall: 0.05)
        clock = 3
        rec.noteText(hypothesis: "", finalLines: 0)
        clock = 3.5
        rec.noteText(hypothesis: "hello", finalLines: 0)
        clock = 4
        rec.noteText(hypothesis: "hello there", finalLines: 0)
        clock = 6
        rec.noteText(hypothesis: "", finalLines: 1)
        rec.noteText(hypothesis: "", finalLines: 2)
        XCTAssertEqual(rec.events.map(\.kind), ["capture started", "first text", "first final text"])
        XCTAssertEqual(rec.events[0].detail, "longest main-thread stall 0.050 s")
        XCTAssertEqual(rec.events[1].detail, "1.50 s after capture start")
        XCTAssertEqual(rec.events[2].detail, "4.00 s after capture start")
        XCTAssertTrue(rec.hasSeenFirstFinalText)
    }
}

@MainActor
final class DiagnosticsWiringTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "liveEngine")
        UserDefaults.standard.removeObject(forKey: "showDebugInfo")
        super.tearDown()
    }

    private func waitWhilePreparing(_ model: RecorderModel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.state == .preparing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testNothingIsSampledWhenDebugIsOff() async throws {
        let model = RecorderModel(engineFactory: { FakeLiveEngine(kind: $0, prepareError: URLError(.notConnectedToInternet)) })
        model.showDebugInfo = false
        model.startRecording(meeting: nil)
        XCTAssertNil(model.diagnostics)
        XCTAssertFalse(model.isSamplingDiagnostics)
        try await waitWhilePreparing(model)
        XCTAssertNil(model.diagnostics)
    }

    func testRecordPressCreatesTheRecorderAndAFailedPreparationStopsSampling() async throws {
        let model = RecorderModel(engineFactory: { FakeLiveEngine(kind: $0, prepareError: URLError(.notConnectedToInternet)) })
        model.liveEngine = .nemotron
        model.showDebugInfo = true
        model.startRecording(meeting: nil)
        let diagnostics = try XCTUnwrap(model.diagnostics)
        XCTAssertTrue(model.isSamplingDiagnostics)
        XCTAssertEqual(diagnostics.engine, .nemotron)
        XCTAssertEqual(diagnostics.phase, .preparing)
        try await waitWhilePreparing(model)
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.isSamplingDiagnostics)
        XCTAssertEqual(diagnostics.events.map(\.kind), ["record pressed", "preparation started", "preparation failed"])
    }

    func testTrashDuringPreparationStopsSampling() async throws {
        let model = RecorderModel(engineFactory: { FakeLiveEngine(kind: $0, prepareDelay: .milliseconds(300)) })
        model.showDebugInfo = true
        model.startRecording(meeting: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.isSamplingDiagnostics)
        model.trashAndStop()
        XCTAssertFalse(model.isSamplingDiagnostics)
        XCTAssertEqual(model.diagnostics?.events.last?.kind, "discarded")
    }

    func testSwitchingDebugOffDropsTheRecorder() async throws {
        let model = RecorderModel(engineFactory: { FakeLiveEngine(kind: $0, prepareDelay: .milliseconds(300)) })
        model.showDebugInfo = true
        model.startRecording(meeting: nil)
        XCTAssertNotNil(model.diagnostics)
        model.showDebugInfo = false
        XCTAssertNil(model.diagnostics)
        XCTAssertFalse(model.isSamplingDiagnostics)
        model.trashAndStop()
    }
}
