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
    var onPrepare: (() -> Void)?
    nonisolated let inbox = StreamingAudioInput()

    let prepareError: Error?
    let prepareDelay: Duration?
    let startSessionError: Error?
    let unloadDelay: Duration?
    let endSessionDelay: Duration?
    let endSessionStopReason: LiveStopReason?
    private(set) var prepareCalls = 0
    private(set) var startSessionCalls = 0
    private(set) var unloadCalls = 0
    private(set) var capturedErrors: [Error] = []

    init(kind: LiveEngineKind, prepareError: Error? = nil, prepareDelay: Duration? = nil,
         startSessionError: Error? = nil, unloadDelay: Duration? = nil,
         endSessionDelay: Duration? = nil, endSessionStopReason: LiveStopReason? = nil,
         lines: [TranscriptLine] = []) {
        self.kind = kind
        self.confirmedLines = lines
        self.prepareError = prepareError
        self.prepareDelay = prepareDelay
        self.startSessionError = startSessionError
        self.unloadDelay = unloadDelay
        self.endSessionDelay = endSessionDelay
        self.endSessionStopReason = endSessionStopReason
    }

    func prepare(language: String, progress: @escaping @Sendable (Double?) -> Void) async throws -> PreparationInfo {
        prepareCalls += 1
        onPrepare?()
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
        if let endSessionDelay { try? await Task.sleep(for: endSessionDelay) }
        if let endSessionStopReason, stopReason == nil { stopReason = endSessionStopReason }
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
    var events: [String] = []
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
        XCTAssertFalse(diagnostics.rows.contains { $0.label == "Erasure" })
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
        XCTAssertTrue(diagnostics.rows.contains(DiagnosticRow(label: "Erasure", value: "not guaranteed", quality: .unknown)))
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
        XCTAssertTrue(diagnostics.rows.contains(DiagnosticRow(label: "Erasure", value: "not guaranteed", quality: .unknown)))
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

    func testParakeetFeedGateResumesWhenTheOverdueWindowArrives() async {
        let gate = ParakeetFeedGate()
        gate.add(Int(16 * ParakeetLiveEngine.sampleRate), at: Date())
        let wait = Task { await gate.waitForRoom() }
        try? await Task.sleep(for: .milliseconds(20))
        gate.windowCompleted(at: Date())
        let result = await wait.value
        XCTAssertEqual(result, .room)
    }

    func testParakeetFeedGateReportsAWindowThatNeverArrives() async {
        let gate = ParakeetFeedGate(overdueAfter: .milliseconds(50))
        gate.add(Int(16 * ParakeetLiveEngine.sampleRate), at: Date())
        let result = await gate.waitForRoom()
        XCTAssertEqual(result, .overdue(through: 13))
    }

    func testParakeetFeedGateReleasesTheFeedWhenInputFinishes() async {
        let gate = ParakeetFeedGate()
        gate.add(Int(16 * ParakeetLiveEngine.sampleRate), at: Date())
        let wait = Task { await gate.waitForRoom() }
        try? await Task.sleep(for: .milliseconds(20))
        gate.finishInput()
        let result = await wait.value
        XCTAssertEqual(result, .room)
        let again = await gate.waitForRoom()
        XCTAssertEqual(again, .room)
    }

    func testParakeetFeedGateCloseEndsTheWait() async {
        let gate = ParakeetFeedGate()
        gate.add(Int(16 * ParakeetLiveEngine.sampleRate), at: Date())
        let wait = Task { await gate.waitForRoom() }
        try? await Task.sleep(for: .milliseconds(20))
        gate.close()
        let result = await wait.value
        XCTAssertEqual(result, .closed)
    }

    func testOverdueParakeetWindowStopsBeforeTheHandoffOverflows() {
        XCTAssertLessThan(ParakeetLiveEngine.overdueWindowSeconds, ParakeetLiveEngine.handoffSeconds)
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

    @MainActor func testPolishPassUnloadsTheLiveEngineBeforeWhisperLoads() async throws {
        let environmentPath = ProcessInfo.processInfo.environment["RECORDER_TEST_AUDIO_JFK"]
        let path = environmentPath ?? "/Users/christopherjones/projects/cjonesde/recorder/Tools/ASRBenchmark/fixtures/jfk.wav"
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("jfk.wav fixture not found") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("polish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("audio.wav")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: audio)

        let fake = FakeLiveEngine(kind: .apple)
        var unloadsSeenByWhisperLoad: [Int] = []
        let model = RecorderModel(
            engineFactory: { _ in fake },
            whisperLoader: { _ in unloadsSeenByWhisperLoad.append(fake.unloadCalls) }
        )
        _ = try await fake.prepare(language: "en-US", progress: { _ in })
        XCTAssertTrue(fake.isLoaded)

        model.transcribeExisting(RecordingEntry(
            folderURL: folder, title: nil, date: Date(), audioURL: audio, transcriptURL: nil, documentURL: nil
        ))
        for _ in 0..<200 where unloadsSeenByWhisperLoad.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(unloadsSeenByWhisperLoad, [1])
        XCTAssertEqual(fake.unloadCalls, 1)
        XCTAssertFalse(fake.isLoaded)
    }

    @MainActor func testPolishPassKeepsTheLiveEngineWhileASessionIsActive() async throws {
        let fake = FakeLiveEngine(kind: .apple)
        var loads = 0
        let model = RecorderModel(engineFactory: { _ in fake }, whisperLoader: { _ in loads += 1 }, fileTranscriber: { _ in throw CancellationError() })
        try await model.live.beginSession(language: "en-US")
        XCTAssertTrue(model.live.isSessionActive)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("polish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.startPolishForTesting(audioURL: folder.appendingPathComponent("a.wav"), folderURL: folder, liveEngineName: nil, diagnostics: nil, reportLanguage: nil)
        for _ in 0..<200 where loads == 0 { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(fake.unloadCalls, 0)
    }

    @MainActor func testPolishDocumentRecordsTheLiveEngineThatRan() async throws {
        let folder = try await polishFolder(liveEngineName: "Fake Parakeet")
        let document = try TranscriptDocument.load(from: folder.appendingPathComponent("transcript.json"))
        XCTAssertEqual(document.liveEngine, "Fake Parakeet")
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8).contains("Live engine"))
    }

    @MainActor func testPolishDocumentHasNoLiveEngineWhenLiveTranscriptionDidNotRun() async throws {
        let folder = try await polishFolder(liveEngineName: nil)
        let document = try TranscriptDocument.load(from: folder.appendingPathComponent("transcript.json"))
        XCTAssertNil(document.liveEngine)
        XCTAssertFalse(try String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8).contains("Live engine"))
    }

    @MainActor private func polishFolder(liveEngineName: String?) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("polish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let model = RecorderModel(
            engineFactory: { FakeLiveEngine(kind: $0) },
            whisperLoader: { _ in },
            fileTranscriber: { _ in
                OfflineTranscription(lines: [TranscriptLine(time: 0, text: "hello", speaker: nil)], clusters: [:], speakerNames: [:])
            }
        )
        model.startPolishForTesting(audioURL: folder.appendingPathComponent("a.wav"), folderURL: folder, liveEngineName: liveEngineName, diagnostics: nil, reportLanguage: nil)
        let json = folder.appendingPathComponent("transcript.json")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: json.path) { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))
        return folder
    }

    @MainActor private func modelLoggingModelUse(_ log: FakeEngineLog, polishFails: Bool) -> RecorderModel {
        RecorderModel(
            engineFactory: { kind in
                let engine = FakeLiveEngine(kind: kind, startSessionError: URLError(.cancelled))
                engine.onPrepare = { log.events.append("prepare \(kind.rawValue)") }
                return engine
            },
            whisperLoader: { _ in log.events.append("whisper load") },
            fileTranscriber: { _ in
                if polishFails { throw CancellationError() }
                return OfflineTranscription(lines: [TranscriptLine(time: 0, text: "hello", speaker: nil)], clusters: [:], speakerNames: [:])
            },
            whisperUnloader: { log.events.append("whisper unload") }
        )
    }

    @MainActor private func polishAndWait(_ model: RecorderModel) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("polish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        model.startPolishForTesting(audioURL: folder.appendingPathComponent("a.wav"), folderURL: folder, liveEngineName: nil, diagnostics: nil, reportLanguage: nil)
        for _ in 0..<200 where model.transcriptionState == .running { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNotEqual(model.transcriptionState, .running)
    }

    @MainActor func testWhisperIsUnloadedWhenPolishEndsAndBeforeTheNextLivePrepare() async throws {
        let log = FakeEngineLog()
        let model = modelLoggingModelUse(log, polishFails: false)
        try await polishAndWait(model)
        guard case .done = model.transcriptionState else { return XCTFail("polish did not finish: \(model.transcriptionState)") }
        XCTAssertEqual(log.events, ["whisper load", "whisper unload"])

        model.liveEngine = .nemotron
        model.startRecording(meeting: nil)
        for _ in 0..<200 where model.state == .preparing { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(log.events, ["whisper load", "whisper unload", "whisper unload", "prepare nemotron"])
    }

    @MainActor func testWhisperIsUnloadedWhenPolishFails() async throws {
        let log = FakeEngineLog()
        let model = modelLoggingModelUse(log, polishFails: true)
        try await polishAndWait(model)
        guard case .failed = model.transcriptionState else { return XCTFail("polish did not fail: \(model.transcriptionState)") }
        XCTAssertEqual(log.events, ["whisper load", "whisper unload"])
    }

    @MainActor func testLocalEngineUnloadsWhisperAndTheDiarizer() {
        let engine = LocalTranscriptionEngine(factory: { FakeLiveEngine(kind: $0) })
        engine.unloadOfflineModels()
        XCTAssertFalse(engine.holdsOfflineModels)
        XCTAssertEqual(engine.engineState, .unloaded)
    }

    func testOverdueParakeetWindowDetailAdmitsASlowDecode() {
        XCTAssertEqual(ParakeetLiveEngine.overdueDetail(through: 13),
                       "Parakeet's window ending at 13 s took longer than 9 s or never finished")
    }
}
