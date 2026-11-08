# Live Engine Picker and Debug View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pick Apple, Nemotron or Parakeet as the live transcription engine, and show an optional debug view (drawer, pop-out, `debug.json`) that explains memory fit, text lag, audio held and why a recording stopped.

**Architecture:** One `LiveSpeechEngine` protocol driven by `LocalTranscriptionEngine`, with three implementations fed by the existing `StreamingAudioInput` and `StreamingInputPump`. FluidAudio engines receive audio through a bounded 10 s handoff. A `DiagnosticsRecorder` samples system and engine metrics once per second from Record press while debug is on, and writes `debug.json` at save.

**Tech Stack:** Swift 6.2 toolchain (target in Swift 5 language mode), SwiftUI, AppKit `NSPanel`, Swift Charts, Speech framework (`SpeechAnalyzer`), FluidAudio 0.18.0, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-08-live-engine-picker-and-debug-design.md`

## Global Constraints

- Work on branch `model-picker` in `/Users/christopherjones/projects/cjonesde/recorder-apple`.
- macOS 26 minimum, unchanged in `Package.swift` and `Info.plist`.
- `Package.swift` tools-version 6.2; FluidAudio `.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.0", traits: [])`.
- No code comments in new or changed code. Explanations go in commit messages.
- No em dashes or `--` in UI copy, docs or commit messages.
- Transcript-only mode writes no audio file for any engine; `debug.json` never contains audio or transcript text.
- Apple keeps its bounds exactly: 0.5 s per source in `StreamingAudioInput`, 4 queued 100 ms chunks, 10 s finalization watchdog.
- Nemotron and Parakeet: handoff cap 10 s of audio, finalization watchdog 30 s.
- Nemotron profile: 560 ms chunks, Neural Engine (`.cpuAndNeuralEngine`), blank-span recovery on.
- Parakeet profile: `AsrModelVersion.ultra`, `SlidingWindowAsrConfig.streaming`.
- Nemotron line split: pause of at least 0.8 s, or a token ending in `.`, `?` or `!`.
- One live engine resident at a time; the live engine is unloaded before Whisper loads for the polish pass.
- Debug sampling interval 1 s, starts at Record press, phases `preparing`, `recording`, `finishing`; no sampling while debug is off.
- Every debug value carries a quality: measured, estimated or unknown.
- Full suite stays green: `swift test -c release -j 4` (130 tests, 16 opt-in skipped at `9746a80`).

## Review Focus

1. Selecting Nemotron or Parakeet offline before its model was ever downloaded: preparation fails with a readable message, the app stays idle, no capture device opens. Pinned in Task 3.
2. Cancelling during a long first-time compile: no capture opens, and the next Record works. Pinned in Task 3.
3. A line confirmed long after it was spoken (Parakeet confirms after 10 s and may lag 10 s more): it still gets a You/Them label. Pinned in Task 5.
4. Debug on, transcript-only, nothing recognized (silent room): no transcript is saved, but `debug.json` is, so the failed test can be diagnosed. Pinned in Task 10.
5. The Apple speech service process cannot be found or read: its memory shows unknown, never Recorder's own number. Pinned in Task 9.

---

### Task 1: Named safety stops

Replace the single `StreamingSpeechError.inputOverrun` with reasons that survive to the panel, the transcript marker and (later) the report.

**Files:**
- Create: `Sources/Recorder/LiveStopReason.swift`
- Modify: `Sources/Recorder/StreamingAudioInput.swift` (ingest/drain overrun paths, `StreamingSpeechError`)
- Modify: `Sources/Recorder/SystemAudioTap.swift` (writer thread `ring.totalDropped` report)
- Modify: `Sources/Recorder/AppleLiveTranscriber.swift` (yield `.dropped`, analysis error, watchdog, `fail`)
- Test: `Tests/RecorderTests/LiveStopReasonTests.swift`, update `Tests/RecorderTests/AppleStreamingTests.swift`

**Interfaces:**
- Produces:
  - `enum LiveStopReason: String, Codable, Sendable, CaseIterable { case desktopAudioAged, micAudioAged, handoffFull, engineQueueFull, engineFellBehind, desktopRingOverflow, engineError, finalizationTimedOut }` with `var message: String`.
  - `struct LiveStopError: LocalizedError, Equatable { let reason: LiveStopReason; let detail: String? }`; `errorDescription` is `reason.message` plus `detail` when present.
  - `AppleLiveTranscriber.stopReason: LiveStopReason?` set with `failureMessage`.
  - `StreamingSpeechError` keeps `unavailableLanguage` and `unsupportedFormat`; `inputOverrun` is removed.

- [ ] **Step 1: Write the failing tests**

```swift
func testDesktopAgeLimitNamesTheDesktopChannel() throws {
    let inbox = StreamingAudioInput()
    inbox.begin(format: format)
    feed(inbox, .desktop, value: 0.4, count: 8001)
    XCTAssertThrowsError(try inbox.drain()) { error in
        XCTAssertEqual((error as? LiveStopError)?.reason, .handoffFull)
    }
}

func testEveryReasonHasDistinctUserMessage() {
    let messages = LiveStopReason.allCases.map(\.message)
    XCTAssertEqual(Set(messages).count, messages.count)
    XCTAssertFalse(messages.contains { $0.contains("\u{2014}") })
}

@MainActor
func testFailureCarriesReasonIntoIncompleteMarker() async {
    var text = StreamingTranscript()
    text.markIncomplete(LiveStopError(reason: .engineQueueFull, detail: nil).localizedDescription)
    XCTAssertTrue(text.lines.last!.text.contains(LiveStopReason.engineQueueFull.message))
}
```

Also add an age test: ingest 1600 desktop frames, wait 0.6 s with `Thread.sleep`, drain, expect `.desktopAudioAged`; same for mic with `.micAudioAged`.

- [ ] **Step 2: Run to verify failure**

Run: `swift test -c release --filter 'LiveStopReasonTests|AppleStreamingTests'`
Expected: FAIL, `LiveStopError` not found.

- [ ] **Step 3: Implement.** `StreamingAudioInput` stores `overrunReason: LiveStopReason?` instead of `overrun: Bool`; the capacity check sets `.handoffFull`, the age checks set `.desktopAudioAged` or `.micAudioAged` by channel index. `SystemAudioTap` reports `LiveStopError(reason: .desktopRingOverflow, detail: nil)`. In `AppleLiveTranscriber`, the yield failure throws `.engineQueueFull`, the watchdog uses `.finalizationTimedOut`, and other thrown errors are wrapped as `.engineError` with `detail: error.localizedDescription`. Message copy is the implementer's, for example "Desktop audio waited longer than 0.5 s".

- [ ] **Step 4: Run tests**

Run: `swift test -c release -j 4`
Expected: all pass, 0 failures.

- [ ] **Step 5: Commit** `git commit -m "Name each live transcription safety stop"`

---

### Task 2: Engine choice, debug toggle and transcript header

**Files:**
- Create: `Sources/Recorder/LiveEngineKind.swift`
- Modify: `Sources/Recorder/Preferences.swift` (keys `liveEngine`, `showDebugInfo`)
- Modify: `Sources/Recorder/RecorderModel.swift:29-84` (observable mirrors, lock), `:742-790` (`writeLiveTranscript` model string)
- Modify: `Sources/Recorder/TranscriptDocument.swift` (field `liveEngine`, header)
- Test: `Tests/RecorderTests/LiveEngineKindTests.swift`, `Tests/RecorderTests/TranscriptDocumentTests.swift`

**Interfaces:**
- Produces:
  - `enum LiveEngineKind: String, Codable, CaseIterable, Sendable { case apple, nemotron, parakeet }` with `label` ("Apple", "Nemotron", "Parakeet"), `usesLanguagePicker: Bool` (true only for `.apple`), `static let default = .apple`.
  - `Preferences.liveEngine: LiveEngineKind` (unknown stored value falls back to `.apple`), `Preferences.showDebugInfo: Bool` (default false).
  - `RecorderModel.liveEngine: LiveEngineKind` and `RecorderModel.showDebugInfo: Bool`, persisted on `didSet`; `RecorderModel.canChangeLiveEngine: Bool` true only when `state == .idle` and `transcriptionState != .running`.
  - `TranscriptDocument.liveEngine: String?` (optional, so older files decode).

- [ ] **Step 1: Write the failing tests**

```swift
func testUnknownStoredEngineFallsBackToApple() {
    UserDefaults.standard.set("whisper", forKey: "liveEngine")
    XCTAssertEqual(Preferences.liveEngine, .apple)
}

func testOldTranscriptJSONWithoutLiveEngineStillLoads() throws {
    let json = #"{"attendees":[],"isPolished":false,"lines":[],"model":"openai_whisper-base","speakerNames":{},"startedAt":"2026-08-20T10:00:00Z"}"#
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    try json.write(to: url, atomically: true, encoding: .utf8)
    XCTAssertNil(try TranscriptDocument.load(from: url).liveEngine)
}

func testLiveHeaderNamesTheEngineNotWhisperKit() {
    let doc = TranscriptDocument(live: [], meetingTitle: nil, attendees: [], startedAt: .now,
                                 audioName: nil, model: "Parakeet Ultra")
    let md = doc.renderMarkdown()
    XCTAssertTrue(md.contains("- **Engine:** Parakeet Ultra (on-device)"))
    XCTAssertFalse(md.contains("WhisperKit"))
}

func testPolishedHeaderNamesWhisperAndTheLiveEngine() {
    var doc = TranscriptDocument(live: [], meetingTitle: nil, attendees: [], startedAt: .now,
                                 audioName: "audio.m4a", model: "openai_whisper-base")
    doc.isPolished = true
    doc.liveEngine = "Nemotron 3.5 streaming"
    let md = doc.renderMarkdown()
    XCTAssertTrue(md.contains("- **Model:** WhisperKit `openai_whisper-base` (on-device)"))
    XCTAssertTrue(md.contains("- **Live engine:** Nemotron 3.5 streaming"))
}

@MainActor
func testEngineCannotChangeWhileRecordingOrFinishing() {
    let model = RecorderModel()
    for state in [RecorderState.preparing, .recording, .paused, .finishing] {
        model.state = state
        XCTAssertFalse(model.canChangeLiveEngine, "\(state)")
    }
    model.state = .idle
    XCTAssertTrue(model.canChangeLiveEngine)
}
```

Clear the two new defaults keys in `tearDown`.

- [ ] **Step 2: Run to verify failure**

Run: `swift test -c release --filter 'LiveEngineKindTests|TranscriptDocumentTests'`
Expected: FAIL, `LiveEngineKind` not found.

- [ ] **Step 3: Implement.** Live header line is `- **Engine:** <model> (on-device)`; polished keeps the WhisperKit line and adds `- **Live engine:** <liveEngine>` when set. `writeLiveTranscript` keeps passing the engine's display string as `model` (Task 3 supplies it from the engine).

- [ ] **Step 4: Run tests**

Run: `swift test -c release -j 4`
Expected: all pass.

- [ ] **Step 5: Commit** `git commit -m "Persist the live engine choice and name it in transcripts"`

---

### Task 3: Live engine protocol, Apple as the first implementation

**Files:**
- Create: `Sources/Recorder/LiveSpeechEngine.swift`
- Modify: `Sources/Recorder/AppleLiveTranscriber.swift` (conform; split `start(language:)` into `prepare` + `startSession`)
- Modify: `Sources/Recorder/LocalTranscription.swift:74-125` (hold `any LiveSpeechEngine`, `select(_:)`)
- Modify: `Sources/Recorder/RecorderModel.swift:230-260` (`startRecording` prepares the selected engine), `:194-204` (wiring uses `live.engine`)
- Test: `Tests/RecorderTests/LiveEngineSelectionTests.swift` with a `FakeLiveEngine` in the same file

**Interfaces:**
- Consumes: `LiveStopReason`, `LiveStopError` (Task 1); `LiveEngineKind` (Task 2).
- Produces:

```swift
struct LiveSessionResult { let lines: [TranscriptLine]; let complete: Bool; let stopReason: LiveStopReason?; var isEmpty: Bool }
enum MetricQuality: String, Codable, Sendable { case measured, estimated, unknown }
struct DiagnosticRow: Codable, Equatable, Sendable { let label: String; let value: String; let quality: MetricQuality }
struct PreparationInfo: Codable, Equatable, Sendable { let loadSeconds: Double; let firstLoad: Bool; let modelBytesOnDisk: Int64?; let computeUnits: String }
struct EngineDiagnostics: Equatable, Sendable {
    let submittedThroughSeconds: Double
    let latestProvisionalEnd: Double?
    let latestFinalEnd: Double?
    let heldAudioSeconds: Double?
    let heldAudioQuality: MetricQuality
    let rows: [DiagnosticRow]
}

@MainActor protocol LiveSpeechEngine: AnyObject {
    var kind: LiveEngineKind { get }
    var displayName: String { get }
    var isLoaded: Bool { get }
    var finalizationTimeout: Duration { get }
    var confirmedLines: [TranscriptLine] { get }
    var hypothesis: String { get }
    var revision: Int { get }
    var isSessionActive: Bool { get }
    var failureMessage: String? { get }
    var stopReason: LiveStopReason? { get }
    var labelSpeakers: Bool { get set }
    var onFailure: (() -> Void)? { get set }
    nonisolated var inbox: StreamingAudioInput { get }
    func prepare(language: String, progress: @escaping @Sendable (Double?) -> Void) async throws -> PreparationInfo
    func startSession() throws
    func endSession() async -> LiveSessionResult
    func cancelSession()
    func captureFailed(_ error: Error)
    func diagnostics() -> EngineDiagnostics
    func unload() async
}
```

  - `LocalTranscriptionEngine.engine: any LiveSpeechEngine` (replaces `live`), `func select(_ kind: LiveEngineKind) async` (unloads the current engine when the kind differs, then constructs the new one), `var lastPreparation: PreparationInfo?`.
  - `LocalTranscriptionEngine.beginSession(language:progress:)` calls `prepare` then `startSession`.
  - Apple: `displayName` is `"Apple SpeechTranscriber (\(localeIdentifier))"`, `finalizationTimeout` `.seconds(10)`, `heldAudioQuality` `.measured` for the app side with a row "Inside Apple" value "unknown" quality `.unknown`.
  - Apple's `StreamingTranscript` gains `var latestProvisionalEnd: Double?` and `var finalEnd: Double` read access, used by `diagnostics()`.

Because `inbox` is per engine, `RecorderModel.configureCaptures()` must route `onSamples` through a lock-guarded reference that `select(_:)` swaps (`LiveInboxRouter` with `func set(_ inbox: StreamingAudioInput?)` and `func ingest(...)`, in `LiveSpeechEngine.swift`).

- [ ] **Step 1: Write the failing tests** (FakeLiveEngine: configurable `prepareError`, `prepareDelay`, counts `startSession` and `unload` calls)

```swift
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
```

`RecorderModel(engineFactory:)` is a test seam defaulting to the real factory. `trashAndStop()` is the existing cancel path during preparation (it cancels `startupTask`). The real-capture variant of the last test stays out of unit tests (no capture is opened because preparation never completes).

- [ ] **Step 2: Run to verify failure**

Run: `swift test -c release --filter LiveEngineSelectionTests`
Expected: FAIL, `LiveSpeechEngine` not found.

- [ ] **Step 3: Implement** the protocol, the router, Apple conformance and the `RecorderModel` changes. The preparing status reads "Preparing <label>…" and appends a percentage when progress is non-nil.

- [ ] **Step 4: Run the full suite and the Apple opt-in checks**

Run: `swift test -c release -j 4`
Expected: all pass.
Run: `RECORDER_LIVE_MODES=1 swift test -c release --filter 'LiveRecordingStaysUpTests|ModeMatrixIntegrationTests'`
Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit** `git commit -m "Drive live transcription through a LiveSpeechEngine protocol"`

---

### Task 4: FluidAudio dependency and retention audit (gate)

**Files:**
- Modify: `Package.swift` (tools-version 6.2, FluidAudio product on the `Recorder` target)
- Create: `docs/live-engines.md`

- [ ] **Step 1: Add the dependency** exactly as in Global Constraints, product `.product(name: "FluidAudio", package: "FluidAudio")`.

- [ ] **Step 2: Build**

Run: `swift build -c release`
Expected: `Build complete!`

- [ ] **Step 3: Audit retention in `.build/checkouts/FluidAudio` at 0.18.0.** Answer, with file and line references, in `docs/live-engines.md`:
  - Does `StreamingNemotronMultilingualAsrManager` compact consumed samples, at what size, and how much does blank-span recovery retain?
  - Does `SlidingWindowAsrManager` drop samples behind its window, or keep everything passed to `streamAudio`?
  - How is recovery switched on (the benchmark used `setenv("FLUIDAUDIO_DISABLE_BLANK_RESCUE", "0", 1)`)? Is there an API instead?
  - Which stream or callback delivers Parakeet updates (`SlidingWindowTranscriptionUpdate`, `isConfirmed`, `tokenTimings`) and what `AudioSource` to pass to `startStreaming` when feeding `streamAudio` directly?
  - How are token texts in Nemotron `getTokenTimings()` joined into words (sentencepiece `▁` or spaces)?

- [ ] **Step 4: Gate.** If either manager keeps all audio it was given, stop here and report to the user with the evidence. Do not continue to Tasks 6 to 8 for that engine. A wrapper that feeds bounded windows is allowed only after the user agrees.

- [ ] **Step 5: Write the constraint section** in `docs/live-engines.md`: Nemotron and Parakeet hold up to roughly 25 to 35 s of audio in memory, the app cannot erase their copies, and their text may lag up to 10 s before the recording stops with "engine fell more than 10 s behind".

- [ ] **Step 6: Run the suite** `swift test -c release -j 4`, expected all pass. **Commit** `git commit -m "Add FluidAudio 0.18.0 and document its audio retention"`

---

### Task 5: Shared speaker attribution and the bounded FluidAudio handoff

**Files:**
- Create: `Sources/Recorder/SpeakerAttribution.swift` (move `StreamingEnergyLog` out of `AppleLiveTranscriber.swift`)
- Create: `Sources/Recorder/BoundedEngineHandoff.swift`
- Test: `Tests/RecorderTests/BoundedEngineHandoffTests.swift`, `Tests/RecorderTests/SpeakerAttributionTests.swift`

**Interfaces:**
- Produces:
  - `StreamingEnergyLog` (unchanged API: `record(_:)`, `clear()`, `sums(start:end:)`) plus `func speaker(start: TimeInterval, end: TimeInterval) -> String?` implementing the existing rule (mic > 4× desktop is "You", desktop > 4× mic is "Them", total ≤ 0.0001 or ambiguous is nil). Retention stays 60 s.
  - `final class BoundedEngineHandoff: @unchecked Sendable`
    - `init(capacitySeconds: Double = 10, sampleRate: Double)`
    - `func push(_ chunk: StreamingAudioInput.Chunk) throws` copies the chunk's samples, throws `LiveStopError(reason: .engineFellBehind, detail: nil)` when held audio would exceed capacity, and erases what it held.
    - `func next() async -> [Float]?` returns the oldest chunk's samples, erasing its slot, or nil after `finish()` once empty.
    - `func finish()`, `func cancel()` (erases everything, wakes `next()` with nil).
    - `var heldSeconds: Double { get }`, `var peakHeldSeconds: Double { get }`.

- [ ] **Step 1: Write the failing tests**

```swift
func testRejectsMoreThanTenSecondsAndErasesBacklog() throws {
    let handoff = BoundedEngineHandoff(capacitySeconds: 10, sampleRate: 16000)
    for _ in 0..<100 { try handoff.push(chunk(seconds: 0.1)) }
    XCTAssertEqual(handoff.heldSeconds, 10, accuracy: 0.001)
    XCTAssertThrowsError(try handoff.push(chunk(seconds: 0.1))) {
        XCTAssertEqual(($0 as? LiveStopError)?.reason, .engineFellBehind)
    }
    XCTAssertEqual(handoff.heldSeconds, 0)
}

func testNextReturnsInOrderAndFinishEndsTheStream() async throws {
    let handoff = BoundedEngineHandoff(capacitySeconds: 10, sampleRate: 16000)
    try handoff.push(chunk(seconds: 0.1, value: 0.1))
    try handoff.push(chunk(seconds: 0.1, value: 0.2))
    handoff.finish()
    let first = await handoff.next()
    let second = await handoff.next()
    XCTAssertEqual(first?.first ?? 0, 0.1, accuracy: 0.0001)
    XCTAssertEqual(second?.first ?? 0, 0.2, accuracy: 0.0001)
    let end = await handoff.next()
    XCTAssertNil(end)
    XCTAssertEqual(handoff.heldSeconds, 0)
}

func testLineConfirmedTwentyFiveSecondsLateStillGetsALabel() {
    let log = StreamingEnergyLog()
    for i in 0..<400 { log.record(energyChunk(start: Double(i) * 0.1, desktop: 0, mic: 1)) }
    XCTAssertEqual(log.speaker(start: 15, end: 17), "You")
}
```

`chunk(seconds:value:)` builds a `StreamingAudioInput.Chunk` from an `ErasingPCMBuffer`; `energyChunk` builds one with given energies. Both are file-private helpers in the test files.

- [ ] **Step 2: Run to verify failure.** `swift test -c release --filter 'BoundedEngineHandoffTests|SpeakerAttributionTests'`, expected FAIL.

- [ ] **Step 3: Implement.** `next()` suspends with a stored `CheckedContinuation` under the lock; `push` and `finish` resume it.

- [ ] **Step 4: Run** `swift test -c release -j 4`, expected all pass.

- [ ] **Step 5: Commit** `git commit -m "Add a bounded audio handoff for FluidAudio engines"`

---

### Task 6: Nemotron engine and the token line segmenter

**Files:**
- Create: `Sources/Recorder/TokenLineSegmenter.swift`
- Create: `Sources/Recorder/NemotronLiveEngine.swift`
- Test: `Tests/RecorderTests/TokenLineSegmenterTests.swift`, `Tests/RecorderTests/FluidEngineVerificationTests.swift` (opt-in)

**Interfaces:**
- Consumes: `LiveSpeechEngine`, `PreparationInfo`, `EngineDiagnostics` (Task 3); `BoundedEngineHandoff`, `StreamingEnergyLog` (Task 5); `StreamingTranscript` (existing).
- Produces:
  - `struct TokenLineSegmenter { struct Token: Equatable { let text: String; let start: Double; let end: Double }; static let pauseSeconds = 0.8; private(set) var confirmedThrough: Double; mutating func confirm(_ tokens: [Token]) -> [(text: String, start: Double, end: Double)]; func tail(_ tokens: [Token]) -> String }`
  - `final class NemotronLiveEngine: LiveSpeechEngine`, `kind .nemotron`, `displayName "Nemotron 3.5 streaming"`, `finalizationTimeout .seconds(30)`.

Segmenter algorithm (time based, so recovery inserting earlier tokens cannot duplicate lines): consider only tokens with `start >= confirmedThrough`; find the last index `i` where the token text ends in `.`, `?` or `!`, or where `tokens[i+1].start - tokens[i].end >= 0.8`; emit tokens up to `i` as one line (joined per the rule found in Task 4 step 3), set `confirmedThrough = tokens[i].end`. `tail` joins the remaining tokens.

- [ ] **Step 1: Write the failing segmenter tests**

```swift
func testSplitsAtPauseOfAtLeastPointEightSeconds() {
    var s = TokenLineSegmenter()
    let lines = s.confirm([t("Guten", 0, 0.4), t("Morgen", 0.4, 0.9), t("wir", 1.7, 1.9)])
    XCTAssertEqual(lines.map(\.text), ["Guten Morgen"])
    XCTAssertEqual(lines[0].start, 0); XCTAssertEqual(lines[0].end, 0.9)
}

func testDoesNotSplitAtPointSevenSeconds() {
    var s = TokenLineSegmenter()
    XCTAssertTrue(s.confirm([t("a", 0, 0.2), t("b", 0.9, 1.0)]).isEmpty)
}

func testSplitsAtSentenceEndAndKeepsTail() {
    var s = TokenLineSegmenter()
    let tokens = [t("Hello.", 0, 0.5), t("How", 0.6, 0.8), t("are", 0.8, 1.0)]
    XCTAssertEqual(s.confirm(tokens).map(\.text), ["Hello."])
    XCTAssertEqual(s.tail(tokens), "How are")
}

func testTokensBeforeConfirmedBoundaryAreNeverEmittedAgain() {
    var s = TokenLineSegmenter()
    _ = s.confirm([t("Hello.", 0, 0.5)])
    let again = s.confirm([t("Hello.", 0, 0.5), t("inserted", 0.2, 0.3), t("Bye.", 2, 2.4)])
    XCTAssertEqual(again.map(\.text), ["Bye."])
}
```

- [ ] **Step 2: Run to verify failure.** `swift test -c release --filter TokenLineSegmenterTests`, expected FAIL.

- [ ] **Step 3: Implement `TokenLineSegmenter`**, run the tests, expected PASS.

- [ ] **Step 4: Implement `NemotronLiveEngine`** following the benchmark call sequence at `git show 5647f5e:Tools/ASRBenchmark/Sources/ASRBenchmark/NemotronStreamingBenchmark.swift`: `downloadAndPreloadShared(languageCode:chunkMs: 560, to:configuration:)` with `.cpuAndNeuralEngine` into `~/Library/Application Support/Recorder/SpeechModels/`, `loadFromShared`, `setLanguage("auto")`, recovery on per Task 4. The pump `deliver` pushes into a `BoundedEngineHandoff` and records energies; a consumer task loops `next()` → `process(samples:)`, then `getTokenTimings()` → segmenter → `StreamingTranscript.update(... final: true ...)` for confirmed lines and the tail as provisional. `endSession` calls `finishWithTokenTimings()` and confirms everything left. Diagnostics: `heldAudioQuality .estimated`, held = handoff seconds + min(fed seconds, 9.5) + 15.24 when recovery is on; rows "Handoff peak", "Recovery" ("on", or replay amount if Task 4 found it observable, otherwise "not observable" with quality `.unknown`). `prepare` reports `firstLoad` true when the model folder did not exist before.

- [ ] **Step 5: Add the opt-in replay test** `testNemotronRealTimeReplay` in `FluidEngineVerificationTests`, modeled on `AppleStreamingVerificationTests.testRealTimeReplayThroughProductionStreaming`, gated by `RECORDER_FLUID_STREAM=1` and `RECORDER_FLUID_ENGINE=nemotron`, asserting `complete == true`, at least one confirmed line before finish, and `inbox.pendingFrames == 0`.

Run: `RECORDER_FLUID_STREAM=1 RECORDER_FLUID_ENGINE=nemotron RECORDER_TEST_AUDIO=/Users/christopherjones/projects/cjonesde/recorder/Tools/ASRBenchmark/fixtures/bilingual.wav swift test -c release --filter FluidEngineVerificationTests`
Expected: PASS (first run downloads and compiles, allow several minutes).

- [ ] **Step 6: Run** `swift test -c release -j 4`, expected all pass. **Commit** `git commit -m "Add the Nemotron live engine with timed line splitting"`

---

### Task 7: Parakeet engine

**Files:**
- Create: `Sources/Recorder/ParakeetLiveEngine.swift`
- Modify: `Tests/RecorderTests/FluidEngineVerificationTests.swift`

**Interfaces:**
- Consumes: as Task 6, minus the segmenter.
- Produces: `final class ParakeetLiveEngine: LiveSpeechEngine`, `kind .parakeet`, `displayName "Parakeet Ultra"`, `finalizationTimeout .seconds(30)`.

- [ ] **Step 1: Write the opt-in replay test** `testParakeetRealTimeReplay`, same gate with `RECORDER_FLUID_ENGINE=parakeet`, asserting `complete == true`, a provisional hypothesis appears within 3 s of speech onset (4.30 s in the bilingual fixture), and `pendingFrames == 0`.

- [ ] **Step 2: Run to verify failure** (engine missing), expected FAIL at compile.

- [ ] **Step 3: Implement.** `AsrModels.downloadAndLoad(to:version: .ultra)` into `SpeechModels/`, `SlidingWindowAsrManager(config: .streaming)`, `loadModels`, `startStreaming(source:)` per Task 4. Consumer task loops handoff `next()`, wraps samples in a 16 kHz mono `AVAudioPCMBuffer`, calls `streamAudio`. Updates: `isConfirmed` updates become final lines (one line per update, start and end from its `tokenTimings`), others replace the provisional range. Diagnostics: held = handoff seconds + min(fed seconds, 15), `.estimated`; rows "Window" ("11 s + 2 s + 2 s") and "Last window decode" (time and duration when an update arrives).

- [ ] **Step 4: Run the replay**, expected PASS. Run `swift test -c release -j 4`, expected all pass.

- [ ] **Step 5: Commit** `git commit -m "Add the Parakeet Ultra live engine"`

---

### Task 8: Bounded-audio long replay and real-device checks for all engines

**Files:**
- Modify: `Tests/RecorderTests/FluidEngineVerificationTests.swift`
- Modify: `Tests/RecorderTests/LiveRecordingStaysUpTests.swift`
- Modify: `Tests/RecorderTests/ModeMatrixIntegrationTests.swift`

- [ ] **Step 1: Add `testHeldAudioStaysBoundedOverFiveMinutes`** (opt-in, `RECORDER_FLUID_LONG=1`, engine from `RECORDER_FLUID_ENGINE`): loop the bilingual fixture for 300 s in real time, sample `diagnostics().heldAudioSeconds` every second, assert every sample ≤ 35 (Nemotron) or ≤ 25 (Parakeet), and that the mean of the last 60 samples exceeds the mean of samples 60 to 120 by less than 1 s.

- [ ] **Step 2: Run it for both engines**

Run: `RECORDER_FLUID_LONG=1 RECORDER_FLUID_ENGINE=nemotron RECORDER_TEST_AUDIO=.../bilingual.wav swift test -c release --filter testHeldAudioStaysBoundedOverFiveMinutes`, then the same with `parakeet`.
Expected: PASS both. A failure is a stop-and-report to the user, not a threshold change.

- [ ] **Step 3: Parameterize** `LiveRecordingStaysUpTests` and `ModeMatrixIntegrationTests` over `LiveEngineKind.allCases` (one test method per engine, so a failure names the engine).

- [ ] **Step 4: Run**

Run: `RECORDER_LIVE_MODES=1 swift test -c release --filter 'LiveRecordingStaysUpTests|ModeMatrixIntegrationTests'`
Expected: 12 tests, 0 failures, and every "transcriptOnly produced" line lists no audio file.

- [ ] **Step 5: Commit** `git commit -m "Verify bounded audio and real-device recording for every engine"`

---

### Task 9: Diagnostics sampling

**Files:**
- Create: `Sources/Recorder/SystemMetrics.swift`
- Create: `Sources/Recorder/MainThreadHeartbeat.swift`
- Create: `Sources/Recorder/DiagnosticsRecorder.swift`
- Modify: `Sources/Recorder/RecorderModel.swift` (create recorder at Record press when `showDebugInfo`, set phases, 1 s timer, events)
- Test: `Tests/RecorderTests/DiagnosticsRecorderTests.swift`, `Tests/RecorderTests/SystemMetricsTests.swift`

**Interfaces:**
- Consumes: `EngineDiagnostics`, `PreparationInfo` (Task 3), `LiveStopReason` (Task 1).
- Produces:

```swift
enum MemoryPressure: String, Codable, Sendable { case normal, warning, critical }
enum RecordingPhase: String, Codable, Sendable { case preparing, recording, finishing }
struct MetricsReading: Codable, Equatable, Sendable {
    var footprintBytes: UInt64; var speechServiceFootprintBytes: UInt64?
    var pressure: MemoryPressure; var swapUsedBytes: UInt64; var swapIns: UInt64; var swapOuts: UInt64
}
protocol SystemMetricsSource: Sendable { func read(includeSpeechService: Bool) -> MetricsReading }
struct LiveSystemMetrics: SystemMetricsSource
struct DebugEvent: Codable, Equatable, Sendable { let t: Double; let phase: RecordingPhase; let kind: String; let detail: String? }
struct DiagnosticSample: Codable, Equatable, Sendable {
    let t: Double; let phase: RecordingPhase; let reading: MetricsReading
    let swapGrowthBytes: Int64; let swapInsSinceStart: UInt64; let swapOutsSinceStart: UInt64
    let textBehindRough: Double?; let textBehindFinal: Double?
    let heldAudioSeconds: Double?; let heldAudioQuality: MetricQuality
    let longestMainThreadStall: Double; let audioFilesOnDisk: [String]
}
@MainActor @Observable final class DiagnosticsRecorder {
    init(source: SystemMetricsSource, now: @escaping () -> TimeInterval, engine: LiveEngineKind, settings: [String: String])
    private(set) var phase: RecordingPhase; private(set) var samples: [DiagnosticSample]; private(set) var events: [DebugEvent]
    private(set) var preparation: PreparationInfo?; private(set) var stops: [LiveStopReason]
    func setPhase(_ phase: RecordingPhase)
    func record(_ kind: String, detail: String?)
    func setPreparation(_ info: PreparationInfo)
    func recordStop(_ reason: LiveStopReason)
    func sample(engine: EngineDiagnostics, stall: Double, folder: URL?)
}
final class MainThreadHeartbeat: @unchecked Sendable { func start(); func stop(); var longestStall: Double { get }; func resetLongest() }
```

`LiveSystemMetrics`: footprint from `task_info(TASK_VM_INFO).phys_footprint`; pressure from `sysctl kern.memorystatus_vm_pressure_level` (1 normal, 2 warning, 4 critical); swap from `sysctl vm.swapusage` (`xsu_used`) and `host_statistics64(HOST_VM_INFO64)` `swapins`/`swapouts`; speech service footprint via `proc_listallpids` + `proc_name` matching the process found serving Apple recognition during an Apple session (identify it once by running a session and listing new processes; record the name in `docs/live-engines.md`) and `proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint`, nil when not found or unreadable. Text behind: `submittedThroughSeconds - latestProvisionalEnd` and `- latestFinalEnd`, nil when the end is nil. Audio files: session folder entries excluding `transcript.md`, `transcript.json`, `debug.json`.

- [ ] **Step 1: Write the failing tests** (a `FakeMetrics` returning scripted readings, a manual clock)

```swift
@MainActor
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

@MainActor
func testTextBehindUsesSubmittedPositionMinusResultEnds() {
    let rec = DiagnosticsRecorder(source: FakeMetrics([reading()]), now: { 0 }, engine: .apple, settings: [:])
    rec.sample(engine: diag(submitted: 30, provisional: 28.2, final: 19), stall: 0, folder: nil)
    XCTAssertEqual(rec.samples[0].textBehindRough!, 1.8, accuracy: 0.001)
    XCTAssertEqual(rec.samples[0].textBehindFinal!, 11, accuracy: 0.001)
}

@MainActor
func testUnreadableSpeechServiceStaysUnknownNotRecorderMemory() {
    let rec = DiagnosticsRecorder(source: FakeMetrics([reading(footprint: 600, speech: nil)]), now: { 0 }, engine: .apple, settings: [:])
    rec.sample(engine: diag(), stall: 0, folder: nil)
    XCTAssertNil(rec.samples[0].reading.speechServiceFootprintBytes)
}

@MainActor
func testAudioFilesIgnoreTranscriptAndDebugFiles() throws {
    let folder = try tempFolder(files: ["transcript.md", "transcript.json", "debug.json", "mic.caf"])
    let rec = DiagnosticsRecorder(source: FakeMetrics([reading()]), now: { 0 }, engine: .apple, settings: [:])
    rec.sample(engine: diag(), stall: 0, folder: folder)
    XCTAssertEqual(rec.samples[0].audioFilesOnDisk, ["mic.caf"])
}

func testLiveMetricsReadsNonZeroFootprintAndAValidPressure() {
    let r = LiveSystemMetrics().read(includeSpeechService: false)
    XCTAssertGreaterThan(r.footprintBytes, 1_000_000)
}
```

Add a heartbeat test: start it, block the main thread for 0.5 s with `Thread.sleep`, then let the run loop spin; assert `longestStall >= 0.4`.

- [ ] **Step 2: Run to verify failure.** `swift test -c release --filter 'DiagnosticsRecorderTests|SystemMetricsTests'`, expected FAIL.

- [ ] **Step 3: Implement** the types, then wire `RecorderModel`: when `showDebugInfo` is on, `startRecording` creates the recorder (phase `.preparing`, event "record pressed"), records preparation info and "capture started" with `heartbeat.longestStall` captured over capture start, sets `.recording`, starts a 1 s main-actor timer calling `sample`; records "first text" and "first final text" on the first non-empty hypothesis and line; records every stop reason; sets `.finishing` in `saveAndStop` and "finalized" with its duration. When debug is off none of this is created.

- [ ] **Step 4: Run** `swift test -c release -j 4`, expected all pass.

- [ ] **Step 5: Commit** `git commit -m "Sample memory, swap, text lag and held audio while debug is on"`

---

### Task 10: `debug.json` report and copy summary

**Files:**
- Create: `Sources/Recorder/DebugReport.swift`
- Modify: `Sources/Recorder/RecorderModel.swift` (write at save, all modes, including the nothing-transcribed path)
- Test: `Tests/RecorderTests/DebugReportTests.swift`

**Interfaces:**
- Consumes: `DiagnosticsRecorder` (Task 9).
- Produces:
  - `struct DebugReport: Codable { let schemaVersion: Int; let appCommit: String?; let machineModel: String; let physicalMemoryBytes: UInt64; let osVersion: String; let engine: LiveEngineKind; let engineSettings: [String: String]; let language: String?; let preparation: PreparationInfo?; let samples: [DiagnosticSample]; let events: [DebugEvent]; let stops: [LiveStopReason]; let summary: [String: Double] }`, `schemaVersion` 1.
  - `extension DiagnosticsRecorder { func report(language: String?) -> DebugReport }`
  - `func write(to folder: URL) throws` writing `debug.json` (ISO 8601 dates, sorted keys).
  - `func summaryText() -> String` for Copy summary: engine, machine, load time and first/cached, first word, median and max text behind (rough, final), peak Recorder memory, peak speech service memory or "unknown", swap growth, peak held audio with its quality, longest stall, stops.
  - `summary` keys: `firstWordSeconds`, `medianBehindRough`, `medianBehindFinal`, `maxBehindFinal`, `peakFootprintBytes`, `swapGrowthBytes`, `peakHeldAudioSeconds`, `longestStallSeconds`.
  - `appCommit` from an `Info.plist` key `RecorderGitCommit` that `build.sh` sets with `git rev-parse --short HEAD`; nil when absent.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
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

@MainActor
func testSilentTranscriptOnlyRecordingStillWritesDebugJSON() async throws {
    let model = RecorderModel(engineFactory: { FakeLiveEngine(kind: $0, lines: []) })
    model.showDebugInfo = true
    model.audioHandlingMode = .transcriptOnly
    let folder = try await recordAndSave(model, seconds: 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("debug.json").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.md").path))
}

@MainActor
func testNoDebugJSONWhenDebugIsOff() async throws {
    let model = RecorderModel(engineFactory: { FakeLiveEngine(kind: $0, lines: [line("hi")]) })
    model.showDebugInfo = false
    let folder = try await recordAndSave(model, seconds: 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("debug.json").path))
}
```

`recordAndSave` needs real captures, so these two model tests are opt-in under `RECORDER_LIVE_MODES=1` and clean up their folders like `ModeMatrixIntegrationTests`.

- [ ] **Step 2: Run to verify failure.** `swift test -c release --filter DebugReportTests`, expected FAIL.

- [ ] **Step 3: Implement** and make the transcript-only "Nothing to save" path keep the session folder when debug is on (it holds only `debug.json`), deleting it otherwise as today.

- [ ] **Step 4: Run** `swift test -c release -j 4` and `RECORDER_LIVE_MODES=1 swift test -c release --filter DebugReportTests`, expected all pass.

- [ ] **Step 5: Commit** `git commit -m "Write debug.json with each recording while debug is on"`

---

### Task 11: Picker and debug UI

**Files:**
- Create: `Sources/Recorder/DebugDrawerView.swift`
- Create: `Sources/Recorder/DebugWindowController.swift` (floating `NSPanel` hosting `DebugWindowView`)
- Create: `Sources/Recorder/DebugWindowView.swift` (Swift Charts)
- Modify: `Sources/Recorder/RecorderPanel.swift` (engine picker above the live transcript; language picker only when `liveEngine.usesLanguagePicker`; both disabled unless `canChangeLiveEngine`; engine picker hidden when `liveTranscriptionEnabled` is false; drawer under the live transcript when `showDebugInfo`; the "Apple · <language>" caption at line 286 shows the selected engine)
- Modify: `Sources/Recorder/PreferencesView.swift` (Transcription tab: engine picker, "Show debug info" toggle)

**Interfaces:**
- Consumes: `RecorderModel.liveEngine`, `.showDebugInfo`, `.canChangeLiveEngine` (Task 2); `RecorderModel.diagnostics: DiagnosticsRecorder?` and `DebugReport.summaryText()` (Tasks 9, 10).
- Produces: `DebugWindowController.shared.show(model:)`, `.close()`.

Drawer rows, in order: text behind (rough / final), Recorder memory, memory pressure and swap growth, oldest audio held (with "estimated" or "unknown" shown next to the value when not measured), audio files on disk ("none" or names), safety stops (count and last reason). Pop-out: header (engine, language or "auto", compute units, recording time), engine block (load time, first or cached, model size), three charts (text behind rough and final; Recorder memory, speech service memory when Apple, swap growth; held audio) with the preparing phase shaded, per-engine rows from `EngineDiagnostics.rows`, event log, "Copy summary" button. Panel level `.floating`, `isFloatingPanel = true`, `hidesOnDeactivate = false`. Colors green, yellow, red at thresholds chosen by the implementer and listed in the commit message.

- [ ] **Step 1: Implement** the views and controller.

- [ ] **Step 2: Build and run the suite**

Run: `swift test -c release -j 4 && ./build.sh && codesign --verify --deep --strict Recorder.app`
Expected: tests pass, `done`, no codesign output.

- [ ] **Step 3: Manual check** with the built app (quit the running Recorder first; macOS asks for permissions again): with debug off, no drawer and no `debug.json`; with debug on, record 30 s per engine while audio plays, check the drawer updates every second, Pop out floats above other windows, Copy summary pastes text, the picker is disabled while recording, the language picker shows only for Apple, and `debug.json` appears beside the transcript. Take one screenshot of the drawer and one of the pop-out for the PR.

- [ ] **Step 4: Commit** `git commit -m "Add the engine picker, debug drawer and pop-out window"`

---

### Task 12: Polish-mode unload and closing documentation

**Files:**
- Modify: `Sources/Recorder/RecorderModel.swift:500-515` and `:658` (`startTranscription`): `await live.engine.unload()` before the Whisper host loads; record a debug event "live engine unloaded for polish"; set `TranscriptDocument.liveEngine` to the engine's `displayName` when the polish pass writes its document.
- Modify: `README.md` (live engines, debug toggle), `docs/apple-streaming.md` (link to `docs/live-engines.md`)
- Test: `Tests/RecorderTests/LiveEngineSelectionTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
func testPolishPassUnloadsTheLiveEngineBeforeWhisperLoads() async throws {
    let fake = FakeLiveEngine(kind: .parakeet)
    let model = RecorderModel(engineFactory: { _ in fake }, whisperLoadObserver: { XCTAssertEqual(fake.unloadCalls, 1) })
    try await model.runPolishForTesting(audio: fixtureURL("jfk"))
    XCTAssertEqual(fake.unloadCalls, 1)
}
```

`whisperLoadObserver` and `runPolishForTesting` are test seams; if `startTranscription` can be driven directly with a `PendingTranscription`, use that instead of a new method.

- [ ] **Step 2: Run to verify failure**, expected FAIL. **Step 3: Implement.** **Step 4: Run** `swift test -c release -j 4`, expected all pass.

- [ ] **Step 5: Final verification**

Run: `swift test -c release -j 4`
Expected: 0 failures; report the executed and skipped counts.
Run: `RECORDER_LIVE_MODES=1 swift test -c release --filter 'LiveRecordingStaysUpTests|ModeMatrixIntegrationTests|DebugReportTests'`
Expected: 0 failures.
Run: `grep -rn $'\u2014' Sources docs/live-engines.md README.md; grep -rn '^\s*//' Sources/Recorder/{LiveStopReason,LiveSpeechEngine,LiveEngineKind,SpeakerAttribution,BoundedEngineHandoff,TokenLineSegmenter,NemotronLiveEngine,ParakeetLiveEngine,SystemMetrics,MainThreadHeartbeat,DiagnosticsRecorder,DebugReport,DebugDrawerView,DebugWindowController,DebugWindowView}.swift`
Expected: no output.

- [ ] **Step 6: Commit** `git commit -m "Unload the live engine before the polish pass and document live engines"`
