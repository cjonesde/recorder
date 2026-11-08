import XCTest
@testable import Recorder

@MainActor
class FakeLiveEngine: LiveSpeechEngine {
    let kind: LiveEngineKind
    var displayName: String { "Fake \(kind.label)" }
    private(set) var isLoaded = false
    var finalizationTimeout: Duration = .seconds(10)
    var confirmedLines: [TranscriptLine] = []
    var hypothesis = ""
    var revision = 0
    private(set) var isSessionActive = false
    var failureMessage: String?
    var stopReason: LiveStopReason?
    var labelSpeakers = true
    var onFailure: (() -> Void)?
    nonisolated let inbox = StreamingAudioInput()

    let prepareError: Error?
    let prepareDelay: Duration?
    let startSessionError: Error?
    let unloadDelay: Duration?
    private(set) var prepareCalls = 0
    private(set) var startSessionCalls = 0
    private(set) var unloadCalls = 0
    private(set) var capturedErrors: [Error] = []

    init(kind: LiveEngineKind, prepareError: Error? = nil, prepareDelay: Duration? = nil,
         startSessionError: Error? = nil, unloadDelay: Duration? = nil) {
        self.kind = kind
        self.prepareError = prepareError
        self.prepareDelay = prepareDelay
        self.startSessionError = startSessionError
        self.unloadDelay = unloadDelay
    }

    func prepare(language: String, progress: @escaping @Sendable (Double?) -> Void) async throws -> PreparationInfo {
        prepareCalls += 1
        if let prepareDelay { try await Task.sleep(for: prepareDelay) }
        if let prepareError { throw prepareError }
        let firstLoad = !isLoaded
        isLoaded = true
        return PreparationInfo(loadSeconds: 0, firstLoad: firstLoad, modelBytesOnDisk: nil, computeUnits: "fake")
    }

    func startSession() throws {
        startSessionCalls += 1
        if let startSessionError { throw startSessionError }
        isSessionActive = true
    }

    func endSession() async -> LiveSessionResult {
        isSessionActive = false
        return LiveSessionResult(lines: confirmedLines, complete: failureMessage == nil, stopReason: stopReason)
    }

    func cancelSession() {
        isSessionActive = false
        failureMessage = nil
        stopReason = nil
    }

    func captureFailed(_ error: Error) {
        capturedErrors.append(error)
        let stop = error as? LiveStopError ?? LiveStopError(reason: .engineError, detail: error.localizedDescription)
        failureMessage = stop.localizedDescription
        stopReason = stop.reason
        onFailure?()
    }

    func diagnostics() -> EngineDiagnostics {
        EngineDiagnostics(submittedThroughSeconds: 0, latestProvisionalEnd: nil, latestFinalEnd: nil,
                          heldAudioSeconds: nil, heldAudioQuality: .unknown, rows: [])
    }

    func unload() async {
        unloadCalls += 1
        if let unloadDelay { try? await Task.sleep(for: unloadDelay) }
        isLoaded = false
    }
}

@MainActor
final class FakeEngineLog {
    var made: [FakeLiveEngine] = []
}

final class LiveEngineSelectionTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "liveEngine")
        super.tearDown()
    }

    @MainActor
    func testSelectingAnotherEngineUnloadsThePreviousOne() async {
        let engine = LocalTranscriptionEngine(factory: { kind in FakeLiveEngine(kind: kind) })
        await engine.select(.nemotron)
        let first = engine.engine as! FakeLiveEngine
        await engine.select(.parakeet)
        XCTAssertEqual(first.unloadCalls, 1)
        XCTAssertEqual(engine.engine.kind, .parakeet)
    }

    @MainActor
    func testReselectingTheSameEngineKeepsItLoaded() async {
        let engine = LocalTranscriptionEngine(factory: { FakeLiveEngine(kind: $0) })
        await engine.select(.nemotron)
        let first = engine.engine as! FakeLiveEngine
        await engine.select(.nemotron)
        XCTAssertTrue(engine.engine === first)
        XCTAssertEqual(first.unloadCalls, 0)
    }

    @MainActor
    func testPreparationFailureLeavesAppIdleWithoutCapture() async throws {
        let model = RecorderModel(engineFactory: { FakeLiveEngine(kind: $0, prepareError: URLError(.notConnectedToInternet)) })
        model.liveEngine = .parakeet
        model.startRecording(meeting: nil)
        while model.state == .preparing { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.currentSession)
        XCTAssertTrue(model.statusMessage?.contains("Parakeet") == true)
    }

    @MainActor
    func testCancelDuringLongPreparationNeverStartsCaptureAndNextRecordWorks() async throws {
        let model = RecorderModel(engineFactory: { kind in
            kind == .apple
                ? FakeLiveEngine(kind: kind, prepareDelay: .milliseconds(300))
                : FakeLiveEngine(kind: kind, startSessionError: URLError(.cancelled))
        })
        model.liveEngine = .apple
        model.startRecording(meeting: nil)
        try await Task.sleep(for: .milliseconds(100))
        let first = model.live.engine as! FakeLiveEngine
        XCTAssertEqual(first.prepareCalls, 1)
        model.trashAndStop()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.currentSession)
        XCTAssertEqual(first.startSessionCalls, 0)

        model.liveEngine = .nemotron
        model.startRecording(meeting: nil)
        let deadline = ContinuousClock.now + .seconds(5)
        while model.state == .preparing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let second = try XCTUnwrap(model.live.engine as? FakeLiveEngine)
        XCTAssertEqual(second.kind, .nemotron)
        XCTAssertEqual(second.prepareCalls, 1)
        XCTAssertEqual(second.startSessionCalls, 1)
        XCTAssertEqual(first.startSessionCalls, 0)
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.currentSession)
    }

    @MainActor
    func testOverlappingSelectionsLeaveOneEngineOfTheLastKind() async {
        let log = FakeEngineLog()
        let engine = LocalTranscriptionEngine(factory: { kind in
            let made = FakeLiveEngine(kind: kind, unloadDelay: .milliseconds(100))
            log.made.append(made)
            return made
        })
        let first = Task { await engine.select(.nemotron) }
        await Task.yield()
        let second = Task { await engine.select(.parakeet) }
        await first.value
        await second.value
        XCTAssertEqual(engine.engine.kind, .parakeet)
        XCTAssertEqual(log.made.map(\.kind), [.apple, .nemotron, .parakeet])
        XCTAssertEqual(log.made.map(\.unloadCalls), [1, 1, 0])
        XCTAssertTrue(engine.engine === log.made.last)
        XCTAssertTrue(engine.router.current === log.made.last?.inbox)
    }

    @MainActor
    func testBeginSessionPreparesThenStartsAndRecordsPreparation() async throws {
        let engine = LocalTranscriptionEngine(factory: { FakeLiveEngine(kind: $0) })
        try await engine.beginSession(language: "en-US")
        let fake = engine.engine as! FakeLiveEngine
        XCTAssertEqual(fake.prepareCalls, 1)
        XCTAssertEqual(fake.startSessionCalls, 1)
        XCTAssertEqual(engine.lastPreparation?.firstLoad, true)
    }

    @MainActor
    func testRouterFollowsTheSelectedEngine() async {
        let engine = LocalTranscriptionEngine(factory: { FakeLiveEngine(kind: $0) })
        await engine.select(.parakeet)
        XCTAssertTrue(engine.router.current === engine.engine.inbox)
    }

    @MainActor
    func testFailureCallbackAndSpeakerLabelsSurviveReselection() async {
        let engine = LocalTranscriptionEngine(factory: { FakeLiveEngine(kind: $0) })
        var failures = 0
        engine.onFailure = { failures += 1 }
        engine.labelSpeakers = false
        await engine.select(.nemotron)
        XCTAssertFalse(engine.engine.labelSpeakers)
        engine.engine.captureFailed(LiveStopError(reason: .desktopRingOverflow, detail: nil))
        XCTAssertEqual(failures, 1)
    }

    @MainActor
    func testAppleCaptureFailureKeepsTheRingOverflowReason() {
        let apple = AppleLiveTranscriber()
        apple.captureFailed(LiveStopError(reason: .desktopRingOverflow, detail: nil))
        XCTAssertEqual(apple.stopReason, .desktopRingOverflow)
    }

    @MainActor
    func testAppleNamesItselfAndUsesTheTenSecondWatchdog() {
        let apple = AppleLiveTranscriber()
        XCTAssertEqual(apple.kind, .apple)
        XCTAssertEqual(apple.finalizationTimeout, .seconds(10))
        XCTAssertTrue(apple.displayName.hasPrefix("Apple SpeechTranscriber ("))
        let diagnostics = apple.diagnostics()
        XCTAssertEqual(diagnostics.heldAudioQuality, .measured)
        XCTAssertTrue(diagnostics.rows.contains(DiagnosticRow(label: "Inside Apple", value: "unknown", quality: .unknown)))
    }

    @MainActor
    func testNemotronNamesItselfAndEstimatesHeldAudioWithoutLoading() {
        let engine = LocalTranscriptionEngine.defaultFactory(.nemotron)
        XCTAssertTrue(engine is NemotronLiveEngine)
        XCTAssertEqual(engine.kind, .nemotron)
        XCTAssertEqual(engine.displayName, "Nemotron 3.5 streaming")
        XCTAssertEqual(engine.finalizationTimeout, .seconds(30))
        XCTAssertFalse(engine.isLoaded)
        XCTAssertThrowsError(try engine.startSession())
        let diagnostics = engine.diagnostics()
        XCTAssertEqual(diagnostics.heldAudioQuality, .estimated)
        XCTAssertEqual(diagnostics.heldAudioSeconds, 0)
        XCTAssertTrue(diagnostics.rows.contains(DiagnosticRow(label: "Recovery replay", value: "not observable", quality: .unknown)))
        XCTAssertTrue(diagnostics.rows.contains { $0.label == "Handoff peak" && $0.quality == .measured })
        engine.captureFailed(LiveStopError(reason: .desktopRingOverflow, detail: nil))
        XCTAssertEqual(engine.stopReason, .desktopRingOverflow)
    }

    @MainActor
    func testNemotronModelsLiveUnderRecorderSpeechModels() {
        let variant = NemotronLiveEngine.variantDirectory(language: "de-DE")
        XCTAssertTrue(variant.path.hasSuffix("Application Support/Recorder/SpeechModels/nemotron-multilingual/latin/560ms"), variant.path)
    }

    @MainActor
    func testParakeetNamesItselfAndEstimatesHeldAudioWithoutLoading() {
        let engine = LocalTranscriptionEngine.defaultFactory(.parakeet)
        XCTAssertTrue(engine is ParakeetLiveEngine)
        XCTAssertEqual(engine.kind, .parakeet)
        XCTAssertEqual(engine.displayName, "Parakeet Ultra")
        XCTAssertEqual(engine.finalizationTimeout, .seconds(30))
        XCTAssertFalse(engine.isLoaded)
        XCTAssertThrowsError(try engine.startSession())
        let diagnostics = engine.diagnostics()
        XCTAssertEqual(diagnostics.heldAudioQuality, .estimated)
        XCTAssertEqual(diagnostics.heldAudioSeconds, 0)
        XCTAssertTrue(diagnostics.rows.contains(DiagnosticRow(label: "Window", value: "11 s + 2 s + 2 s", quality: .measured)))
        XCTAssertTrue(diagnostics.rows.contains { $0.label == "Last window decode" })
        XCTAssertTrue(diagnostics.rows.contains { $0.label == "Handoff peak" && $0.quality == .measured })
        engine.captureFailed(LiveStopError(reason: .desktopRingOverflow, detail: nil))
        XCTAssertEqual(engine.stopReason, .desktopRingOverflow)
    }

    @MainActor
    func testParakeetModelsLiveUnderRecorderSpeechModels() {
        XCTAssertTrue(ParakeetLiveEngine.modelDirectory.path.hasSuffix("Application Support/Recorder/SpeechModels/parakeet-ultra"),
                      ParakeetLiveEngine.modelDirectory.path)
    }

    func testParakeetFeedGateHoldsBackOnlyWhileAWindowDecodes() {
        let gate = ParakeetFeedGate()
        XCTAssertEqual(gate.queuedSeconds, 0)
        gate.add(Int(15 * ParakeetLiveEngine.sampleRate), at: Date())
        XCTAssertEqual(gate.queuedSeconds, 2, accuracy: 1e-9)
        XCTAssertTrue(gate.hasRoom)
        gate.add(Int(1 * ParakeetLiveEngine.sampleRate), at: Date())
        XCTAssertFalse(gate.hasRoom)
        gate.windowCompleted(at: Date())
        XCTAssertEqual(gate.queuedSeconds, 0)
        XCTAssertTrue(gate.hasRoom)
        XCTAssertNotNil(gate.lastDecode)
    }

    func testFinalizationTimeoutMessageDoesNotNameAFixedWait() {
        XCTAssertFalse(LiveStopReason.finalizationTimedOut.message.contains("10 s"))
    }

    func testStreamingTranscriptExposesProvisionalAndFinalEnds() {
        var text = StreamingTranscript()
        XCTAssertNil(text.latestProvisionalEnd)
        text.update(text: "hello", start: 0, end: 1, final: true, speaker: nil)
        text.update(text: "wor", start: 1, end: 1.5, final: false, speaker: nil)
        XCTAssertEqual(text.finalEnd, 1)
        XCTAssertEqual(text.latestProvisionalEnd, 1.5)
    }
}
