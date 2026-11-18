import XCTest
@testable import Recorder

@MainActor
private final class HeldTranscriber {
    private(set) var calls: [URL] = []
    private var released: Set<URL> = []
    private var failuresLeft: [URL: Int] = [:]

    func transcribe(_ url: URL) async throws -> OfflineTranscription {
        calls.append(url)
        if let left = failuresLeft[url], left > 0 {
            failuresLeft[url] = left - 1
            throw URLError(.cannotDecodeContentData)
        }
        while !released.contains(url) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let name = url.deletingLastPathComponent().lastPathComponent
        return OfflineTranscription(
            lines: [TranscriptLine(time: 0, text: "polished \(name)", speaker: "s1")],
            clusters: [:],
            speakerNames: ["s1": "Speaker 1"]
        )
    }

    func release(_ url: URL) { released.insert(url) }
    func fail(_ url: URL, times: Int) { failuresLeft[url] = times }
    func calls(to url: URL) -> Int { calls.filter { $0 == url }.count }
}

@MainActor
final class BackToBackTranscriptionTests: XCTestCase {

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("back-to-back-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition never became true", file: file, line: line)
    }

    private func isDone(_ state: TranscriptionState) -> Bool {
        if case .done = state { return true }
        return false
    }

    private func makeModel(
        _ transcriber: HeldTranscriber,
        log: FakeEngineLog = FakeEngineLog(),
        engine: @escaping (LiveEngineKind) -> FakeLiveEngine = { FakeLiveEngine(kind: $0) }
    ) -> RecorderModel {
        RecorderModel(
            engineFactory: { kind in
                let fake = engine(kind)
                fake.onPrepare = { log.events.append("prepare") }
                return fake
            },
            whisperLoader: { _ in log.events.append("whisper load") },
            fileTranscriber: { try await transcriber.transcribe($0) },
            whisperUnloader: { log.events.append("whisper unload") }
        )
    }

    func testRecordingCanStartWhileALocalTranscriptionRuns() async throws {
        let transcriber = HeldTranscriber()
        let model = makeModel(transcriber)
        let folder = try makeFolder()
        let audio = folder.appendingPathComponent("audio.m4a")

        model.startPolishForTesting(audioURL: audio, folderURL: folder, liveEngineName: nil, diagnostics: nil, reportLanguage: nil)
        try await waitUntil { transcriber.calls.count == 1 }

        XCTAssertEqual(model.transcriptions.running?.folderURL, folder)
        XCTAssertTrue(model.canStartRecording)
        XCTAssertTrue(model.canChangeLiveEngine)
        transcriber.release(audio)
        try await waitUntil { self.isDone(model.transcriptionState) }
    }

    func testStartingARecordingPausesTheLocalTranscriptionUntilTheRecordingEnds() async throws {
        let transcriber = HeldTranscriber()
        let log = FakeEngineLog()
        let model = makeModel(transcriber, log: log) { kind in
            FakeLiveEngine(kind: kind, prepareDelay: .milliseconds(400), startSessionError: URLError(.cancelled))
        }
        let folder = try makeFolder()
        let audio = folder.appendingPathComponent("audio.m4a")

        model.startPolishForTesting(audioURL: audio, folderURL: folder, liveEngineName: nil, diagnostics: nil, reportLanguage: nil)
        try await waitUntil { transcriber.calls.count == 1 }

        model.startRecording(meeting: nil)
        XCTAssertEqual(model.state, .preparing)
        try await waitUntil { model.transcriptions.running == nil }
        XCTAssertEqual(model.transcriptions.waiting.map(\.folderURL), [folder])
        XCTAssertEqual(log.events.filter { $0 == "whisper load" }.count, 1, "Whisper loaded again while a recording was starting")
        XCTAssertEqual(transcriber.calls.count, 1)

        try await waitUntil { model.state == .idle }
        try await waitUntil { transcriber.calls.count == 2 }
        let prepare = try XCTUnwrap(log.events.firstIndex(of: "prepare"))
        XCTAssertEqual(log.events[prepare - 1], "whisper unload", "the live engine prepared before Whisper was unloaded")

        transcriber.release(audio)
        try await waitUntil { self.isDone(model.transcriptionState) }
        let markdown = try String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("polished \(folder.lastPathComponent)"))
    }

    func testAnEarlierRecordingFinishingInTheBackgroundLeavesTheShownTranscriptAlone() async throws {
        let transcriber = HeldTranscriber()
        let model = makeModel(transcriber)
        let first = try makeFolder()
        let second = try makeFolder()
        let firstAudio = first.appendingPathComponent("audio.m4a")
        let secondAudio = second.appendingPathComponent("audio.m4a")

        model.startPolishForTesting(audioURL: firstAudio, folderURL: first, meetingTitle: "Standup", liveEngineName: nil, diagnostics: nil, reportLanguage: nil)
        try await waitUntil { transcriber.calls == [firstAudio] }
        model.transcribeExisting(RecordingEntry(
            folderURL: second, title: "Review", date: Date(), audioURL: secondAudio, transcriptURL: nil, documentURL: nil
        ))
        XCTAssertEqual(model.transcriptions.waiting.map(\.folderURL), [second])

        transcriber.release(firstAudio)
        try await waitUntil { transcriber.calls == [firstAudio, secondAudio] }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("transcript.json").path))
        XCTAssertEqual(model.lastTranscription?.folderURL, second)
        XCTAssertEqual(model.transcriptionState, .running)
        XCTAssertNil(model.lastDocument)
        XCTAssertTrue(model.statusMessage?.contains("Standup") == true, "status: \(model.statusMessage ?? "nil")")

        transcriber.release(secondAudio)
        try await waitUntil { self.isDone(model.transcriptionState) }
        XCTAssertEqual(model.transcriptionState, .done(second.appendingPathComponent("transcript.md")))

        model.renameSpeaker(id: "s1", to: "Dana")
        let renamed = try String(contentsOf: second.appendingPathComponent("transcript.md"), encoding: .utf8)
        let untouched = try String(contentsOf: first.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(renamed.contains("Dana"))
        XCTAssertFalse(untouched.contains("Dana"))
    }

    func testRetryQueuesAFailedRecordingAgain() async throws {
        let transcriber = HeldTranscriber()
        let model = makeModel(transcriber)
        let folder = try makeFolder()
        let audio = folder.appendingPathComponent("audio.m4a")
        transcriber.fail(audio, times: 1)

        model.startPolishForTesting(audioURL: audio, folderURL: folder, liveEngineName: nil, diagnostics: nil, reportLanguage: nil)
        try await waitUntil {
            if case .failed = model.transcriptionState { return true }
            return false
        }
        XCTAssertEqual(model.transcriptions.count, 0)

        transcriber.release(audio)
        model.retryTranscription()
        try await waitUntil { self.isDone(model.transcriptionState) }
        XCTAssertEqual(transcriber.calls(to: audio), 2)
    }

    func testRequestingTheSameRecordingTwiceQueuesItOnce() async throws {
        let transcriber = HeldTranscriber()
        let model = makeModel(transcriber)
        let folder = try makeFolder()
        let audio = folder.appendingPathComponent("audio.m4a")
        let entry = RecordingEntry(folderURL: folder, title: nil, date: Date(), audioURL: audio, transcriptURL: nil, documentURL: nil)

        model.transcribeExisting(entry)
        model.transcribeExisting(entry)
        XCTAssertEqual(model.transcriptions.count, 1)
        try await waitUntil { transcriber.calls.count == 1 }
        model.transcribeExisting(entry)
        XCTAssertEqual(model.transcriptions.count, 1)

        transcriber.release(audio)
        try await waitUntil { self.isDone(model.transcriptionState) }
        XCTAssertEqual(transcriber.calls.count, 1)
    }
}
