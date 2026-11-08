import XCTest
@testable import Recorder

@MainActor
final class DebugReportTests: XCTestCase {
    private var created: [URL] = []
    private var previousEngine = Preferences.liveEngine
    private var previousDebug = Preferences.showDebugInfo

    override func setUp() async throws {
        previousEngine = Preferences.liveEngine
        previousDebug = Preferences.showDebugInfo
    }

    override func tearDown() async throws {
        for folder in created { try? FileManager.default.removeItem(at: folder) }
        created = []
        Preferences.liveEngine = previousEngine
        Preferences.showDebugInfo = previousDebug
    }

    private func recorderWithSamples(preparation: PreparationInfo? = nil, speechService: Bool = false) -> DiagnosticsRecorder {
        let metrics = FakeMetrics([
            reading(footprint: 500, speech: speechService ? 900 : nil, swap: 1_000),
            reading(footprint: 700, speech: speechService ? 1_200 : nil, swap: 1_000),
            reading(footprint: 650, speech: speechService ? 1_100 : nil, swap: 4_000),
            reading(footprint: 600, speech: speechService ? 1_000 : nil, swap: 3_000),
        ])
        var clock = 0.0
        let rec = DiagnosticsRecorder(source: metrics, now: { clock }, engine: speechService ? .apple : .parakeet, settings: ["language": "de-DE"])
        if let preparation { rec.setPreparation(preparation) }
        clock = 1; rec.captureStarted(stall: 0)
        rec.setPhase(.recording)
        clock = 2; rec.sample(engine: diag(submitted: 10, provisional: 9, final: 5, held: 0.5), stall: 0.1, folder: nil)
        clock = 3.5; rec.noteText(hypothesis: "Guten Morgen", finalLines: 0)
        clock = 4; rec.sample(engine: diag(submitted: 20, provisional: 18, final: 10, held: 1.5), stall: 0.4, folder: nil)
        clock = 6; rec.sample(engine: diag(submitted: 30, provisional: 27, final: 20, held: 0.2), stall: 0.2, folder: nil)
        return rec
    }

    private func line(_ text: String) -> TranscriptLine {
        TranscriptLine(time: 1, text: text, speaker: nil)
    }

    func testReportContainsNoTranscriptTextOrSamples() throws {
        let rec = recorderWithSamples()
        rec.record("first text", detail: nil)
        let data = try JSONEncoder().encode(rec.report(language: "de-DE"))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("Guten Morgen"))
        let keys = Set((try JSONSerialization.jsonObject(with: data) as! [String: Any]).keys)
        XCTAssertEqual(keys, ["schemaVersion", "appCommit", "machineModel", "physicalMemoryBytes", "osVersion", "engine",
                              "engineSettings", "language", "preparation", "samples", "events", "stops", "summary"])
    }

    func testNilOptionalsEncodeAsNullSoTheKeySetIsStable() throws {
        let rec = recorderWithSamples()
        let data = try JSONEncoder().encode(rec.report(language: nil))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object.count, 13)
        XCTAssertTrue(object["language"] is NSNull)
        XCTAssertTrue(object["preparation"] is NSNull)
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
    }

    func testSummaryValuesComeFromTheSamplesAndEvents() {
        let rec = recorderWithSamples()
        let summary = rec.report(language: nil).summary
        XCTAssertEqual(summary["firstWordSeconds"]!, 2.5, accuracy: 0.001)
        XCTAssertEqual(summary["medianBehindRough"]!, 2, accuracy: 0.001)
        XCTAssertEqual(summary["medianBehindFinal"]!, 10, accuracy: 0.001)
        XCTAssertEqual(summary["maxBehindFinal"]!, 10, accuracy: 0.001)
        XCTAssertEqual(summary["peakFootprintBytes"], 700)
        XCTAssertEqual(summary["swapGrowthBytes"], 3_000)
        XCTAssertEqual(summary["peakHeldAudioSeconds"]!, 1.5, accuracy: 0.001)
        XCTAssertEqual(summary["longestStallSeconds"]!, 0.4, accuracy: 0.001)
    }

    func testSummaryOmitsValuesThatWereNeverMeasured() {
        let unknown = MetricsReading(footprintBytes: nil, speechServiceFootprintBytes: nil, pressure: nil, swapUsedBytes: nil, swapIns: nil, swapOuts: nil)
        let rec = DiagnosticsRecorder(source: FakeMetrics([unknown]), now: { 0 }, engine: .nemotron, settings: [:])
        rec.sample(engine: diag(), stall: 0, folder: nil)
        let summary = rec.report(language: nil).summary
        XCTAssertNil(summary["peakFootprintBytes"])
        XCTAssertNil(summary["swapGrowthBytes"])
        XCTAssertNil(summary["firstWordSeconds"])
        XCTAssertNil(summary["medianBehindFinal"])
        XCTAssertNil(summary["peakHeldAudioSeconds"])
        let text = rec.summaryText()
        XCTAssertTrue(text.contains("Peak Recorder memory: unknown"), text)
        XCTAssertTrue(text.contains("Swap growth: unknown"), text)
        XCTAssertTrue(text.contains("First word: unknown"), text)
    }

    func testSummaryTextCoversTheCopiedFacts() {
        let info = PreparationInfo(loadSeconds: 3.25, firstLoad: true, modelBytesOnDisk: nil, computeUnits: "fake")
        let rec = recorderWithSamples(preparation: info, speechService: true)
        rec.recordStop(.engineFellBehind)
        let text = rec.summaryText()
        XCTAssertTrue(text.contains("Engine: Apple"), text)
        XCTAssertTrue(text.contains("Load time: 3.25 s (first load)"), text)
        XCTAssertTrue(text.contains("First word: 2.50 s"), text)
        XCTAssertTrue(text.contains("Text behind (rough): median 2.00 s"), text)
        XCTAssertTrue(text.contains("Text behind (final): median 10.00 s, max 10.00 s"), text)
        XCTAssertTrue(text.contains("Peak speech service memory: "), text)
        XCTAssertFalse(text.contains("Peak speech service memory: unknown"), text)
        XCTAssertTrue(text.contains("Peak held audio: 1.50 s (measured)"), text)
        XCTAssertTrue(text.contains("Longest stall: 0.40 s"), text)
        XCTAssertTrue(text.contains("Stops: engineFellBehind"), text)
        XCTAssertFalse(text.contains("Guten Morgen"))
    }

    func testSpeechServiceMemoryIsUnknownWhenNeverRead() {
        let rec = recorderWithSamples()
        XCTAssertTrue(rec.summaryText().contains("Peak speech service memory: unknown"))
    }

    func testWriteProducesSortedISO8601JSONThatDecodes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        created.append(folder)
        let rec = recorderWithSamples()
        try rec.report(language: "de-DE").write(to: folder)
        let data = try Data(contentsOf: folder.appendingPathComponent("debug.json"))
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DebugReport.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.samples.count, 3)
        XCTAssertEqual(decoded.language, "de-DE")
        XCTAssertEqual(decoded.engine, .parakeet)
    }

    func testAppCommitIsNilWithoutTheInfoPlistKey() {
        XCTAssertNil(DebugReport.bundledCommit(from: [:]))
        XCTAssertEqual(DebugReport.bundledCommit(from: ["RecorderGitCommit": "abc1234"]), "abc1234")
        XCTAssertNil(DebugReport.bundledCommit(from: ["RecorderGitCommit": ""]))
    }

    func testMachineFactsArePopulated() {
        let report = recorderWithSamples().report(language: nil)
        XCTAssertFalse(report.machineModel.isEmpty)
        XCTAssertEqual(report.physicalMemoryBytes, ProcessInfo.processInfo.physicalMemory)
        XCTAssertEqual(report.osVersion, ProcessInfo.processInfo.operatingSystemVersionString)
    }

    func testFailedDebugJSONWriteIsShownInTheStatusMessageAndSurvivesLaterStatusUpdates() {
        let model = RecorderModel(engineFactory: { FakeLiveEngine(kind: $0) })
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("nope")
        model.statusMessage = "Transcript saved, no audio kept"
        model.persistDebugReport(recorderWithSamples(), folder: missing, language: nil)
        XCTAssertTrue(model.statusMessage?.contains("Transcript saved, no audio kept") == true)
        XCTAssertTrue(model.statusMessage?.contains("Could not write debug.json:") == true)
        model.statusMessage = "Nothing to save"
        XCTAssertTrue(model.statusMessage?.hasPrefix("Nothing to save") == true)
        XCTAssertTrue(model.statusMessage?.contains("Could not write debug.json:") == true)
    }

    func testSuccessfulDebugJSONWriteLeavesTheStatusMessageAlone() throws {
        let model = RecorderModel(engineFactory: { FakeLiveEngine(kind: $0) })
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        created.append(folder)
        model.statusMessage = "Saved"
        model.persistDebugReport(recorderWithSamples(), folder: folder, language: nil)
        XCTAssertEqual(model.statusMessage, "Saved")
    }

    func testUnloadForPolishEventReachesTheAlreadyWrittenDebugJSON() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        created.append(folder)
        let recorder = recorderWithSamples()
        try recorder.report(language: "en-US").write(to: folder)
        let before = try JSONDecoder().decode(DebugReport.self, from: Data(contentsOf: folder.appendingPathComponent("debug.json")))
        XCTAssertFalse(before.events.contains { $0.kind == "live engine unloaded for polish" })

        let fake = FakeLiveEngine(kind: .parakeet)
        _ = try await fake.prepare(language: "en-US", progress: { _ in })
        let model = RecorderModel(
            engineFactory: { _ in fake },
            whisperLoader: { _ in },
            fileTranscriber: { _ in throw CancellationError() }
        )
        model.showDebugInfo = true
        model.startPolishForTesting(audioURL: folder.appendingPathComponent("a.wav"), folderURL: folder, liveEngineName: nil, diagnostics: recorder, reportLanguage: "en-US")
        for _ in 0..<200 where fake.unloadCalls == 0 { try await Task.sleep(for: .milliseconds(25)) }
        try await Task.sleep(for: .milliseconds(100))

        let after = try JSONDecoder().decode(DebugReport.self, from: Data(contentsOf: folder.appendingPathComponent("debug.json")))
        XCTAssertTrue(after.events.contains { $0.kind == "live engine unloaded for polish" })
    }

    func testRetriedPolishRecordsTheUnloadOnceBecauseTheEngineIsAlreadyUnloaded() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        created.append(folder)
        let recorder = recorderWithSamples()
        let fake = FakeLiveEngine(kind: .parakeet)
        _ = try await fake.prepare(language: "en-US", progress: { _ in })
        let model = RecorderModel(engineFactory: { _ in fake }, whisperLoader: { _ in }, fileTranscriber: { _ in throw CancellationError() })
        model.showDebugInfo = true
        model.startPolishForTesting(audioURL: folder.appendingPathComponent("a.wav"), folderURL: folder, liveEngineName: nil, diagnostics: recorder, reportLanguage: "en-US")
        for _ in 0..<200 where !Self.isFailed(model.transcriptionState) { try await Task.sleep(for: .milliseconds(25)) }
        model.retryTranscription()
        for _ in 0..<200 where fake.unloadCalls < 2 { try await Task.sleep(for: .milliseconds(25)) }
        for _ in 0..<200 where !Self.isFailed(model.transcriptionState) { try await Task.sleep(for: .milliseconds(25)) }

        XCTAssertEqual(fake.unloadCalls, 2)
        XCTAssertEqual(recorder.events.filter { $0.kind == "live engine unloaded for polish" }.count, 1)
    }

    func testRetryAfterDebugIsSwitchedOffDoesNotTouchDebugJSON() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        created.append(folder)
        let recorder = recorderWithSamples()
        let fake = FakeLiveEngine(kind: .parakeet)
        _ = try await fake.prepare(language: "en-US", progress: { _ in })
        let model = RecorderModel(engineFactory: { _ in fake }, whisperLoader: { _ in }, fileTranscriber: { _ in throw CancellationError() })
        model.showDebugInfo = false
        model.startPolishForTesting(audioURL: folder.appendingPathComponent("a.wav"), folderURL: folder, liveEngineName: nil, diagnostics: recorder, reportLanguage: "en-US")
        for _ in 0..<200 where fake.unloadCalls == 0 { try await Task.sleep(for: .milliseconds(25)) }
        for _ in 0..<200 where !Self.isFailed(model.transcriptionState) { try await Task.sleep(for: .milliseconds(25)) }

        XCTAssertEqual(fake.unloadCalls, 1)
        XCTAssertFalse(recorder.events.contains { $0.kind == "live engine unloaded for polish" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("debug.json").path))
    }

    private static func isFailed(_ state: TranscriptionState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    func testUnloadForPolishWithoutDiagnosticsWritesNoDebugJSON() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        created.append(folder)
        let fake = FakeLiveEngine(kind: .parakeet)
        let model = RecorderModel(engineFactory: { _ in fake }, whisperLoader: { _ in }, fileTranscriber: { _ in throw CancellationError() })
        model.startPolishForTesting(audioURL: folder.appendingPathComponent("a.wav"), folderURL: folder, liveEngineName: nil, diagnostics: nil, reportLanguage: nil)
        for _ in 0..<200 where fake.unloadCalls == 0 { try await Task.sleep(for: .milliseconds(25)) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("debug.json").path))
    }

    private func recordAndSave(_ model: RecorderModel, seconds: TimeInterval) async throws -> URL {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RECORDER_LIVE_MODES"] == "1",
            "set RECORDER_LIVE_MODES=1 to run the debug report check"
        )
        model.configureCaptures()
        model.silenceAutoStopEnabled = false
        model.liveTranscriptionEnabled = true
        model.startRecording(meeting: nil)
        while model.state == .preparing { try await Task.sleep(for: .milliseconds(100)) }
        let session = try XCTUnwrap(model.currentSession, "recording did not start: \(model.statusMessage ?? "no message")")
        created.append(session.folderURL)
        try await Task.sleep(for: .seconds(seconds))
        model.saveAndStop()
        try await Task.sleep(for: .seconds(8))
        return session.folderURL
    }

    func testSilentTranscriptOnlyRecordingStillWritesDebugJSON() async throws {
        let model = RecorderModel(engineFactory: { FakeLiveEngine(kind: $0, lines: []) })
        model.showDebugInfo = true
        model.audioHandlingMode = .transcriptOnly
        let folder = try await recordAndSave(model, seconds: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("debug.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.md").path))
        let report = try JSONDecoder().decode(DebugReport.self, from: Data(contentsOf: folder.appendingPathComponent("debug.json")))
        XCTAssertTrue(report.events.contains { $0.kind == "finalized" })
    }

    func testNoDebugJSONWhenDebugIsOff() async throws {
        let model = RecorderModel(engineFactory: { FakeLiveEngine(kind: $0, lines: [self.line("hi")]) })
        model.showDebugInfo = false
        model.audioHandlingMode = .transcriptOnly
        let folder = try await recordAndSave(model, seconds: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("debug.json").path))
    }

    func testSilentTranscriptOnlyRecordingWithoutDebugLeavesNoFolder() async throws {
        let model = RecorderModel(engineFactory: { FakeLiveEngine(kind: $0, lines: []) })
        model.showDebugInfo = false
        model.audioHandlingMode = .transcriptOnly
        let folder = try await recordAndSave(model, seconds: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
}
