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
    private(set) var prepareCalls = 0
    private(set) var startSessionCalls = 0
    private(set) var unloadCalls = 0
    private(set) var capturedErrors: [Error] = []

    init(kind: LiveEngineKind, prepareError: Error? = nil, prepareDelay: Duration? = nil) {
        self.kind = kind
        self.prepareError = prepareError
        self.prepareDelay = prepareDelay
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
        isLoaded = false
    }
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
        let model = RecorderModel(engineFactory: { FakeLiveEngine(kind: $0, prepareDelay: .seconds(5)) })
        model.startRecording(meeting: nil)
        try await Task.sleep(for: .milliseconds(100))
        model.trashAndStop()
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.currentSession)
        XCTAssertEqual((model.live.engine as! FakeLiveEngine).startSessionCalls, 0)
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
    func testPlaceholderEnginesRefuseToPrepareWithTheirName() async {
        for kind in [LiveEngineKind.nemotron, .parakeet] {
            let engine = LocalTranscriptionEngine.defaultFactory(kind)
            XCTAssertEqual(engine.kind, kind)
            do {
                _ = try await engine.prepare(language: "en-US", progress: { _ in })
                XCTFail("\(kind) prepared")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(kind.label), error.localizedDescription)
            }
        }
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
