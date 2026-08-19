# Plan A: Model Hosts and No-Retention Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the 954-line transcription engine into focused units built around a reusable single-model host, then add a three-way audio-handling mode whose strictest setting writes no audio to disk at all.

**Architecture:** `LocalTranscription.swift` currently holds five unrelated jobs and enforces "one pipe must never transcribe twice concurrently" with class-wide flags. We extract a generic `ModelHost<Pipe>` that owns one model plus its own serialization, so a second host can be added in Plan B without that invariant becoming ambiguous. Separately, both captures learn to accept a nil destination URL, which is what makes the no-retention mode structural: the file handle is never opened, so a crash cannot leak audio.

**Tech Stack:** Swift 6 tools in Swift 5 language mode, macOS 15+, SwiftUI plus AppKit, AVFoundation, Core Audio process taps, WhisperKit and SpeakerKit (from the WhisperKit package), XCTest.

**Spec:** `docs/superpowers/specs/2026-08-19-dual-model-transcription-design.md`

## Global Constraints

- Platform floor is `.macOS("15")`; the ring buffer needs `Synchronization.Atomic`.
- Swift language mode is v5 (`.swiftLanguageMode(.v5)`); Swift 6 concurrency warnings exist already and are not in scope to fix.
- **Do not add comments to code.** Well-named identifiers carry the meaning. Anything genuinely non-obvious goes in the commit message, never in the source. Short `///` doc comments on new types and members are acceptable, matching the codebase.
- **Never use an em dash (`—`) or a double hyphen (`--`)** in any output: source, commit messages, docs. Use commas, parentheses or periods.
- Everything runs on-device. The only network access is WhisperKit model downloads from Hugging Face.
- Run tests with `swift test`. Four live hardware tests are opt-in via `RECORDER_LIVE_TAP=1` and `RECORDER_LIVE_ROUTE=1` and must stay skipped by default.
- Rebuild the app with `CODESIGN_IDENTITY="Apple Development: mail@cjones.de (J6N6MT3NYJ)" ./build.sh` so TCC grants stay sticky. Quit the running app first, because the script does `rm -rf Recorder.app`.
- Realtime audio callbacks (`SystemAudioTap.handleIO`) must not allocate, lock `self.lock`, or touch the filesystem.

---

### Task 1: Move the sample inbox into its own file

A pure move with no behaviour change, to shrink `LocalTranscription.swift` before anything else touches it.

**Files:**
- Create: `Sources/Recorder/SampleInbox.swift`
- Modify: `Sources/Recorder/LocalTranscription.swift` (remove lines for `StreamResampler`, `DrainedAudio`, `SampleInbox`)
- Test: `Tests/RecorderTests/SampleInboxSkewTests.swift` (existing, must keep passing)

**Interfaces:**
- Consumes: nothing.
- Produces: `SampleInbox`, `SampleInbox.Source`, `SampleInbox.targetRate`, `SampleInbox.energyBlockSamples`, `StreamResampler`, `DrainedAudio`. All unchanged in signature and access level.

- [ ] **Step 1: Run the suite to record a green baseline**

Run: `swift test`
Expected: PASS, `Executed 20 tests, with 4 tests skipped and 0 failures`.

- [ ] **Step 2: Create the new file with the moved types**

Cut the `MARK: - StreamResampler`, `MARK: - DrainedAudio` and `MARK: - SampleInbox` sections out of `Sources/Recorder/LocalTranscription.swift` verbatim and paste them into a new `Sources/Recorder/SampleInbox.swift` under this header:

```swift
import Foundation
import Accelerate
import os
import WhisperKit
```

Do not change any code inside them. `SampleInbox.targetRate` stays `Double(WhisperKit.sampleRate)`.

- [ ] **Step 3: Trim the imports left behind**

`Sources/Recorder/LocalTranscription.swift` keeps `import Foundation`, `import Observation`, `import Accelerate`, `import os`, `import WhisperKit`, `import SpeakerKit`. Leave them; `LocalTranscriptionEngine` still uses all of them.

- [ ] **Step 4: Verify nothing changed**

Run: `swift test`
Expected: PASS, same 20 tests, 4 skipped, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/Recorder/SampleInbox.swift Sources/Recorder/LocalTranscription.swift
git commit -m "Move SampleInbox, StreamResampler and DrainedAudio to their own file

Pure move ahead of splitting the transcription engine. No behaviour change."
```

---

### Task 2: Move TranscriptLine out and cover its rendering

`TranscriptLine.markdown` and `timestampLabel` have no tests today, and Task 6 depends on their exact output.

**Files:**
- Create: `Sources/Recorder/TranscriptLine.swift`
- Modify: `Sources/Recorder/LocalTranscription.swift` (remove the `MARK: - TranscriptLine` section)
- Create: `Tests/RecorderTests/TranscriptLineTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct TranscriptLine: Identifiable, Equatable` with `let time: TimeInterval`, `let text: String`, `let speaker: String?`, `var markdown: String`, `var timestampLabel: String`.

- [ ] **Step 1: Write the failing test**

Create `Tests/RecorderTests/TranscriptLineTests.swift`:

```swift
import XCTest
@testable import Recorder

final class TranscriptLineTests: XCTestCase {

    func testTimestampLabelUsesMinutesAndSecondsUnderAnHour() {
        XCTAssertEqual(TranscriptLine(time: 0, text: "a", speaker: nil).timestampLabel, "00:00")
        XCTAssertEqual(TranscriptLine(time: 5, text: "a", speaker: nil).timestampLabel, "00:05")
        XCTAssertEqual(TranscriptLine(time: 61, text: "a", speaker: nil).timestampLabel, "01:01")
        XCTAssertEqual(TranscriptLine(time: 3599, text: "a", speaker: nil).timestampLabel, "59:59")
    }

    func testTimestampLabelAddsHoursPastAnHour() {
        XCTAssertEqual(TranscriptLine(time: 3600, text: "a", speaker: nil).timestampLabel, "1:00:00")
        XCTAssertEqual(TranscriptLine(time: 3725, text: "a", speaker: nil).timestampLabel, "1:02:05")
    }

    func testMarkdownOmitsTheSpeakerPrefixWhenUnknown() {
        let line = TranscriptLine(time: 65, text: "hello there", speaker: nil)
        XCTAssertEqual(line.markdown, "[01:05] hello there")
    }

    func testMarkdownBoldsTheSpeakerWhenKnown() {
        let line = TranscriptLine(time: 65, text: "hello there", speaker: "You")
        XCTAssertEqual(line.markdown, "[01:05] **You**: hello there")
    }
}
```

- [ ] **Step 2: Run it and expect it to pass**

Run: `swift test --filter TranscriptLineTests`
Expected: PASS, 4 tests. This is a characterisation test, not a red test: `TranscriptLine` already exists and already behaves this way. Its job is to lock the exact rendering in place before the type moves and before Task 6 depends on it. If any assertion fails, the assertion is wrong about current behaviour; correct the test to match the code rather than changing the code.

- [ ] **Step 3: Move the type**

Cut the `MARK: - TranscriptLine` section from `Sources/Recorder/LocalTranscription.swift` into a new `Sources/Recorder/TranscriptLine.swift` with header `import Foundation`. Change nothing inside it.

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: PASS, 24 tests, 4 skipped, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/Recorder/TranscriptLine.swift Sources/Recorder/LocalTranscription.swift Tests/RecorderTests/TranscriptLineTests.swift
git commit -m "Move TranscriptLine to its own file and cover its markdown rendering

The rendering had no tests and the transcript sidecar work depends on its exact
output, so lock it in before moving it."
```

---

### Task 3: Extract a generic, testable model host

The load state machine is the part of the engine a second model needs to reuse. It is untestable while it constructs `WhisperKit` directly, so the host is generic over its pipe type and takes its download, load and existence checks as closures.

**Files:**
- Create: `Sources/Recorder/ModelHost.swift`
- Create: `Tests/RecorderTests/ModelHostTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum ModelLoadState: Equatable { case unloaded, notDownloaded(String), downloading(String, Double), loading(String), ready, failed(String) }`
  - `@MainActor @Observable final class ModelHost<Pipe>` with:
    - `init(isDownloaded: @escaping (String) -> Bool, download: @escaping (String, @escaping (Double) -> Void) async throws -> URL, load: @escaping (String, URL) async throws -> Pipe)`
    - `var state: ModelLoadState`
    - `var selectedModel: String`
    - `var loadedModel: String?`
    - `var loadFailureMessage: String?`
    - `func loadModel(_ name: String, downloadIfNeeded: Bool) async`
    - `func awaitReady(timeout: TimeInterval) async throws -> Pipe`
    - `func withPipe<T>(_ body: (Pipe) async throws -> T) async rethrows -> T`
    - `enum HostError: LocalizedError { case modelNotReady(String) }`
  - `typealias WhisperModelHost = ModelHost<WhisperKit>`

- [ ] **Step 1: Write the failing test**

Create `Tests/RecorderTests/ModelHostTests.swift`:

```swift
import XCTest
@testable import Recorder

private final class FakePipe: @unchecked Sendable {
    let name: String
    init(name: String) { self.name = name }
}

@MainActor
final class ModelHostTests: XCTestCase {

    private func makeHost(
        onDisk: Set<String> = [],
        failLoadFor: Set<String> = [],
        progress: [Double] = []
    ) -> ModelHost<FakePipe> {
        ModelHost<FakePipe>(
            isDownloaded: { onDisk.contains($0) },
            download: { name, report in
                for value in progress { report(value) }
                return URL(fileURLWithPath: "/tmp/\(name)")
            },
            load: { name, _ in
                if failLoadFor.contains(name) {
                    throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
                }
                return FakePipe(name: name)
            }
        )
    }

    func testStartsUnloaded() {
        let host = makeHost()
        XCTAssertEqual(host.state, .unloaded)
        XCTAssertNil(host.loadedModel)
    }

    func testReportsNotDownloadedWhenMissingAndDownloadNotAllowed() async {
        let host = makeHost()
        await host.loadModel("tiny", downloadIfNeeded: false)
        XCTAssertEqual(host.state, .notDownloaded("tiny"))
        XCTAssertNil(host.loadedModel)
    }

    func testLoadsAModelAlreadyOnDisk() async {
        let host = makeHost(onDisk: ["base"])
        await host.loadModel("base", downloadIfNeeded: false)
        XCTAssertEqual(host.state, .ready)
        XCTAssertEqual(host.loadedModel, "base")
    }

    func testDownloadsThenLoadsWhenAllowed() async {
        let host = makeHost(progress: [0.5, 1.0])
        await host.loadModel("large", downloadIfNeeded: true)
        XCTAssertEqual(host.state, .ready)
        XCTAssertEqual(host.loadedModel, "large")
    }

    func testAFailedFirstLoadSurfacesAsFailed() async {
        let host = makeHost(onDisk: ["bad"], failLoadFor: ["bad"])
        await host.loadModel("bad", downloadIfNeeded: false)
        XCTAssertEqual(host.state, .failed("boom"))
        XCTAssertNil(host.loadedModel)
    }

    func testAFailedSwitchKeepsThePreviousModelServing() async {
        let host = makeHost(onDisk: ["base", "bad"], failLoadFor: ["bad"])
        await host.loadModel("base", downloadIfNeeded: false)
        XCTAssertEqual(host.loadedModel, "base")

        await host.loadModel("bad", downloadIfNeeded: false)
        XCTAssertEqual(host.state, .ready)
        XCTAssertEqual(host.loadedModel, "base")
        XCTAssertNotNil(host.loadFailureMessage)
    }

    func testReloadingTheLoadedModelIsANoOp() async {
        let host = makeHost(onDisk: ["base"])
        await host.loadModel("base", downloadIfNeeded: false)
        let first = try? await host.awaitReady(timeout: 1)
        await host.loadModel("base", downloadIfNeeded: false)
        let second = try? await host.awaitReady(timeout: 1)
        XCTAssertIdentical(first, second)
    }

    func testWithPipeSerializesOverlappingWork() async throws {
        let host = makeHost(onDisk: ["base"])
        await host.loadModel("base", downloadIfNeeded: false)

        let overlaps = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { @MainActor in
                    try? await host.withPipe { _ in
                        overlaps.enter()
                        try? await Task.sleep(for: .milliseconds(5))
                        overlaps.leave()
                    }
                }
            }
        }
        XCTAssertEqual(overlaps.maxConcurrent, 1)
    }

    func testAwaitReadyThrowsWhenLoadingFailed() async {
        let host = makeHost(onDisk: ["bad"], failLoadFor: ["bad"])
        await host.loadModel("bad", downloadIfNeeded: false)
        do {
            _ = try await host.awaitReady(timeout: 1)
            XCTFail("expected awaitReady to throw")
        } catch {
            XCTAssertTrue(error is ModelHost<FakePipe>.HostError)
        }
    }
}

private final class Counter {
    private var current = 0
    private(set) var maxConcurrent = 0
    func enter() { current += 1; maxConcurrent = max(maxConcurrent, current) }
    func leave() { current -= 1 }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter ModelHostTests`
Expected: FAIL to compile, "cannot find type 'ModelHost' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/Recorder/ModelHost.swift`:

```swift
import Foundation
import Observation
import os
import WhisperKit

/// Load and download progress for one model.
enum ModelLoadState: Equatable {
    case unloaded
    case notDownloaded(String)
    case downloading(String, Double)
    case loading(String)
    case ready
    case failed(String)
}

/// Owns exactly one model instance: its download, its load state machine, and
/// serialized access to it. Generic over the pipe type so the state machine can be
/// tested without constructing a real model.
@MainActor
@Observable
final class ModelHost<Pipe: AnyObject> {

    enum HostError: LocalizedError {
        case modelNotReady(String)

        var errorDescription: String? {
            switch self {
            case .modelNotReady(let detail):
                return "Transcription model is not ready: \(detail)"
            }
        }
    }

    var state: ModelLoadState = .unloaded
    var selectedModel: String = WhisperModelOption.defaultModelID
    var loadedModel: String?
    var loadFailureMessage: String?

    @ObservationIgnored private let isDownloadedCheck: (String) -> Bool
    @ObservationIgnored private let downloadModel: (String, @escaping (Double) -> Void) async throws -> URL
    @ObservationIgnored private let loadPipe: (String, URL) async throws -> Pipe

    @ObservationIgnored private var pipe: Pipe?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var busy = false

    @ObservationIgnored private static var log: Logger {
        Logger(subsystem: "com.tobi.Recorder", category: "ModelHost")
    }

    init(
        isDownloaded: @escaping (String) -> Bool,
        download: @escaping (String, @escaping (Double) -> Void) async throws -> URL,
        load: @escaping (String, URL) async throws -> Pipe
    ) {
        self.isDownloadedCheck = isDownloaded
        self.downloadModel = download
        self.loadPipe = load
    }

    func loadModel(_ name: String, downloadIfNeeded: Bool) async {
        selectedModel = name

        switch state {
        case .ready where loadedModel == name:
            return
        case .downloading(let inFlight, _) where inFlight == name:
            return
        case .loading(let inFlight) where inFlight == name:
            return
        case .notDownloaded(let pending) where pending == name && !downloadIfNeeded:
            return
        default:
            break
        }

        loadGeneration += 1
        let generation = loadGeneration
        loadFailureMessage = nil

        let onDisk = isDownloadedCheck(name)
        if !onDisk && !downloadIfNeeded {
            if pipe == nil {
                state = .notDownloaded(name)
            }
            return
        }

        do {
            let folder: URL
            if onDisk {
                folder = try await downloadModel(name, { _ in })
            } else {
                state = .downloading(name, 0)
                folder = try await downloadModel(name, { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.loadGeneration == generation else { return }
                        self.state = .downloading(name, fraction)
                    }
                })
            }
            guard loadGeneration == generation else { return }

            state = .loading(name)
            let loaded = try await loadPipe(name, folder)
            guard loadGeneration == generation else { return }
            pipe = loaded
            loadedModel = name
            state = .ready
        } catch {
            guard loadGeneration == generation else { return }
            Self.log.error("model load failed: \(error.localizedDescription)")
            if pipe != nil, let previous = loadedModel {
                state = .ready
                loadFailureMessage = "Could not switch to \(WhisperModelOption.label(for: name)): \(error.localizedDescription). Still using \(WhisperModelOption.label(for: previous))."
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func awaitReady(timeout: TimeInterval = 600) async throws -> Pipe {
        switch state {
        case .notDownloaded, .unloaded, .failed:
            await loadModel(selectedModel, downloadIfNeeded: true)
        default:
            break
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pipe, case .ready = state { return pipe }
            if case .failed(let message) = state {
                throw HostError.modelNotReady(message)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw HostError.modelNotReady("timed out waiting for the model to load")
    }

    /// Run `body` with exclusive use of the pipe. The model carries mutable decode
    /// state, so one host must never decode twice at once.
    func withPipe<T>(_ body: (Pipe) async throws -> T) async throws -> T {
        while busy {
            try? await Task.sleep(for: .milliseconds(50))
        }
        busy = true
        defer { busy = false }
        let pipe = try await awaitReady()
        return try await body(pipe)
    }
}

typealias WhisperModelHost = ModelHost<WhisperKit>
```

Note: the `onDisk` branch calls `downloadModel` with a no-op progress reporter so a
single closure covers both paths; the real WhisperKit wiring in Task 4 returns the
local folder without touching the network when the model is present.

- [ ] **Step 4: Run tests**

Run: `swift test --filter ModelHostTests`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/Recorder/ModelHost.swift Tests/RecorderTests/ModelHostTests.swift
git commit -m "Add a generic single-model host with its own load state machine

Extracts the download and load state machine so a second model can reuse it. Generic
over the pipe type and taking its download and load steps as closures, so the state
machine is testable without constructing a real model. withPipe replaces the
class-wide busy flags: each host serializes only itself, which is what lets a
high-quality pass run while a live transcription streams on another model."
```

---

### Task 4: Point the live engine at a WhisperModelHost

Replace `LocalTranscriptionEngine`'s inline loading with a host instance, keeping every externally visible property working so the panel and preferences do not change yet.

**Files:**
- Modify: `Sources/Recorder/LocalTranscription.swift`
- Create: `Sources/Recorder/WhisperModelStorage.swift`

**Interfaces:**
- Consumes: `ModelHost`, `ModelLoadState`, `WhisperModelHost` from Task 3.
- Produces:
  - `enum WhisperModelStorage` with `static var base: URL`, `static func localFolder(for name: String) -> URL`, `static func isDownloaded(_ name: String) -> Bool`, `static func makeHost() -> WhisperModelHost`.
  - `LocalTranscriptionEngine.host: WhisperModelHost` (new, internal).
  - `LocalTranscriptionEngine.engineState`, `.modelName`, `.loadedModelName`, `.loadFailureMessage` keep their existing names and types, forwarding to `host`.

- [ ] **Step 1: Create the storage and host factory**

Create `Sources/Recorder/WhisperModelStorage.swift`, moving the three private statics out of `LocalTranscriptionEngine`:

```swift
import Foundation
import WhisperKit

/// Where WhisperKit models live on disk, and how to build a host that loads them.
enum WhisperModelStorage {

    /// ~/Library/Application Support/Recorder/WhisperModels
    static var base: URL {
        let root = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser
        return root
            .appendingPathComponent("Recorder", isDirectory: true)
            .appendingPathComponent("WhisperModels", isDirectory: true)
    }

    static func localFolder(for name: String) -> URL {
        base
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    static func isDownloaded(_ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: localFolder(for: name).appendingPathComponent("TextDecoder.mlmodelc").path
        )
    }

    @MainActor
    static func makeHost() -> WhisperModelHost {
        WhisperModelHost(
            isDownloaded: { isDownloaded($0) },
            download: { name, report in
                if isDownloaded(name) { return localFolder(for: name) }
                return try await WhisperKit.download(
                    variant: name,
                    downloadBase: base,
                    progressCallback: { progress in report(progress.fractionCompleted) }
                )
            },
            load: { name, folder in
                let config = WhisperKitConfig(
                    model: name,
                    downloadBase: base,
                    modelFolder: folder.path,
                    verbose: false,
                    logLevel: .none,
                    load: true,
                    download: false
                )
                return try await WhisperKit(config)
            }
        )
    }
}
```

- [ ] **Step 2: Replace the engine's loading internals**

In `Sources/Recorder/LocalTranscription.swift`:

1. Delete `EngineState`, `EngineError`, the `pipe` property, `loadGeneration`, `loadModel`, `awaitReady`, `modelStorageBase`, `localModelFolder`, `isDownloaded`.
2. Add `let host = WhisperModelStorage.makeHost()`.
3. Add forwarding properties so existing call sites keep compiling:

```swift
    var engineState: ModelLoadState { host.state }
    var modelName: String { host.selectedModel }
    var loadedModelName: String? { host.loadedModel }
    var loadFailureMessage: String? { host.loadFailureMessage }

    func loadModel(_ name: String, downloadIfNeeded: Bool) async {
        await host.loadModel(name, downloadIfNeeded: downloadIfNeeded)
    }
```

4. In `tick`, replace `guard let pipe else { return }` plus the direct
   `pipe.transcribe(...)` call with:

```swift
            let results = try await host.withPipe { pipe in
                try await pipe.transcribe(
                    audioArray: windowSamples,
                    decodeOptions: self.decodingOptions(forFile: false)
                )
            }
```

   and delete the `ticking` / `offlineBusy` guards that existed only to keep one pipe
   from decoding twice. Keep `ticking` itself, because `endSession` waits on it to know
   the tick loop is idle.

5. In `transcribeFile`, replace `let pipe = try await awaitReady()` and the
   `while ticking || offlineBusy` spin with a single `host.withPipe { ... }` wrapping
   the transcribe call. Keep the `AudioProcessor.loadAudioAsFloatArray` detached task
   and the diarization block unchanged.

- [ ] **Step 3: Fix the call sites the rename touches**

`Sources/Recorder/PreferencesView.swift:140` switches on `model.live.engineState`. Its
cases are unchanged in name and payload, so only the type name changed. Confirm it
still compiles. `Sources/Recorder/RecorderModel.swift:56-59` reads
`live.loadFailureMessage` and `live.loadedModelName`; both still exist.

- [ ] **Step 4: Build and test**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: `Build complete!`

Run: `swift test`
Expected: PASS, 33 tests, 4 skipped, 0 failures.

- [ ] **Step 5: Smoke test the real app**

```bash
osascript -e 'tell application "Recorder" to quit'; sleep 2
CODESIGN_IDENTITY="Apple Development: mail@cjones.de (J6N6MT3NYJ)" ./build.sh
open ./Recorder.app
```

Start a short recording, confirm the live transcript still streams and Preferences
still shows the model status, then stop and confirm `transcript.md` is written.

- [ ] **Step 6: Commit**

```bash
git add Sources/Recorder/WhisperModelStorage.swift Sources/Recorder/LocalTranscription.swift
git commit -m "Load the live model through a WhisperModelHost

Moves model storage paths and the WhisperKit download and load steps into
WhisperModelStorage, and replaces the engine's inline state machine with a host
instance. Decode serialization now goes through host.withPipe instead of class-wide
ticking and offlineBusy flags, so adding a second model in the next plan cannot make
that invariant ambiguous."
```

---

### Task 5: Extract LiveTranscriber

Split the live streaming path out of `LocalTranscriptionEngine`, leaving the offline
file path behind for Plan B to turn into `PolishPass`.

**Files:**
- Create: `Sources/Recorder/LiveTranscriber.swift`
- Modify: `Sources/Recorder/LocalTranscription.swift`
- Modify: `Sources/Recorder/RecorderModel.swift:23`
- Modify: `Sources/Recorder/RecorderPanel.swift` (references to `model.live`)

**Interfaces:**
- Consumes: `WhisperModelHost`, `SampleInbox`, `TranscriptLine`.
- Produces: `@MainActor @Observable final class LiveTranscriber` with `let host: WhisperModelHost`, `nonisolated let inbox: SampleInbox`, `var confirmedLines: [TranscriptLine]`, `var hypothesis: String`, `var isSessionActive: Bool`, `var revision: Int`, `var language: String?`, `var labelSpeakers: Bool`, `var hasText: Bool`, `var maxWindowSamples: Int`, `func beginSession()`, `func endSession() async -> LiveSessionResult`, `func cancelSession()`, `func transcript(includeHypothesis: Bool) -> String`, and `struct LiveSessionResult { let body: String; let complete: Bool }`.

- [ ] **Step 1: Move the live path**

Create `Sources/Recorder/LiveTranscriber.swift` and move these members of
`LocalTranscriptionEngine` into it verbatim: `confirmedLines`, `hypothesis`,
`isSessionActive`, `revision`, `language`, `labelSpeakers`, `hasText`, `inbox`,
`tickTask`, `ticking`, `sessionGeneration`, `finalTickComplete`, `windowSamples`,
`windowStartSample`, `desktopEnvelope`, `micEnvelope`, `desktopSpeechBlocks`,
`micSpeechBlocks`, all the static tuning constants, `LiveSessionResult`,
`beginSession`, `endSession`, `cancelSession`, `transcript`, `transcriptBody`,
`body(of:)`, `tick`, `windowRMS`, `cleanSegments`, `confirm`, `channelLabel`,
`noteGap`, and `decodingOptions`.

Give it `let host: WhisperModelHost` and an `init(host: WhisperModelHost)`.

Change one constant from a `static let` to a settable property, because Task 10 needs
to lower it in transcript-only mode:

```swift
    /// Cap on buffered live audio. Lowered in transcript-only mode, where this buffer
    /// is the only place audio exists.
    var maxWindowSamples = 15 * 60 * Int(SampleInbox.targetRate)
```

Replace every `Self.maxWindowSamples` with `maxWindowSamples`.

Keep `cleanSegments` and `decodingOptions` duplicated in `LocalTranscriptionEngine`
for its `transcribeFile`; Plan B removes that duplication when `PolishPass` lands.

- [ ] **Step 2: Rename the engine's remaining surface**

`LocalTranscriptionEngine` now holds only `transcribeFile`, `diarizer`,
`assignSpeakers`, `speakerKit`, and its host forwarding. Add:

```swift
    let live: LiveTranscriber
```

and construct it in an `init` that shares the same host:

```swift
    init() {
        let host = WhisperModelStorage.makeHost()
        self.host = host
        self.live = LiveTranscriber(host: host)
    }
```

Then re-expose the live surface so `RecorderModel` and `RecorderPanel` keep compiling
without edits in this task:

```swift
    var confirmedLines: [TranscriptLine] { live.confirmedLines }
    var hypothesis: String { live.hypothesis }
    var isSessionActive: Bool { live.isSessionActive }
    var revision: Int { live.revision }
    var hasText: Bool { live.hasText }
    var language: String? {
        get { live.language }
        set { live.language = newValue }
    }
    var labelSpeakers: Bool {
        get { live.labelSpeakers }
        set { live.labelSpeakers = newValue }
    }
    nonisolated var inbox: SampleInbox { live.inbox }

    func beginSession() { live.beginSession() }
    func cancelSession() { live.cancelSession() }
    func endSession() async -> LiveTranscriber.LiveSessionResult { await live.endSession() }
    func transcript(includeHypothesis: Bool) -> String { live.transcript(includeHypothesis: includeHypothesis) }
```

- [ ] **Step 3: Fix the one type reference that changed**

`Sources/Recorder/RecorderModel.swift:329` declares
`Task<LocalTranscriptionEngine.LiveSessionResult, Never>?`. Change it to
`Task<LiveTranscriber.LiveSessionResult, Never>?`.

- [ ] **Step 4: Build and test**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: `Build complete!`

Run: `swift test`
Expected: PASS, 33 tests, 4 skipped, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/Recorder/LiveTranscriber.swift Sources/Recorder/LocalTranscription.swift Sources/Recorder/RecorderModel.swift
git commit -m "Extract LiveTranscriber from the transcription engine

The live sliding-window path moves to its own unit holding the tick loop, confirmed
lines and channel attribution, talking to one model host. The engine keeps the offline
file path for now and forwards the live surface so callers are untouched. The live
window cap becomes a property rather than a constant, because the no-retention mode
needs to lower it."
```

---

### Task 6: TranscriptDocument and the JSON sidecar

A structured transcript that renders to markdown, so a later rename re-renders instead
of patching text. Pure logic, fully testable.

**Files:**
- Create: `Sources/Recorder/TranscriptDocument.swift`
- Create: `Tests/RecorderTests/TranscriptDocumentTests.swift`

**Interfaces:**
- Consumes: `TranscriptLine`.
- Produces:
  - `struct TranscriptDocument: Codable, Equatable` with `var meetingTitle: String?`, `var attendees: [String]`, `var startedAt: Date`, `var audioName: String?`, `var model: String`, `var isPolished: Bool`, `var lines: [StoredLine]`, `var speakerNames: [String: String]`
  - `struct StoredLine: Codable, Equatable` with `var time: TimeInterval`, `var text: String`, `var speakerID: String?`
  - `func renderMarkdown() -> String`
  - `func renamingSpeaker(_ id: String, to name: String) -> TranscriptDocument`
  - `func displayName(for id: String) -> String`
  - `var speakerIDs: [String]`
  - `static func load(from url: URL) throws -> TranscriptDocument`
  - `func write(jsonTo url: URL) throws`

- [ ] **Step 1: Write the failing test**

Create `Tests/RecorderTests/TranscriptDocumentTests.swift`:

```swift
import XCTest
@testable import Recorder

final class TranscriptDocumentTests: XCTestCase {

    private func sample() -> TranscriptDocument {
        TranscriptDocument(
            meetingTitle: "Weekly",
            attendees: ["Anna", "Ben"],
            startedAt: Date(timeIntervalSince1970: 0),
            audioName: "audio.m4a",
            model: "openai_whisper-base",
            isPolished: false,
            lines: [
                TranscriptDocument.StoredLine(time: 0, text: "hello", speakerID: "you"),
                TranscriptDocument.StoredLine(time: 5, text: "hi there", speakerID: "s1"),
                TranscriptDocument.StoredLine(time: 9, text: "unattributed", speakerID: nil),
            ],
            speakerNames: ["you": "You", "s1": "Speaker 1"]
        )
    }

    func testSpeakerIDsAreInOrderOfFirstAppearance() {
        XCTAssertEqual(sample().speakerIDs, ["you", "s1"])
    }

    func testRenderIncludesHeaderAndTimestampedLines() {
        let markdown = sample().renderMarkdown()
        XCTAssertTrue(markdown.contains("# Transcript: Weekly"))
        XCTAssertFalse(markdown.contains("\u{2014}"), "em dashes are not allowed anywhere")
        XCTAssertTrue(markdown.contains("**Invited attendees:** Anna, Ben"))
        XCTAssertTrue(markdown.contains("[00:00] **You**: hello"))
        XCTAssertTrue(markdown.contains("[00:05] **Speaker 1**: hi there"))
        XCTAssertTrue(markdown.contains("[00:09] unattributed"))
    }

    func testRenamingChangesEveryLineForThatSpeaker() {
        let renamed = sample().renamingSpeaker("s1", to: "Ben")
        let markdown = renamed.renderMarkdown()
        XCTAssertTrue(markdown.contains("[00:05] **Ben**: hi there"))
        XCTAssertFalse(markdown.contains("Speaker 1"))
        XCTAssertTrue(markdown.contains("[00:00] **You**: hello"), "other speakers untouched")
    }

    func testRenamingIsIdempotent() {
        let once = sample().renamingSpeaker("s1", to: "Ben")
        let twice = once.renamingSpeaker("s1", to: "Ben")
        XCTAssertEqual(once, twice)
        XCTAssertEqual(once.renderMarkdown(), twice.renderMarkdown())
    }

    func testRenamingAnUnknownSpeakerChangesNothing() {
        let doc = sample()
        XCTAssertEqual(doc.renamingSpeaker("nope", to: "X"), doc)
    }

    func testRoundTripsThroughJSON() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doc-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let original = sample()
        try original.write(jsonTo: url)
        let loaded = try TranscriptDocument.load(from: url)
        XCTAssertEqual(loaded, original)
    }

    func testPolishedFlagIsRenderedSoTheSourceIsObvious() {
        var doc = sample()
        doc.isPolished = true
        XCTAssertTrue(doc.renderMarkdown().contains("high-quality pass"))
        doc.isPolished = false
        XCTAssertTrue(doc.renderMarkdown().contains("live transcription"))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter TranscriptDocumentTests`
Expected: FAIL to compile, "cannot find type 'TranscriptDocument' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/Recorder/TranscriptDocument.swift`:

```swift
import Foundation

/// The structured transcript, and the source of truth for `transcript.md`.
/// Speaker labels are stored as stable ids with a separate id-to-name map, so a
/// rename re-renders the document instead of patching markdown text.
struct TranscriptDocument: Codable, Equatable {

    struct StoredLine: Codable, Equatable {
        var time: TimeInterval
        var text: String
        var speakerID: String?
    }

    var meetingTitle: String?
    var attendees: [String]
    var startedAt: Date
    var audioName: String?
    var model: String
    var isPolished: Bool
    var lines: [StoredLine]
    var speakerNames: [String: String]

    var speakerIDs: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for line in lines {
            guard let id = line.speakerID, !seen.contains(id) else { continue }
            seen.insert(id)
            ordered.append(id)
        }
        return ordered
    }

    func displayName(for id: String) -> String {
        speakerNames[id] ?? id
    }

    func renamingSpeaker(_ id: String, to name: String) -> TranscriptDocument {
        guard speakerNames[id] != nil else { return self }
        var copy = self
        copy.speakerNames[id] = name
        return copy
    }

    func renderMarkdown() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short

        var header = "# Transcript"
        if let title = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            header += ": \(title)"
        }

        var out = [header, ""]
        out.append("- **Recorded:** \(formatter.string(from: startedAt))")
        if !attendees.isEmpty {
            out.append("- **Invited attendees:** \(attendees.joined(separator: ", "))")
        }
        if let audioName {
            out.append("- **Audio:** `\(audioName)`")
        } else {
            out.append("- **Audio:** not retained (transcript only)")
        }
        out.append("- **Model:** WhisperKit `\(model)` (on-device)")
        out.append("- **Source:** \(isPolished ? "high-quality pass over the recorded audio" : "live transcription")")
        out.append("")
        out.append("---")
        out.append("")

        for line in lines {
            let speaker = line.speakerID.map { displayName(for: $0) }
            out.append(TranscriptLine(time: line.time, text: line.text, speaker: speaker).markdown)
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    static func load(from url: URL) throws -> TranscriptDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptDocument.self, from: Data(contentsOf: url))
    }

    func write(jsonTo url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter TranscriptDocumentTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/Recorder/TranscriptDocument.swift Tests/RecorderTests/TranscriptDocumentTests.swift
git commit -m "Add TranscriptDocument as the structured source of truth for transcripts

Stores speaker labels as stable ids plus a separate name map, so renaming a speaker
re-renders the markdown rather than patching it, which makes renames idempotent and
testable. Also records whether the text came from the live stream or a high-quality
pass, and states plainly when no audio was retained."
```

---

### Task 7: Write the sidecar alongside transcript.md

**Files:**
- Modify: `Sources/Recorder/RecorderModel.swift:510-533` (`writeTranscript`), `:628-660` (`composeTranscriptDocument`)
- Modify: `Sources/Recorder/RecordingsLibrary.swift:55-73`

**Interfaces:**
- Consumes: `TranscriptDocument` from Task 6.
- Produces: `RecordingEntry.documentURL: URL?`; `RecorderModel.writeTranscript(document:pending:keepStatus:)`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/RecorderTests/TranscriptDocumentTests.swift`:

```swift
    func testLinesFromTranscriptLinesPreserveSpeakerIdentity() {
        let lines = [
            TranscriptLine(time: 0, text: "hello", speaker: "You"),
            TranscriptLine(time: 4, text: "hi", speaker: "Them"),
            TranscriptLine(time: 8, text: "quiet", speaker: nil),
        ]
        let doc = TranscriptDocument(
            live: lines,
            meetingTitle: nil,
            attendees: [],
            startedAt: Date(timeIntervalSince1970: 0),
            audioName: nil,
            model: "openai_whisper-base"
        )
        XCTAssertEqual(doc.speakerIDs, ["You", "Them"])
        XCTAssertEqual(doc.displayName(for: "You"), "You")
        XCTAssertFalse(doc.isPolished)
        XCTAssertTrue(doc.renderMarkdown().contains("[00:08] quiet"))
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter testLinesFromTranscriptLinesPreserveSpeakerIdentity`
Expected: FAIL to compile, no such initialiser.

- [ ] **Step 3: Add the convenience initialiser**

Append to `TranscriptDocument` in `Sources/Recorder/TranscriptDocument.swift`:

```swift
    init(
        live lines: [TranscriptLine],
        meetingTitle: String?,
        attendees: [String],
        startedAt: Date,
        audioName: String?,
        model: String
    ) {
        self.meetingTitle = meetingTitle
        self.attendees = attendees
        self.startedAt = startedAt
        self.audioName = audioName
        self.model = model
        self.isPolished = false
        self.lines = lines.map {
            StoredLine(time: $0.time, text: $0.text, speakerID: $0.speaker)
        }
        self.speakerNames = Dictionary(
            uniqueKeysWithValues: Set(lines.compactMap(\.speaker)).map { ($0, $0) }
        )
    }
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter TranscriptDocumentTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Route transcript writing through the document**

In `Sources/Recorder/RecorderModel.swift`, delete `composeTranscriptDocument` and
replace `writeTranscript` with:

```swift
    private func writeTranscript(
        document: TranscriptDocument,
        pending: PendingTranscription,
        keepStatus: Bool
    ) {
        let markdownURL = pending.folderURL.appendingPathComponent("transcript.md")
        let jsonURL = pending.folderURL.appendingPathComponent("transcript.json")
        let markdown = document.renderMarkdown()
        do {
            try document.write(jsonTo: jsonURL)
            try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
        } catch {
            transcriptionState = .failed("Could not write the transcript: \(error.localizedDescription)")
            return
        }
        lastTranscriptText = markdown
        lastTranscriptURL = markdownURL
        transcriptionState = .done(markdownURL)
        if !keepStatus {
            statusMessage = "Transcript saved (transcript.md)"
        }
        refreshRecordings()
    }
```

Update the three call sites. `saveAndStop` currently passes `liveResult.body`, a
pre-rendered string; change `LiveTranscriber.LiveSessionResult` to carry the lines
instead:

```swift
    struct LiveSessionResult {
        let lines: [TranscriptLine]
        let complete: Bool

        var isEmpty: Bool { lines.isEmpty }
    }
```

Return `LiveSessionResult(lines: confirmedLines, complete: finalTickComplete)` from
`endSession` and `LiveSessionResult(lines: snapshot, complete: false)` from its early
exits, deleting `transcriptBody` and `body(of:)`. Then in `saveAndStop`:

```swift
                if let liveResult, !liveResult.isEmpty, liveResult.complete {
                    self.writeTranscript(
                        document: TranscriptDocument(
                            live: liveResult.lines,
                            meetingTitle: pending.meetingTitle,
                            attendees: pending.attendees,
                            startedAt: pending.startedAt,
                            audioName: pending.audioURL?.lastPathComponent,
                            model: self.live.loadedModelName ?? self.live.modelName
                        ),
                        pending: pending,
                        keepStatus: mixError != nil
                    )
                }
```

`startTranscription` still receives a markdown body from `transcribeFile`. Wrap it for
now with a single unattributed line so the sidecar is always written:

```swift
                let body = try await self.live.transcribeFile(pending.audioURL!)
                guard !body.isEmpty else { ... }
                var document = TranscriptDocument(
                    live: [TranscriptLine(time: 0, text: body, speaker: nil)],
                    meetingTitle: pending.meetingTitle,
                    attendees: pending.attendees,
                    startedAt: pending.startedAt,
                    audioName: pending.audioURL?.lastPathComponent,
                    model: self.live.loadedModelName ?? self.live.modelName
                )
                document.isPolished = true
                self.writeTranscript(document: document, pending: pending, keepStatus: false)
```

Plan B replaces this wrapper with `PolishPass` returning real structured lines.

- [ ] **Step 6: Surface the sidecar in the library**

In `Sources/Recorder/RecordingsLibrary.swift`, add `let documentURL: URL?` to
`RecordingEntry` and populate it in `recent(limit:)`:

```swift
            let document = url.appendingPathComponent("transcript.json")
            let hasDocument = fm.fileExists(atPath: document.path)
```

passing `documentURL: hasDocument ? document : nil` to the initialiser, and add
`|| hasDocument` to the `guard hasAudio || hasTranscript || hasRaw` condition so a
transcript-only recording is listed.

- [ ] **Step 7: Build, test, smoke**

Run: `swift build 2>&1 | grep -E "error:|Build complete"` then `swift test`
Expected: `Build complete!`, then 34 tests, 4 skipped, 0 failures.

Rebuild the app, record 30 seconds, stop, and confirm the folder now holds both
`transcript.md` and `transcript.json` with matching content.

- [ ] **Step 8: Commit**

```bash
git add Sources/Recorder/TranscriptDocument.swift Sources/Recorder/RecorderModel.swift Sources/Recorder/RecordingsLibrary.swift Sources/Recorder/LiveTranscriber.swift Tests/RecorderTests/TranscriptDocumentTests.swift
git commit -m "Write transcript.json beside transcript.md

The live session now returns structured lines rather than pre-rendered markdown, and
both files are produced from one TranscriptDocument. The sidecar is what makes speaker
renaming possible later, and it also lets the library list a recording that kept no
audio."
```

---

### Task 8: AudioHandlingMode

Pure logic and persistence first, so the mode is fully tested before any capture code
changes.

**Files:**
- Create: `Sources/Recorder/AudioHandlingMode.swift`
- Create: `Tests/RecorderTests/AudioHandlingModeTests.swift`
- Modify: `Sources/Recorder/Preferences.swift`
- Modify: `Sources/Recorder/RecorderModel.swift:40-42, 188`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum AudioHandlingMode: String, CaseIterable, Identifiable` with cases `transcriptOnly`, `keepAudio`, `keepAudioAndPolish`
  - `var id: String`, `var label: String`, `var detail: String`
  - `var retainsAudio: Bool`, `var runsPolishPass: Bool`
  - `func producesNothing(liveTranscriptionEnabled: Bool) -> Bool`
  - `static let `default`: AudioHandlingMode`
  - `Preferences.audioHandlingMode: AudioHandlingMode`
  - `RecorderModel.audioHandlingMode: AudioHandlingMode`

- [ ] **Step 1: Write the failing test**

Create `Tests/RecorderTests/AudioHandlingModeTests.swift`:

```swift
import XCTest
@testable import Recorder

final class AudioHandlingModeTests: XCTestCase {

    func testOnlyKeepAudioModesRetainAudio() {
        XCTAssertFalse(AudioHandlingMode.transcriptOnly.retainsAudio)
        XCTAssertTrue(AudioHandlingMode.keepAudio.retainsAudio)
        XCTAssertTrue(AudioHandlingMode.keepAudioAndPolish.retainsAudio)
    }

    func testOnlyThePolishModeRunsThePolishPass() {
        XCTAssertFalse(AudioHandlingMode.transcriptOnly.runsPolishPass)
        XCTAssertFalse(AudioHandlingMode.keepAudio.runsPolishPass)
        XCTAssertTrue(AudioHandlingMode.keepAudioAndPolish.runsPolishPass)
    }

    func testAPolishPassAlwaysImpliesRetainedAudio() {
        for mode in AudioHandlingMode.allCases where mode.runsPolishPass {
            XCTAssertTrue(mode.retainsAudio, "\(mode) polishes without keeping audio")
        }
    }

    func testTranscriptOnlyWithLiveOffWouldProduceNothing() {
        XCTAssertTrue(AudioHandlingMode.transcriptOnly.producesNothing(liveTranscriptionEnabled: false))
        XCTAssertFalse(AudioHandlingMode.transcriptOnly.producesNothing(liveTranscriptionEnabled: true))
    }

    func testOtherModesAlwaysProduceSomething() {
        for mode in AudioHandlingMode.allCases where mode != .transcriptOnly {
            XCTAssertFalse(mode.producesNothing(liveTranscriptionEnabled: false))
            XCTAssertFalse(mode.producesNothing(liveTranscriptionEnabled: true))
        }
    }

    func testRawValuesAreStableForPersistence() {
        XCTAssertEqual(AudioHandlingMode.transcriptOnly.rawValue, "transcriptOnly")
        XCTAssertEqual(AudioHandlingMode.keepAudio.rawValue, "keepAudio")
        XCTAssertEqual(AudioHandlingMode.keepAudioAndPolish.rawValue, "keepAudioAndPolish")
        XCTAssertEqual(AudioHandlingMode(rawValue: "nonsense"), nil)
    }

    func testDefaultKeepsAudioAndPolishes() {
        XCTAssertEqual(AudioHandlingMode.default, .keepAudioAndPolish)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter AudioHandlingModeTests`
Expected: FAIL to compile, "cannot find type 'AudioHandlingMode' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/Recorder/AudioHandlingMode.swift`:

```swift
import Foundation

/// What a recording is allowed to leave on disk. The high-quality pass needs audio to
/// survive the recording, so choosing it is choosing retention; one control keeps that
/// trade a single unambiguous statement.
enum AudioHandlingMode: String, CaseIterable, Identifiable {
    case transcriptOnly
    case keepAudio
    case keepAudioAndPolish

    var id: String { rawValue }

    static let `default`: AudioHandlingMode = .keepAudioAndPolish

    var label: String {
        switch self {
        case .transcriptOnly: return "Transcript only"
        case .keepAudio: return "Keep audio"
        case .keepAudioAndPolish: return "Keep audio and run a high-quality pass"
        }
    }

    var detail: String {
        switch self {
        case .transcriptOnly:
            return "No audio is ever written to disk. Only transcript.md and transcript.json are saved."
        case .keepAudio:
            return "Saves audio.m4a next to the live transcript."
        case .keepAudioAndPolish:
            return "Saves audio.m4a, then re-transcribes it with the high-quality model and names speakers."
        }
    }

    var retainsAudio: Bool {
        self != .transcriptOnly
    }

    var runsPolishPass: Bool {
        self == .keepAudioAndPolish
    }

    /// True when this mode combined with the live setting would save nothing at all.
    func producesNothing(liveTranscriptionEnabled: Bool) -> Bool {
        self == .transcriptOnly && !liveTranscriptionEnabled
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter AudioHandlingModeTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Persist it and remove autoTranscribe**

In `Sources/Recorder/Preferences.swift`, delete the `autoTranscribe` key and property
and add:

```swift
        static let audioHandling       = "audioHandlingMode"
```

```swift
    /// What a recording may leave on disk. Default keeps audio and polishes it.
    static var audioHandlingMode: AudioHandlingMode {
        get {
            guard let raw = defaults.string(forKey: Key.audioHandling),
                  let mode = AudioHandlingMode(rawValue: raw) else { return .default }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Key.audioHandling) }
    }
```

In `Sources/Recorder/RecorderModel.swift`, replace the `autoTranscribe` property with:

```swift
    /// What this recording may leave on disk.
    var audioHandlingMode: AudioHandlingMode = .default {
        didSet { Preferences.audioHandlingMode = audioHandlingMode }
    }
```

and in `loadPreferences` replace `autoTranscribe = Preferences.autoTranscribe` with
`audioHandlingMode = Preferences.audioHandlingMode`.

At `saveAndStop`, replace `let wantsTranscript = autoTranscribe` with
`let wantsTranscript = liveTranscriptionEnabled || audioHandlingMode.runsPolishPass`.

In `Sources/Recorder/PreferencesView.swift`, delete the "After saving" section that
binds `$model.autoTranscribe`. Task 12 adds the mode picker.

- [ ] **Step 6: Build and test**

Run: `swift build 2>&1 | grep -E "error:|Build complete"` then `swift test`
Expected: `Build complete!`, then 41 tests, 4 skipped, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/Recorder/AudioHandlingMode.swift Sources/Recorder/Preferences.swift Sources/Recorder/RecorderModel.swift Sources/Recorder/PreferencesView.swift Tests/RecorderTests/AudioHandlingModeTests.swift
git commit -m "Add AudioHandlingMode and retire the autoTranscribe preference

One three-way mode replaces a boolean whose meaning was already implied by whether a
transcript gets written. A test pins the invariant that a mode can never run the
high-quality pass without retaining the audio it reads."
```

---

### Task 9: Let both captures record nothing

**Files:**
- Modify: `Sources/Recorder/SystemAudioTap.swift:160` (`start(writingTo:)`)
- Modify: `Sources/Recorder/MicCapture.swift` (`start(writingTo:)`)
- Modify: `Sources/Recorder/Shared.swift:114-178` (`RecordingSession`)
- Create: `Tests/RecorderTests/RecordingSessionTests.swift`
- Modify: `Tests/RecorderTests/LiveTapVerificationTests.swift`

**Interfaces:**
- Consumes: `AudioHandlingMode` from Task 8.
- Produces:
  - `SystemAudioTap.start(writingTo url: URL?) throws`
  - `MicCapture.start(writingTo url: URL?) throws`
  - `RecordingSession` with `let desktopURL: URL?`, `let micURL: URL?`, `let outputURL: URL?`
  - `RecordingSession.create(now: Date, meetingTitle: String?, mode: AudioHandlingMode) throws -> RecordingSession`

- [ ] **Step 1: Write the failing test**

Create `Tests/RecorderTests/RecordingSessionTests.swift`:

```swift
import XCTest
@testable import Recorder

final class RecordingSessionTests: XCTestCase {

    private func cleanUp(_ session: RecordingSession) {
        try? FileManager.default.removeItem(at: session.folderURL)
    }

    func testKeepAudioModesGetAudioPaths() throws {
        for mode in [AudioHandlingMode.keepAudio, .keepAudioAndPolish] {
            let session = try RecordingSession.create(
                now: Date(), meetingTitle: "PathTest-\(mode.rawValue)", mode: mode
            )
            defer { cleanUp(session) }
            XCTAssertNotNil(session.desktopURL)
            XCTAssertNotNil(session.micURL)
            XCTAssertNotNil(session.outputURL)
        }
    }

    func testTranscriptOnlyHasNoAudioPathsButStillHasAFolder() throws {
        let session = try RecordingSession.create(
            now: Date(), meetingTitle: "PathTestTranscriptOnly", mode: .transcriptOnly
        )
        defer { cleanUp(session) }
        XCTAssertNil(session.desktopURL)
        XCTAssertNil(session.micURL)
        XCTAssertNil(session.outputURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: session.folderURL.path),
            "the folder must exist so the transcript has a home"
        )
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter RecordingSessionTests`
Expected: FAIL to compile, `create` has no `mode:` parameter.

- [ ] **Step 3: Make the session's audio paths optional**

In `Sources/Recorder/Shared.swift`, change the three audio properties to optionals and
the factory signature to `create(now: Date, meetingTitle: String?, mode: AudioHandlingMode)`.
At the end, build the result as:

```swift
        return RecordingSession(
            folderURL: folderURL,
            desktopURL: mode.retainsAudio ? folderURL.appendingPathComponent("desktop.caf") : nil,
            micURL: mode.retainsAudio ? folderURL.appendingPathComponent("mic.caf") : nil,
            outputURL: mode.retainsAudio ? folderURL.appendingPathComponent("audio.m4a") : nil,
            startedAt: now,
            meetingTitle: meetingTitle
        )
```

- [ ] **Step 4: Accept a nil destination in the tap**

In `Sources/Recorder/SystemAudioTap.swift`, change `func start(writingTo url: URL)` to
`func start(writingTo url: URL?)` and guard the file creation:

```swift
        if let url {
            do {
                let f = try AVAudioFile(
                    forWriting: url,
                    settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: writeFmt.sampleRate,
                        AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsNonInterleaved: false,
                        AVLinearPCMIsBigEndianKey: false
                    ],
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
                self.file = f
            } catch {
                destroyTapAndAggregateLocked()
                throw TapError.fileOpenFailed(error.localizedDescription)
            }
        } else {
            self.file = nil
        }
```

`startWriterThread` takes `file: AVAudioFile` today. Change it to `file: AVAudioFile?`
and guard the write inside the thread body so the ring is still drained (which is what
keeps `onSamples` flowing and `capturedFrames` accurate) but nothing is written:

```swift
                    if let file {
                        try file.write(from: buffer)
                    }
```

Update the call site to `startWriterThread(file: self.file, writeFormat: writeFmt, ring: newRing)`.

- [ ] **Step 5: Accept a nil destination in the mic**

In `Sources/Recorder/MicCapture.swift`, change `func start(writingTo url: URL)` to
`func start(writingTo url: URL?)`, and make the file optional:

```swift
        var outFile: AVAudioFile?
        if let url {
            do {
                outFile = try AVAudioFile(
                    forWriting: url,
                    settings: monoFormat.settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
            } catch {
                throw MicError.couldNotCreateFile(url, underlying: error)
            }
        }
```

In `write(_:hostTime:)`, the `guard ... let file = self.file` currently makes a nil
file mean "not running", which would stop `onSamples`. Split the two concerns:

```swift
        let wrote: Bool = lock.withLock {
            guard self.running, !self.paused else { return false }
            if let file = self.file {
                do {
                    try file.write(from: writeBuffer)
                } catch {
                    self.running = false
                    self.file = nil
                    self.onFatalError?(error)
                    return false
                }
            }
            if self.firstHostTime == nil {
                self.firstHostTime = hostTime
            }
            self.frameCount += AVAudioFramePosition(writeBuffer.frameLength)
            return true
        }
```

- [ ] **Step 6: Add a live check that nothing lands on disk**

Append to `Tests/RecorderTests/LiveTapVerificationTests.swift`:

```swift
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
```

- [ ] **Step 7: Update the one existing caller and build**

`RecorderModel.startRecording` calls `RecordingSession.create(now:meetingTitle:)` and
`tap.start(writingTo: session.desktopURL)`. Task 10 rewrites that method; for now pass
`mode: audioHandlingMode` to `create` so the build succeeds.

Run: `swift build 2>&1 | grep -E "error:|Build complete"` then `swift test`
Expected: `Build complete!`, then 44 tests, 5 skipped, 0 failures.

Run: `RECORDER_LIVE_TAP=1 swift test --filter LiveTapVerificationTests`
Expected: PASS, 3 tests.

- [ ] **Step 8: Commit**

```bash
git add Sources/Recorder/SystemAudioTap.swift Sources/Recorder/MicCapture.swift Sources/Recorder/Shared.swift Sources/Recorder/RecorderModel.swift Tests/RecorderTests/RecordingSessionTests.swift Tests/RecorderTests/LiveTapVerificationTests.swift
git commit -m "Let both captures run without a destination file

A nil URL means no AVAudioFile is ever created, while the ring buffer, writer thread,
meters and onSamples all keep working. Because the handle is never opened, a crash
mid-recording cannot leak audio, which a delete-afterwards design could not promise.
A live check asserts an empty directory after recording with no destination."
```

---

### Task 10: Wire the modes through RecorderModel

**Files:**
- Modify: `Sources/Recorder/RecorderModel.swift:197-279` (`startRecording`), `:298-389` (`saveAndStop`)
- Modify: `Sources/Recorder/LiveTranscriber.swift`
- Modify: `Tests/RecorderTests/SampleInboxSkewTests.swift` (no change expected; run to confirm)

**Interfaces:**
- Consumes: `AudioHandlingMode`, optional session URLs, `LiveTranscriber.maxWindowSamples`.
- Produces: `LiveTranscriber.transcriptOnlyWindowSamples` static constant; `RecorderModel.activeMode`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/RecorderTests/AudioHandlingModeTests.swift`:

```swift
    func testTranscriptOnlyUsesTheShorterLiveWindow() {
        XCTAssertEqual(
            LiveTranscriber.windowCap(for: .transcriptOnly),
            90 * Int(SampleInbox.targetRate)
        )
        for mode in [AudioHandlingMode.keepAudio, .keepAudioAndPolish] {
            XCTAssertEqual(
                LiveTranscriber.windowCap(for: mode),
                15 * 60 * Int(SampleInbox.targetRate)
            )
        }
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter testTranscriptOnlyUsesTheShorterLiveWindow`
Expected: FAIL to compile, no `windowCap(for:)`.

- [ ] **Step 3: Add the window cap rule and zeroing**

In `Sources/Recorder/LiveTranscriber.swift` add:

```swift
    /// In transcript-only mode this buffer is the only place audio exists, so it is
    /// bounded far more tightly than when the audio is on disk anyway.
    static func windowCap(for mode: AudioHandlingMode) -> Int {
        mode.retainsAudio
            ? 15 * 60 * Int(SampleInbox.targetRate)
            : 90 * Int(SampleInbox.targetRate)
    }
```

Add a helper that overwrites buffered audio before releasing it, and call it wherever
`windowSamples` is dropped (the overflow branch in `tick`, and in `cancelSession` and
the final tick):

```swift
    private func discardWindow(upTo count: Int) {
        guard count > 0 else { return }
        for i in 0..<min(count, windowSamples.count) {
            windowSamples[i] = 0
        }
        windowSamples.removeFirst(min(count, windowSamples.count))
    }

    private func clearWindow() {
        for i in windowSamples.indices { windowSamples[i] = 0 }
        windowSamples.removeAll(keepingCapacity: false)
    }
```

Replace `windowSamples.removeFirst(overflow)` with `discardWindow(upTo: overflow)`,
and `windowSamples.removeAll()` / `windowSamples = []` with `clearWindow()`.

- [ ] **Step 4: Run tests**

Run: `swift test --filter AudioHandlingModeTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Apply the mode when recording starts**

In `startRecording`, after creating the session:

```swift
        let mode = audioHandlingMode
        guard !mode.producesNothing(liveTranscriptionEnabled: liveTranscriptionEnabled) else {
            statusMessage = "Transcript-only mode needs live transcription switched on, otherwise nothing would be saved."
            return
        }
        activeMode = mode
        live.live.maxWindowSamples = LiveTranscriber.windowCap(for: mode)
```

and change `RecordingSession.create(now: now, meetingTitle: meeting?.title)` to pass
`mode: mode`. The `tap.start(writingTo: session.desktopURL)` and
`mic.start(writingTo: session.micURL)` calls now pass optionals and need no change.

Add the stored property next to the other non-observed state:

```swift
    @ObservationIgnored private var activeMode: AudioHandlingMode = .default
```

- [ ] **Step 6: Skip the mixer when there is no audio**

In `saveAndStop`, guard the whole mix and polish block. Replace the
`Task.detached(priority: .utility)` body's opening with:

```swift
        let mode = activeMode
        guard let outputURL = session.outputURL,
              let desktopURL = session.desktopURL,
              let micURL = session.micURL else {
            transcriptionState = .running
            Task { [weak self] in
                guard let self else { return }
                let liveResult = await liveTask?.value
                guard let liveResult, !liveResult.isEmpty else {
                    self.transcriptionState = .failed("Nothing was transcribed, and no audio was kept.")
                    self.statusMessage = "Nothing to save"
                    return
                }
                self.writeTranscript(
                    document: TranscriptDocument(
                        live: liveResult.lines,
                        meetingTitle: meetingTitle,
                        attendees: attendees,
                        startedAt: startedAt,
                        audioName: nil,
                        model: self.live.loadedModelName ?? self.live.modelName
                    ),
                    pending: pending,
                    keepStatus: false
                )
                self.statusMessage = "Transcript saved, no audio kept"
            }
            currentSession = nil
            activeMeeting = nil
            silenceMonitor = nil
            return
        }
```

`PendingTranscription.audioURL` becomes `URL?` to match. Keep the existing mix path
below unchanged for the two keep-audio modes, and gate the offline fallback on
`mode.runsPolishPass` so `keepAudio` never spends time re-transcribing:

```swift
                } else if mixError == nil, mode.runsPolishPass {
                    self.startTranscription(pending)
```

- [ ] **Step 7: Build, test, and verify all three modes by hand**

Run: `swift build 2>&1 | grep -E "error:|Build complete"` then `swift test`
Expected: `Build complete!`, then 45 tests, 5 skipped, 0 failures.

Rebuild the app. For each mode, record 30 seconds and check the folder:

| Mode | Expected folder contents |
|---|---|
| transcriptOnly | `transcript.md`, `transcript.json` only |
| keepAudio | plus `audio.m4a`, `desktop.caf`, `mic.caf` |
| keepAudioAndPolish | same as keepAudio, transcript marked as the high-quality pass |

- [ ] **Step 8: Commit**

```bash
git add Sources/Recorder/RecorderModel.swift Sources/Recorder/LiveTranscriber.swift Tests/RecorderTests/AudioHandlingModeTests.swift
git commit -m "Honour the audio-handling mode end to end

Transcript-only recordings never create a session audio path, never run the mixer, and
cap the live buffer at 90 seconds instead of 15 minutes, because in that mode the
buffer is the only place audio exists. Dropped and cleared buffers are overwritten
before release, since the no-retention claim rests on exactly that. keepAudio no
longer spends time re-transcribing a file the user did not ask to polish."
```

---

### Task 11: Mid-recording downgrade

**Files:**
- Modify: `Sources/Recorder/SystemAudioTap.swift`
- Modify: `Sources/Recorder/MicCapture.swift`
- Modify: `Sources/Recorder/RecorderModel.swift`

**Interfaces:**
- Consumes: everything from Tasks 9 and 10.
- Produces: `SystemAudioTap.stopWriting()`, `MicCapture.stopWriting()`, `RecorderModel.changeAudioHandling(to:) -> Bool`.

- [ ] **Step 1: Add stopWriting to the tap**

In `Sources/Recorder/SystemAudioTap.swift`:

```swift
    /// Close the destination file while capture continues. Meters, `onSamples` and the
    /// ring keep running; only the disk write stops.
    func stopWriting() {
        lock.lock()
        defer { lock.unlock() }
        file = nil
    }
```

The writer thread holds its own strong reference for its lifetime, so clearing
`self.file` alone will not stop it. Change the thread body's captured file to a
lock-protected read instead: replace the captured `file` parameter use with
`let target = self.lockedFile()` inside the drain loop, where

```swift
    private func lockedFile() -> AVAudioFile? {
        lock.withLock { file }
    }
```

and write only `if let target { try target.write(from: buffer) }`.

- [ ] **Step 2: Add stopWriting to the mic**

```swift
    /// Close the destination file while capture continues.
    func stopWriting() {
        lock.withLock { self.file = nil }
    }
```

The mic's `write` already treats a nil file as "capture but do not persist" after
Task 9, so nothing else changes.

- [ ] **Step 3: Add the model-level switch**

In `Sources/Recorder/RecorderModel.swift`:

```swift
    /// Change the audio-handling mode for the recording in progress. Downgrading to
    /// transcript-only closes and deletes the partial audio. Upgrading is refused,
    /// because the earlier audio no longer exists. Returns whether the change applied.
    @discardableResult
    func changeAudioHandling(to mode: AudioHandlingMode) -> Bool {
        audioHandlingMode = mode
        guard state != .idle, let session = currentSession else { return true }

        if mode.retainsAudio && !activeMode.retainsAudio {
            statusMessage = "Cannot start keeping audio mid-recording: the earlier audio was never saved."
            return false
        }

        if !mode.retainsAudio && activeMode.retainsAudio {
            tap.stopWriting()
            mic.stopWriting()
            for url in [session.desktopURL, session.micURL, session.outputURL].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: url)
            }
            statusMessage = "Switched to transcript only, audio so far deleted"
        }

        activeMode = mode
        live.live.maxWindowSamples = LiveTranscriber.windowCap(for: mode)
        return true
    }
```

`saveAndStop` reads `session.outputURL` to decide whether to mix. After a downgrade the
files are gone but the URLs are not nil, so guard on `activeMode.retainsAudio` as well:
change the guard to `guard activeMode.retainsAudio, let outputURL = session.outputURL, ...`.

- [ ] **Step 4: Build and test**

Run: `swift build 2>&1 | grep -E "error:|Build complete"` then `swift test`
Expected: `Build complete!`, then 45 tests, 5 skipped, 0 failures.

- [ ] **Step 5: Verify by hand**

Start a recording in `keepAudioAndPolish`, wait 15 seconds, switch to transcript-only,
wait 15 seconds, then stop. Confirm the folder holds only `transcript.md` and
`transcript.json`, that the transcript covers the whole 30 seconds, and that switching
back mid-recording is refused with a message.

- [ ] **Step 6: Commit**

```bash
git add Sources/Recorder/SystemAudioTap.swift Sources/Recorder/MicCapture.swift Sources/Recorder/RecorderModel.swift
git commit -m "Allow downgrading to transcript-only mid-recording

stopWriting closes the destination file while capture, meters and the live transcript
carry on, then the partial audio is deleted. Upgrading mid-recording is refused rather
than producing a file that silently begins part way through the meeting. The writer
thread now reads the file under the lock instead of holding it for its lifetime, so
closing it actually takes effect."
```

---

### Task 12: Surface the mode in Preferences and the panel

**Files:**
- Modify: `Sources/Recorder/PreferencesView.swift`
- Modify: `Sources/Recorder/RecorderPanel.swift:30-45`

**Interfaces:**
- Consumes: `AudioHandlingMode`, `RecorderModel.changeAudioHandling(to:)`.
- Produces: no new API.

- [ ] **Step 1: Add the Recording tab to Preferences**

In `Sources/Recorder/PreferencesView.swift`, add to the `TabView`:

```swift
            RecordingPreferences()
                .tabItem { Label("Recording", systemImage: "waveform") }
```

and define it:

```swift
private struct RecordingPreferences: View {
    @Environment(RecorderModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Audio handling", selection: $model.audioHandlingMode) {
                    ForEach(AudioHandlingMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(model.audioHandlingMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.audioHandlingMode.producesNothing(liveTranscriptionEnabled: model.liveTranscriptionEnabled) {
                    Label(
                        "Transcript-only mode needs live transcription switched on, or nothing would be saved.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            } header: {
                Text("Audio handling")
            } footer: {
                Text("Transcript-only never writes audio to disk, not even temporarily, so a crash cannot leave a recording behind. The high-quality pass needs the audio file, so it is only available when audio is kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
```

Raise the `TabView` frame from `height: 560` to `height: 620` so the third tab is not
clipped.

- [ ] **Step 2: Add the panel badge**

In `Sources/Recorder/RecorderPanel.swift`, inside the `controls` section, add a chip
that shows the mode and lets it change:

```swift
    private var audioHandlingChip: some View {
        Menu {
            ForEach(AudioHandlingMode.allCases) { mode in
                Button {
                    model.changeAudioHandling(to: mode)
                } label: {
                    if mode == model.audioHandlingMode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
        } label: {
            Label(
                model.audioHandlingMode.retainsAudio ? "Audio kept" : "Transcript only",
                systemImage: model.audioHandlingMode.retainsAudio ? "waveform.circle" : "eye.slash.circle"
            )
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
```

and render it below the record controls. While recording in transcript-only mode, add
a persistent badge:

```swift
            if model.state != .idle && !model.audioHandlingMode.retainsAudio {
                Label("Transcript only, no audio saved", systemImage: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 3: Build, test, and check the UI**

Run: `swift build 2>&1 | grep -E "error:|Build complete"` then `swift test`
Expected: `Build complete!`, then 45 tests, 5 skipped, 0 failures.

Rebuild the app and confirm: the Recording tab shows three radio options with the
warning appearing only for the invalid combination; the panel chip reflects and changes
the mode; the badge appears while recording transcript-only.

- [ ] **Step 4: Commit**

```bash
git add Sources/Recorder/PreferencesView.swift Sources/Recorder/RecorderPanel.swift
git commit -m "Add the audio-handling mode to Preferences and the panel

A Recording tab carries the three-way choice with a footer stating what each mode
leaves on disk, and warns about the one combination that would save nothing. The panel
gains a chip to change the mode before or during a recording, plus a persistent badge
while recording with no audio retained, so the guarantee is visible at the moment it
matters."
```

---

## Self-Review

**Spec coverage.** Architecture units: `SampleInbox` Task 1, `TranscriptLine` Task 2,
`ModelHost` Task 3, `WhisperModelStorage` Task 4, `LiveTranscriber` Task 5,
`TranscriptDocument` Tasks 6 and 7. `PolishPass`, `SpeakerProfileStore` and
`AudioChannelLoader` are Plan B by design. Mode matrix Task 8, optional capture URLs
Task 9, mixer skip and the 90 second cap and zeroing Task 10, mid-recording downgrade
and upgrade refusal Task 11, UI Task 12. The refused live-off plus transcript-only
combination is enforced in Task 10 and surfaced in Tasks 8 and 12. `autoTranscribe`
removal is Task 8.

**Deliberate Plan A gaps**, all owned by Plan B: the second model picker, the polish
pass itself, speaker naming and profiles, and the rename UI. Task 7 leaves a documented
placeholder wrapper around `transcribeFile` that Plan B replaces.

**Type consistency.** `ModelLoadState` is used unqualified in `LocalTranscription` and
`PreferencesView`. `LiveSessionResult` carries `lines` plus `complete` from Task 7
onward, and Task 10 relies on `isEmpty`. `PendingTranscription.audioURL` becomes `URL?`
in Task 10, matching the optional `session.outputURL` from Task 9.
`LiveTranscriber.windowCap(for:)` is defined in Task 10 and used in Tasks 10 and 11.
`RecorderModel.activeMode` is introduced in Task 10 and read in Tasks 10 and 11.
`live.live.maxWindowSamples` reflects that `RecorderModel.live` is the engine and
`engine.live` is the transcriber; rename `RecorderModel.live` to `engine` in Task 5 if
that reads badly, updating the panel's `model.live` references in the same task.
