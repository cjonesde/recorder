# Live Voice Coach Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A live prompter for his own voice in calls: a dependency-free coach core fed by Recorder's mic and system-audio streams, a small always-on-top HUD that shows pace and energy, and every other detector running in shadow mode with an event log and labelled clips that decide promotion.

**Architecture:** A new SwiftPM library target `VoiceCoach` (Foundation only) takes audio samples and transcript lines in and returns HUD state, log events and clip requests out. It is single-threaded and deterministic given a seeded random source. Recorder couples to it through one adapter file (`Sources/Recorder/Coach/CoachAdapter.swift`) that drains lock-free rings on a serial queue, writes `coach.jsonl` and clips into the session folder, and publishes HUD state to a borderless floating panel. Step 0 is a Python tool that runs the same gate and `coach.py`'s intonation code on a kept `audio.m4a`.

**Tech Stack:** Swift 6.2 toolchain, macOS 26, SwiftPM, XCTest, SwiftUI + AppKit (`NSPanel`), AVFoundation (clip writing and playback only, adapter side). Python 3.12 via `uv run --with`, numpy<2, praat-parselmouth 0.4.7, ffmpeg.

**Spec:** `docs/2026-11-14-grill-live-voice-coach.md`

## Global Constraints

- `VoiceCoach` imports Foundation only. No AppKit, AVFoundation, Accelerate or Recorder types. It must compile unchanged for a later port to schriftlich.app.
- `VoiceCoach` builds in Swift 6 language mode; `Recorder` stays `.swiftLanguageMode(.v5)`.
- No code comments of any kind in new or changed code (user rule). Names carry meaning.
- No em dashes and no `--` used as punctuation in any prose, UI string, commit message or doc.
- No text on the HUD. Colour and shape only (SF Symbols that are pictograms, not letters).
- Only pace and energy are visible on day one. Every other detector logs in shadow mode until promoted.
- Promotion of a detector to the HUD requires at least 20 labelled clips and precision of at least 0.9 (pace starts promoted, per the spec).
- Irritation is log-only and never named as such: the detector is `raisedVoice`, acoustic quantities only, never promotable.
- Nothing is stored about other participants beyond turn timing (talk share, interruption counts). No pitch, level or text of the desktop stream is logged.
- Clips are audio and therefore exist only when the recording's `AudioHandlingMode.retainsAudio` is true, only for own voice, and only where the tap was quiet for the whole clip window.
- The coin flip (withholding) is a preference, on by default, probability 0.5 per trigger. Cue-off sessions follow a fading schedule.
- "So" detection runs only when the live engine is `.apple` (Parakeet lags 11 to 13 s).
- The coach is off by default (`Preferences.coachEnabled == false`); existing behaviour is unchanged until switched on.
- Commits on branch `voice-coach`, identity `cjonesde`. No push without asking.

## Review Focus

1. **Desk speakers, them talking:** the mic hears the remote voice. Expected: no pace, energy, ending or clip is computed from those frames (gate `.them`), and the energy meter holds rather than jumping. Test: `GateTests.testBleedNeverOpensGate`, `VoiceCoachEngineTests.testRemoteSpeechThroughSpeakersProducesNoOwnSpeech`.
2. **Tap stalls or rebuilds** (the macOS 26 zero-PCM watchdog): desktop samples stop for seconds. Expected: the coach does not freeze waiting and does not score blind; frames go `.unknown`. Test: `GateTests.testDesktopStallMarksUnknownAfterTwoSeconds`.
3. **First sessions without a baseline:** expected no pace cue at all until 120 s of own speech exist, so the first call cannot open with a false alarm. Test: `PaceTests.testNoTriggerBeforeBaseline`.
4. **Transcript-only recording or a mid-call downgrade to transcript-only:** expected no clip file ever written, existing clips deleted on downgrade. Test: `CoachAdapterTests.testTranscriptOnlyWritesNoClips`, `CoachAdapterTests.testDowngradeDeletesClips`.
5. **Trash mid-call:** expected the coach stops and its log and clips go with the trashed folder, with no write racing the deletion. Test: `CoachAdapterTests.testStopIsSynchronousBeforeFolderRemoval`.

---

## File Structure

```
Package.swift                                    add VoiceCoach target, VoiceCoachTests, Recorder depends on VoiceCoach
Sources/VoiceCoach/
  CoachTypes.swift          public value types: CoachSource, DetectorID, GateState, CoachLine, CoachEvent, CoachHUDState, ClipRequest, CoachOutput, CoachSessionSummary
  CoachPreset.swift         CoachPreset + thresholds + pick(attendeeCount:)
  CoachConfig.swift         CoachConfig (everything the adapter decides per session)
  CoachBaseline.swift       persisted per-language rate and per-mic level medians
  Downsampler.swift         streaming resampler to 16 kHz
  FrameAnalyzer.swift       10 ms frames: level dB per source, mic f0 via PitchTracker
  PitchTracker.swift        YIN f0 estimator
  OwnVoiceGate.swift        noise floor + gate state per frame
  CuePolicy.swift           coin flip, cue-off sessions, shadow decision
  RollingMedian.swift       small helpers: rolling window median, median()
  PaceDetector.swift        syllable nuclei + articulation rate + trigger
  EnergyMeter.swift         level vs baseline -> 0...1
  SentenceStartCounter.swift  "so" at sentence starts
  Intonation.swift          cleanF0 + terminalContour ports
  EndingsDetector.swift     phrase ends, rising and trailing rates
  ProsodyProxies.swift      raisedVoice (log only) + onset slope
  TurnTaking.swift          talk share + interruptions
  ClipPlanner.swift         clip windows that were tap-quiet throughout
  VoiceCoach.swift          the engine: ingest, advance, finish
Tests/VoiceCoachTests/
  Synth.swift               synthetic voice, silence, noise, seeded RNG
  *Tests.swift              one file per component
  Fixtures/contour-fixture.json + make_contour_fixture.py
Sources/Recorder/Coach/
  CoachAdapter.swift        CoachController (@MainActor) + CoachPump (rings, queue, log writer, clip writer)
  CoachStore.swift          baseline file, session counter, labels and precision aggregation
  CoachHUDPanel.swift       NSPanel controller + CoachHUDView
  CoachReviewWindow.swift   clip review, labels, precision, promotion toggles
Sources/Recorder/RecorderModel.swift, Preferences.swift, PreferencesView.swift, RecorderPanel.swift   small hooks
Tests/RecorderTests/CoachAdapterTests.swift
Tools/SpeakerTest/speaker_test.py + test_speaker_test.py   step 0
```

## Shared numbers (used across tasks, defined once in `CoachTuning` inside `CoachConfig.swift`)

| Name | Value |
|:-|:-|
| analysis rate / hop / level window | 16 000 Hz / 160 samples (10 ms) / 480 samples (30 ms) |
| pitch range / YIN threshold / YIN window | 60 to 500 Hz / 0.15 / 480 samples |
| mic speech | level > floor + 10 dB and > -60 dBFS; floor drops instantly, rises 0.5 dB/s |
| tap active | desktop level > `tapQuietDB` (-50 dBFS) |
| gate lead / hangover | 0.3 s / 0.5 s |
| overlap | tap active and mic level > desktop level + 6 dB and mic speech |
| desktop stall | mic ahead of desktop by > 2.0 s -> `.unknown` |
| sample events | one per detector per second of coach time |
| cue lit duration | 4 s |
| clip window | trigger time - 6 s to + 2 s |

---

### Task 0: Step 0 speaker test tool (Python)

**Files:**
- Create: `Tools/SpeakerTest/speaker_test.py`
- Create: `Tools/SpeakerTest/test_speaker_test.py`
- Modify: `README.md` (one short "Voice coach speaker test" subsection with the commands)

**Interfaces:**
- Consumes: `coach.py` from `--coach` (default `~/projects/cjonesde/cj-plugins/plugins/cj-core/skills/talking-head-coaching/scripts/coach.py`), loaded with `importlib.util.spec_from_file_location`; uses `audio_stats`, `pitch_track`, `terminal_contour`, `pause_phrases`, `AUDIO_RATE`, `AUDIO_WINDOW`.
- Produces: CLI `analyze <audio.m4a> [--csv out.csv] [--clips dir] [--json]` and `score <labels.csv>`. Same gate numbers as the Shared numbers table, so the Swift gate inherits whatever this test shows.

Run everything with `uv run --python 3.12 --with "numpy<2" --with praat-parselmouth==0.4.7 --with pytest ...`. No PEP 723 header, no comments.

- [ ] **Step 1: Write failing tests** in `test_speaker_test.py` on synthetic int16 stereo at 16 kHz:
  - `test_tap_quiet_mask_closes_with_lead_and_hangover`: desktop burst 2.0 to 3.0 s at -20 dBFS; mask (50 ms windows) is False for every window whose centre lies in [1.7, 3.5] and True at 1.0 s and 4.0 s.
  - `test_bleed_lag_is_found`: mic = desktop delayed 40 ms and attenuated 18 dB; `bleed_report` returns lag within 0.03 to 0.05 s and attenuation within 15 to 21 dB.
  - `test_syllable_nuclei_counts_synthetic_train`: 4 Hz amplitude-modulated 150 Hz harmonic tone for 5 s gives 18 to 22 nuclei.
  - `test_gated_phrase_ends_drop_bleed_only_phrases`: phrase ends that sit inside desktop bursts are absent from the gated set and present in the ungated set.
  - `test_score_reports_agreement`: a CSV with `contour` and `ear` columns (rise/fall/level) gives agreement 0.75 for 3 of 4 matching rows, split into `all` and `gated`.
- [ ] **Step 2: Run** `uv run ... pytest Tools/SpeakerTest -q`. Expected: FAIL (module missing).
- [ ] **Step 3: Implement** `speaker_test.py`: `load_stereo(path) -> (desktop, mic)` via ffmpeg `-ac 2 -ar 16000 -f s16le` (left desktop, right mic per `StereoMixer.swift:5-6`); `window_db(pcm) -> np.ndarray` (50 ms RMS dBFS); `tap_quiet_mask(desktop_db, quiet_db=-50, lead=0.3, hangover=0.5)`; `bleed_report(desktop, mic) -> dict` (lag by envelope cross-correlation over tap-active windows, median attenuation mic minus desktop); `syllable_nuclei(mic_db, voiced) -> list[float]` (2 dB hysteresis peak picker on the 10 ms level contour, peak must be voiced and above floor + 10 dB, the same rule as `PaceDetector`); `analyze(path) -> dict` with `scorable_share` (share of his speech windows that are tap-quiet), articulation rate all vs gated, contour counts all vs gated per phrase end from `pause_phrases(audio_stats(mic).pauses)` and `terminal_contour(times, st, p.last_word, p.end)`, and a `verdict` string; `--csv` writes `t,contour,rise,fall,gated,ear` with `ear` empty; `--clips` writes 3.5 s mono wav (mic channel, t - 3 to t + 0.5) per phrase end via the `wave` module; `score` prints agreement for all and gated rows. Verdict rule: "desk speakers usable" when gated agreement >= 0.8 over >= 15 ear-marked endings and `scorable_share` >= 0.5, "headset tool" when either fails, "needs ear marks" before `score` runs.
- [ ] **Step 4: Run** tests. Expected: 5 passed. Also run `analyze` on a synthetic stereo m4a built with `say` + ffmpeg and confirm it prints a report and writes CSV and clips.
- [ ] **Step 5: Commit** `Add the step 0 speaker test for the voice coach`.

### Task 1: VoiceCoach target, framing and pitch

**Files:**
- Modify: `Package.swift` (add `.target(name: "VoiceCoach", path: "Sources/VoiceCoach")`, add `"VoiceCoach"` to Recorder's dependencies, add `.testTarget(name: "VoiceCoachTests", dependencies: ["VoiceCoach"], path: "Tests/VoiceCoachTests", resources: [.copy("Fixtures")])`)
- Create: `CoachTypes.swift`, `CoachConfig.swift` (with `CoachTuning`), `Downsampler.swift`, `PitchTracker.swift`, `FrameAnalyzer.swift`, `RollingMedian.swift`
- Test: `Tests/VoiceCoachTests/Synth.swift`, `DownsamplerTests.swift`, `PitchTrackerTests.swift`, `FrameAnalyzerTests.swift`

**Interfaces:**
- Produces:
  - `public enum CoachSource: Sendable { case mic, desktop }`
  - `public enum DetectorID: String, Codable, CaseIterable, Sendable { case pace, energy, soStarts, risingEndings, trailingEndings, raisedVoice, talkShare, interruptions }` with `public var isPromotable: Bool` (true for pace, soStarts, risingEndings, trailingEndings, talkShare) and `public var showsAsTrigger: Bool` (false for energy, talkShare)
  - `public enum GateState: String, Codable, Sendable { case own, them, overlap, silence, unknown }`
  - `struct Downsampler { init(); mutating func process(_ input: UnsafeBufferPointer<Float>, rate: Double, into out: inout [Float]) }` producing 16 kHz, two cascaded one-pole low-passes at 7 kHz, then linear interpolation; sample count over time is preserved within 1 sample per second.
  - `struct PitchTracker { init(tuning: CoachTuning); func f0(_ window: ArraySlice<Float>) -> Double }` returning Hz or 0 (YIN cumulative mean normalised difference, absolute threshold, parabolic interpolation).
  - `struct LevelFrame { let index: Int; let db: Double }` and `struct FrameAnalyzer { mutating func push(_ samples16k: [Float]) -> [LevelFrame]; func window(endingAt index: Int, length: Int) -> ArraySlice<Float>? }` (one per source; frame `i` covers samples ending at `(i + 1) * 160`, level over the trailing 480 samples, dBFS with floor -120).
  - `func median(_ values: [Double]) -> Double?`, `struct RollingWindow { init(capacity: Int); mutating func append(_ v: Double); var median: Double?; var count: Int; var values: [Double] }`
  - Test helpers in `Synth.swift`: `Synth.voice(f0: (Double) -> Double, syllablesPerSecond: Double, seconds: Double, rate: Double = 48_000, peakDB: Double = -20) -> [Float]` (5 harmonics at amplitude 1/k, Hann bursts covering 60% of each syllable period, dips 20 dB below peak), `Synth.silence(seconds:rate:)`, `Synth.noise(seconds:db:rate:seed:)`, `struct SplitMix64: RandomNumberGenerator`.

- [ ] **Step 1: Write failing tests:** `testDownsampling48kPreservesDuration` (48 000 samples in 7 chunks of uneven size -> 16 000 +/- 1 out), `testDownsampling44_1kPreservesDuration`, `testYINFindsHarmonicPitch` (150 Hz harmonic tone -> 147...153), `testYINFindsLowAndHighPitch` (80 Hz and 300 Hz within 3%), `testYINReturnsZeroOnNoise` (white noise at -30 dBFS -> 0 in at least 90% of frames), `testLevelOfFullScaleSineIsMinus3dB` (-3.0 +/- 0.2), `testSilenceIsFloor`.
- [ ] **Step 2: Run** `swift test --filter VoiceCoachTests`. Expected: FAIL to compile.
- [ ] **Step 3: Implement** the files above.
- [ ] **Step 4: Run** `swift test --filter VoiceCoachTests`. Expected: all pass. Run `swift build` to confirm Recorder still builds with the new dependency.
- [ ] **Step 5: Commit** `Add the VoiceCoach target with framing and pitch`.

### Task 2: Own-voice gate

**Files:**
- Create: `Sources/VoiceCoach/OwnVoiceGate.swift`
- Test: `Tests/VoiceCoachTests/GateTests.swift`

**Interfaces:**
- Consumes: `LevelFrame`, `CoachTuning`.
- Produces: `struct OwnVoiceGate { init(tuning: CoachTuning); mutating func classify(micDB: Double, desktopDB: [Double?], at index: Int) -> GateState; var micFloorDB: Double; func isMicSpeech(_ db: Double) -> Bool }`. `desktopDB` is the window of desktop levels for frame indices `index - hangoverFrames ... index + leadFrames` (nil where the desktop frame does not exist). Rules: any nil in the window -> `.unknown`; any tap-active frame in the window -> `.overlap` when the current desktop level is known and mic > desktop + 6 dB and mic speech, else `.them`; otherwise `.own` when mic speech, else `.silence`. The floor updates on every frame.

- [ ] **Step 1: Write failing tests:** `testOwnSpeechWithQuietTapIsOwn`, `testTapActiveClosesGateFromLeadToHangover` (tap active frames 100...199: frames 70...249 are not `.own`, frame 60 and 260 are `.own` while he speaks), `testBleedNeverOpensGate` (mic = tap level - 18 dB plus his silence: never `.own`, never `.overlap`), `testLoudOwnVoiceOverTapIsOverlap`, `testDesktopStallMarksUnknownAfterTwoSeconds` (this one drives the engine in Task 3; write it now as a pending `XCTSkip` and enable it in Task 3), `testFloorTracksRoomNoise` (floor converges within 1 dB of a -55 dBFS noise bed in 10 s and drops instantly to a quieter bed).
- [ ] **Step 2: Run** `swift test --filter GateTests`. Expected: FAIL.
- [ ] **Step 3: Implement** `OwnVoiceGate`.
- [ ] **Step 4: Run** again. Expected: pass (one skipped).
- [ ] **Step 5: Commit** `Gate own-voice frames on a quiet system audio tap`.

### Task 3: Engine skeleton, cue policy, event log format

**Files:**
- Create: `CuePolicy.swift`, `CoachPreset.swift` (presets with thresholds only; calendar pick comes in Task 10), `VoiceCoach.swift`
- Modify: `CoachTypes.swift`, `CoachConfig.swift`
- Test: `CuePolicyTests.swift`, `VoiceCoachEngineTests.swift`, enable `GateTests.testDesktopStallMarksUnknownAfterTwoSeconds`

**Interfaces:**
- Produces:
  - `public enum CoachPreset: String, Codable, CaseIterable, Sendable { case presentation, oneOnOne, group }` with `public var paceRatio: Double` (1.10 / 1.20 / 1.15) and `public var talkShareHigh: Double?` (nil / 0.65 / 0.40)
  - `public struct CoachConfig: Sendable, Equatable { public var language: String; public var preset: CoachPreset; public var promoted: Set<DetectorID>; public var withholding: Bool; public var cueOffSession: Bool; public var transcriptCues: Bool; public var baselineRate: Double?; public var baselineLevelDB: Double?; public var tuning: CoachTuning; public init(language: String) }` (defaults: preset `.presentation`, promoted `[.pace]`, withholding true, cueOffSession false, transcriptCues false, tuning `.default`)
  - `public struct CoachEvent: Codable, Equatable, Sendable { public enum Kind: String, Codable, Sendable { case session, sample, trigger, clip, preset, gap }; public let t: Double; public let kind: Kind; public let detector: DetectorID?; public let values: [String: Double]; public let shown: Bool?; public let note: String?; public let id: String? }`
  - `public struct CoachHUDState: Equatable, Sendable { public var energy: Double?; public var gate: GateState; public var litCues: Set<DetectorID>; public var talkShare: Double?; public var talkShareHigh: Bool; public var preset: CoachPreset; public static func idle(_ preset: CoachPreset) -> CoachHUDState }`
  - `public struct ClipRequest: Equatable, Sendable { public let id: String; public let detector: DetectorID; public let start: Double; public let end: Double }`
  - `public struct CoachOutput: Sendable { public var hud: CoachHUDState; public var events: [CoachEvent]; public var clips: [ClipRequest] }`
  - `public struct CoachSessionSummary: Codable, Equatable, Sendable { public let language: String; public let ownSpeechSeconds: Double; public let articulationRate: Double?; public let levelDB: Double? }`
  - `public enum CuePolicy { public static func isCueOffSession(index: Int) -> Bool; public static func decide(_ detector: DetectorID, config: CoachConfig, random: inout some RandomNumberGenerator) -> (shown: Bool, note: String) }`. Cue-off schedule (1-based session index): 1...10 every 5th, 11...20 every 3rd, above 20 every 2nd. Notes: `"shadow"` (not promoted or not promotable), `"cue-off session"`, `"withheld"`, `"shown"`. With withholding on, shown when `Double.random(in: 0..<1, using:) < 0.5`.
  - `public final class VoiceCoach { public init(config: CoachConfig, random: any RandomNumberGenerator = SystemRandomNumberGenerator()); public func ingest(_ source: CoachSource, _ samples: UnsafeBufferPointer<Float>, sampleRate: Double); public func ingest(_ line: CoachLine); public func setPreset(_ preset: CoachPreset); public func advance() -> CoachOutput; public func finish() -> CoachSessionSummary; public private(set) var ownSpeechSeconds: Double }` plus `public struct CoachLine: Sendable { public let time: Double; public let text: String; public let isOwn: Bool }`. `advance()` processes every mic frame `i` for which desktop frames through `i + leadFrames` exist, or, when the mic is more than 2.0 s ahead of the desktop, processes it with nil desktop levels (gate `.unknown`) and emits one `gap` event per stall. The first `advance()` emits a `session` event with the config in `values`/`note`. Internally, `trigger(_ detector:at:values:)` runs `CuePolicy.decide`, appends a `trigger` event with a fresh id (`"\(detector.rawValue)-\(Int(t * 1000))"`), and lights the cue until t + 4 s when shown. Detectors arrive in later tasks; this task wires the frame loop, the gate, the 1 Hz sample tick (one `sample` event per frame-second with `gate` share values) and HUD assembly.

- [ ] **Step 1: Write failing tests:** `testCueOffScheduleFades` (indices 5, 10 off; 13, 15 off; 22, 24 off; 1, 2, 11, 21 on), `testShadowWhenNotPromoted`, `testCoinFlipIsAboutHalf` (SplitMix64 seed 7, 1000 decisions, shown count 450...550), `testWithholdingOffAlwaysShows`, `testCueOffSessionWithholdsAll`, `testFirstAdvanceLogsSession`, `testSamplesLoggedOncePerSecond` (10 s of synthetic audio on both sources -> 10 `sample` events), `testRemoteSpeechThroughSpeakersProducesNoOwnSpeech` (desktop voice at -20 dBFS, mic same voice delayed 40 ms at -38 dBFS -> `ownSpeechSeconds == 0`), `testDesktopStallMarksUnknownAfterTwoSeconds` (mic 5 s, desktop 1 s -> frames after 2.0 s ahead are processed with HUD gate `.unknown` and one `gap` event), `testEventsRoundTripAsJSONLines`.
- [ ] **Step 2: Run** `swift test --filter VoiceCoachTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** again. Expected: pass.
- [ ] **Step 5: Commit** `Add the coach engine loop, cue policy and event format`.

### Task 4: Pace and energy against his baseline

**Files:**
- Create: `PaceDetector.swift`, `EnergyMeter.swift`, `CoachBaseline.swift`
- Modify: `VoiceCoach.swift` (feed `.own` frames, trigger pace, put energy on the HUD, fill `finish()`)
- Test: `PaceTests.swift`, `EnergyTests.swift`, `BaselineTests.swift`

**Interfaces:**
- Produces:
  - `struct PaceDetector { init(tuning: CoachTuning, baselineRate: Double?); mutating func observe(t: Double, db: Double, voiced: Bool, own: Bool, floorDB: Double); mutating func tick(t: Double, paceRatio: Double) -> Bool; var rate: Double?; var effectiveBaseline: Double?; var syllableTimes: [Double]; var sessionRateMedian: Double? }`. Syllable rule: 2 dB hysteresis peak picker on the 10 ms level contour of own frames; a peak counts when voiced within +/- 3 frames and above floor + 10 dB. Rate = syllables in the last 1000 own frames / own seconds in that span, defined once at least 500 own frames exist. `tick` runs at 1 Hz, appends the current rate to the session rate history, and returns true when rate >= baseline x paceRatio on 3 consecutive ticks and 30 s have passed since the last trigger. Effective baseline = `baselineRate` if set, else the median of the session rate history once 120 s of own speech exist, else nil (no trigger, sample note `"no baseline"`).
  - `struct EnergyMeter { init(baselineLevelDB: Double?); mutating func observe(t: Double, db: Double, own: Bool); func value(at t: Double) -> Double?; var offsetDB: Double?; var sessionLevelMedian: Double? }`. Median of the last 300 own-frame levels minus baseline (persisted, else session median after 30 s own speech). `value = clamp((offset + 9) / 15, 0, 1)`, nil when no own frame in the last 20 s or no baseline yet.
  - `public struct CoachBaseline: Codable, Equatable, Sendable { public var rates: [String: [Double]]; public var levels: [String: [Double]]; public init(); public func rate(language: String) -> Double?; public func level(mic: String) -> Double?; public mutating func record(_ summary: CoachSessionSummary, mic: String) }`. Keeps the last 10 session medians per key, returns the median once 3 exist, ignores sessions with under 120 s own speech.
  - Pace sample `values`: `rate`, `baseline`, `ratio`. Energy sample `values`: `levelDB`, `offsetDB`, `energy`.

- [ ] **Step 1: Write failing tests:** `testSyllableCountMatchesSyntheticTrain` (4 syll/s for 20 s -> rate 3.6...4.4), `testRateIgnoresPauses` (same speech with 2 s silences between 3 s stretches -> same rate band), `testNoTriggerBeforeBaseline` (fast 7 syll/s for 100 s, no persisted baseline -> no pace trigger), `testTriggersWhenFasterThanBaseline` (baseline 4.0, speech at 6 syll/s -> one trigger within 15 s, none again within 30 s), `testNoTriggerAtBaselinePace`, `testEnergyRisesWithLevel` (baseline -26: speech at -26 -> 0.55...0.65, at -17 -> 1.0, at -35 -> 0.0), `testEnergyNilAfterTwentySecondsQuiet`, `testBaselineNeedsThreeLongSessions`, `testBaselineKeepsLastTen`.
- [ ] **Step 2: Run** `swift test --filter VoiceCoachTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** again. Expected: pass.
- [ ] **Step 5: Commit** `Detect pace and energy against his own baseline`.

### Task 5: Recorder adapter, HUD panel, event log on disk

**Files:**
- Create: `Sources/Recorder/Coach/CoachAdapter.swift`, `Sources/Recorder/Coach/CoachStore.swift`, `Sources/Recorder/Coach/CoachHUDPanel.swift`
- Modify: `Sources/Recorder/Preferences.swift`, `Sources/Recorder/RecorderModel.swift` (`configureCaptures`, `startPreparedRecording`, `togglePause`, `saveAndStop`, `trashAndStop`, `changeAudioHandling`), `Sources/Recorder/PreferencesView.swift` (new "Coach" tab), `Sources/Recorder/RecorderPanel.swift` (coach on/off toggle shown while idle)
- Test: `Tests/RecorderTests/CoachAdapterTests.swift`

**Interfaces:**
- Consumes: `VoiceCoach`, `CoachConfig`, `CoachBaseline`, `CuePolicy.isCueOffSession`, `FloatRingBuffer`, `LiveEngineKind`, `TranscriptLine`.
- Produces:
  - `final class CoachPump: @unchecked Sendable { init(folder: URL, config: CoachConfig, retainsAudio: Bool, random: any RandomNumberGenerator = SystemRandomNumberGenerator()); func ingest(_ source: CoachSource, _ samples: UnsafePointer<Float>, count: Int, rate: Double); func ingest(lines: [CoachLine]); func setPreset(_ preset: CoachPreset); func audioRetentionChanged(retains: Bool); func drainNow(); func stop() -> CoachSessionSummary; var onHUD: (@Sendable (CoachHUDState) -> Void)? }`. `ingest(source:...)` is realtime safe: it only writes into one of two `FloatRingBuffer(capacityFrames: 960_000)` and stores the rate. A `DispatchSourceTimer` on a serial queue every 50 ms drains both rings, feeds the core, calls `advance()`, appends each event as one JSON line to `<folder>/coach.jsonl` through a `FileHandle`, and calls `onHUD` only when the state changed. `stop()` runs `queue.sync`, drains, closes the file and returns the summary, so the caller may delete the folder right after.
  - `@MainActor @Observable final class CoachController { var hud: CoachHUDState?; var isActive: Bool; nonisolated let relay: CoachRelay; func start(folder: URL, language: String, engine: LiveEngineKind, attendeeCount: Int?, retainsAudio: Bool, lines: @escaping @MainActor () -> [TranscriptLine]); func stop(); func setPaused(_ paused: Bool); func overridePreset(_ preset: CoachPreset); func audioRetentionChanged(retains: Bool) }`. `CoachRelay` is a lock-guarded holder for the current `CoachPump?` so `configureCaptures` can wire `tap.onSamples`/`mic.onSamples` once (`coach.relay.ingest(...)` next to `router.ingest(...)`), mirroring `LiveInboxRouter`. `start` builds the config from Preferences (promoted set, withholding), `CoachStore` (baseline for language and mic name from `AVCaptureDevice.default(for: .audio)?.localizedName ?? "default"`, session index for the cue-off schedule) and the engine kind (`transcriptCues = engine == .apple`). A main-actor 0.5 s timer forwards new `TranscriptLine`s by id as `CoachLine(time:text:isOwn: speaker == "You")`. `stop` records the summary into the baseline and closes the HUD.
  - `@MainActor final class CoachStore { static let shared; var baseline: CoachBaseline; func nextSessionIndex() -> Int; func save() }` persisting to `~/Library/Application Support/Recorder/coach-baseline.json` and `Preferences.coachSessionCount`.
  - `Preferences.coachEnabled: Bool` (default false), `Preferences.coachWithholding: Bool` (default true), `Preferences.coachPromoted: Set<DetectorID>` (default `[.pace]`, stored as raw-value array), `Preferences.coachSessionCount: Int`, `Preferences.coachHUDOrigin: CGPoint?`.
  - `@MainActor final class CoachHUDPanel { static let shared; func show(controller: CoachController); func close() }`: borderless `NSPanel` with `.nonactivatingPanel`, 176 x 30 pt, corner radius 15, `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, `isMovableByWindowBackground = true`, `hidesOnDeactivate = false`, `sharingType = .none`, origin from `Preferences.coachHUDOrigin` else centred under the menu bar on the main screen (6 pt gap), origin saved on `windowDidMove`. `CoachHUDView`: gate dot 8 pt (own green, them blue, overlap purple, silence gray, unknown clear with gray stroke), energy capsule 84 x 8 pt filled to `energy` with a colour from cool gray-blue (0) to warm orange (1), cue glyph slots (pace `tortoise.fill`, soStarts `repeat`, risingEndings `arrow.up.right`, trailingEndings `arrow.down.right`) visible only while lit, amber; whole view at 40% opacity while paused. Context menu: preset picker (labels in a menu are fine), "Hide until next recording".
- [ ] **Step 1: Write failing tests** in `CoachAdapterTests`: `testPumpWritesSessionAndSampleLines` (feed 3 s of `Synth`-style tone on both sources through `ingest`, `drainNow()`, `stop()`: `coach.jsonl` has a `session` line first and 3 `sample` lines per detector present), `testStopIsSynchronousBeforeFolderRemoval` (stop then remove folder then wait 200 ms: folder stays absent), `testRelayIgnoresSamplesWithoutPump`, `testControllerDisabledByDefault` (`Preferences.coachEnabled` false in a fresh suite). The Synth helper is test-target local; copy the minimal tone generator into the test file.
- [ ] **Step 2: Run** `swift test --filter CoachAdapterTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the files and hooks. `RecorderModel` gains `let coach = CoachController()` and calls `coach.start` after `state = .recording` in `startPreparedRecording` when `Preferences.coachEnabled`, `coach.setPaused` in `togglePause`, `coach.stop()` at the top of `saveAndStop` and before the folder removal in `trashAndStop`, and `coach.audioRetentionChanged(retains: false)` in the `deletesPartialAudio` branch of `changeAudioHandling`.
- [ ] **Step 4: Run** `swift test -c release -j 4`. Expected: all previous tests plus the new ones pass. Then `./build.sh` and launch `Recorder.app`, switch the coach on in Preferences, start a recording, and confirm the HUD appears under the camera with a moving energy bar while speaking, and `coach.jsonl` exists in the session folder after stopping.
- [ ] **Step 5: Commit** `Show pace and energy on a floating HUD during recordings`.

### Task 6: "So" at sentence starts (shadow)

**Files:**
- Create: `Sources/VoiceCoach/SentenceStartCounter.swift`
- Modify: `VoiceCoach.swift` (route `ingest(_ line:)`), `CoachHUDPanel.swift` (glyph already reserved)
- Test: `SentenceStartTests.swift`

**Interfaces:**
- Produces: `struct SentenceStartCounter { init(language: String); mutating func observe(_ line: CoachLine) -> (sentences: Int, starts: Int, matched: [String]); var rate: Double?; mutating func shouldTrigger(at t: Double) -> Bool }`. Starter words: `en: ["so"]`, `de: ["so", "also"]`, compared case-insensitively on the first word after stripping punctuation; sentences split on `.`, `!`, `?`, `…`; a line without terminal punctuation counts as one sentence. Only `isOwn` lines count. Rate over the last 10 own sentences; trigger when at least 5 sentences exist and rate >= 0.3, refractory 60 s. Ignored entirely when `config.transcriptCues` is false (sample note `"engine lags"`). Log `values`: `sentences`, `starts`, `rate`; never the text.

- [ ] **Step 1: Write failing tests:** `testCountsSoAtSentenceStartsOnly` ("So we start. Not so fast. So, next." -> 3 sentences, 2 starts), `testGermanAlsoCounts`, `testOtherSpeakersLinesIgnored`, `testTriggerAfterThreeOfTen`, `testRefractorySixtySeconds`, `testDisabledWhenEngineLags` (engine with `transcriptCues = false` never triggers), `testLogNeverContainsText`.
- [ ] **Step 2: Run** `swift test --filter SentenceStartTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** again. Expected: pass.
- [ ] **Step 5: Commit** `Count "so" at his sentence starts in shadow mode`.

### Task 7: Statement endings, rising and trailing (shadow)

**Files:**
- Create: `Sources/VoiceCoach/Intonation.swift`, `Sources/VoiceCoach/EndingsDetector.swift`
- Create: `Tests/VoiceCoachTests/Fixtures/make_contour_fixture.py`, `Tests/VoiceCoachTests/Fixtures/contour-fixture.json`
- Modify: `VoiceCoach.swift`
- Test: `IntonationTests.swift`, `EndingsTests.swift`

**Interfaces:**
- Produces:
  - `enum Contour: String, Codable { case rise, fall, level, unmeasured }`
  - `func cleanF0(_ f0: [Double], reference: Double? = nil) -> [Double]` (semitones re the median voiced f0 or `reference`, NaN for unvoiced, NaN for points more than 7 st from the median of their +/- 3 neighbourhood when that holds at least 3 values; exact port of `coach.py:1159-1173`)
  - `func terminalContour(times: [Double], st: [Double], start: Double, end: Double) -> (Contour, rise: Double, fall: Double)` (exact port of `coach.py:1187-1214`: TERMINAL_WINDOW 0.4, MIN_VOICED 6, RISE_ST 3.0, FALL_ST 1.5, tail 3, 3-point running median)
  - `struct EndingsDetector { init(tuning: CoachTuning); mutating func observe(t: Double, f0: Double, db: Double, own: Bool); mutating func observe(_ line: CoachLine); mutating func tick(t: Double) -> [(DetectorID, values: [String: Double])]; var risingRate: Double?; var trailingRate: Double? }`. Phrase end = end of an own run of at least 0.5 s followed by at least 0.4 s without own frames. Each phrase end is evaluated 0.3 s later with `terminalContour(start: end - 0.4, end: end)` on `cleanF0` of the session's voiced own f0 (reference = session median), and trailing = mean level of own frames in the last 0.3 s of the run < median level of the run's earlier frames - 6 dB. Results stay pending for 3 s; a pending phrase is dropped as a question when an own line whose text ends in `?` arrives with `time` in `[end - 10, end]`. `tick` returns `risingEndings` when at least 5 measured phrases exist in the last 8 and the rise share > 0.30, and `trailingEndings` when at least 3 of the last 8 trail; each with a 45 s refractory. Samples log `measured`, `rises`, `levels`, `falls`, `trailing`, `risingRate`, `trailingRate`.
- [ ] **Step 1: Write the fixture generator** `make_contour_fixture.py`: builds 8 synthetic cases (clear rise, clear fall, level, rise then fall, too few voiced points, a single 9 st octave jump, rise inside the body but level end, NaN gaps), runs coach.py's `clean_f0` and `terminal_contour` on them, writes `contour-fixture.json` with inputs and outputs. Run it with `uv run --python 3.12 --with "numpy<2" python Tests/VoiceCoachTests/Fixtures/make_contour_fixture.py`.
- [ ] **Step 2: Write failing tests:** `testCleanF0MatchesCoachPy` and `testTerminalContourMatchesCoachPy` (every fixture case: contour equal, rise and fall within 1e-6, NaN positions equal), `testSyntheticRisingStatementsTrigger` (6 phrases of 1.5 s speech with a 4 st rise over the last 300 ms, separated by 0.8 s silence -> `risingEndings` trigger), `testFallingStatementsDoNotTrigger`, `testQuestionLineExcludesPhrase`, `testTrailingOffDetected` (last 300 ms 9 dB quieter in 4 of 6 phrases -> `trailingEndings` trigger), `testBleedFramesNeverMakePhrases`.
- [ ] **Step 3: Run** `swift test --filter VoiceCoachTests`. Expected: FAIL.
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run** again. Expected: pass.
- [ ] **Step 6: Commit** `Port coach.py endings and add a trailing-off rate in shadow mode`.

### Task 8: Clips, labels, review window, promotion gate

**Files:**
- Create: `Sources/VoiceCoach/ClipPlanner.swift`, `Sources/Recorder/Coach/CoachReviewWindow.swift`
- Modify: `VoiceCoach.swift` (every trigger registers a clip), `CoachAdapter.swift` (clip writer), `CoachStore.swift` (labels + precision), `PreferencesView.swift` (Coach tab: precision table, promotion toggles, "Review clips" button)
- Test: `ClipPlannerTests.swift`, additions to `CoachAdapterTests.swift`, `CoachStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct ClipPlanner { mutating func register(id: String, detector: DetectorID, at t: Double); mutating func observe(t: Double, gate: GateState) -> [ClipOutcome] }` with `enum ClipOutcome { case keep(ClipRequest), skip(id: String, reason: String) }`. Window `[t - 6, t + 2]` clamped at 0; decided when frame time passes the window end; keep only when every frame in the window is `.own` or `.silence`; skip reason `"other side audible"` or `"gap"`. The engine logs a `clip` event for both outcomes and returns kept requests in `CoachOutput.clips`.
  - Adapter: the pump keeps the last 12 s of native-rate mic samples in a ring on its queue, indexed by sample count, and writes `<folder>/coach-clips/<id>.m4a` (AAC mono, `AVAudioFile`) for each request when `retainsAudio`; otherwise logs a `clip` event with note `"transcript only"`. `audioRetentionChanged(retains: false)` deletes `coach-clips/` and stops writing.
  - `CoachStore`: `func triggers(in folder: URL) -> [CoachTriggerRecord]` (parses `coach.jsonl` trigger and clip lines), `func label(_ id: String, _ label: CoachLabel?, in folder: URL)` writing `<folder>/coach-labels.json` (`[id: "right" | "falseAlarm"]`), `func precision() -> [DetectorID: (labelled: Int, right: Int)]` across all folders under `RecordingsLibrary`'s root, `static func canPromote(labelled: Int, right: Int) -> Bool` (labelled >= 20 and right / labelled >= 0.9). `enum CoachLabel: String, Codable { case right, falseAlarm }`.
  - `CoachReviewWindow.shared.show(model: RecorderModel)`: list of sessions newest first, each trigger row with detector glyph, time, shown or withheld, play button (`AVAudioPlayer`), and a Right / False alarm picker; header table of precision per detector with a promotion toggle that is disabled unless `canPromote` (pace's toggle always enabled, since the spec puts it on the HUD from day one).
- [ ] **Step 1: Write failing tests:** `testClipKeptWhenTapQuietThroughout`, `testClipSkippedWhenThemSpeaksInWindow`, `testClipWindowClampedAtStart`, `testTranscriptOnlyWritesNoClips`, `testDowngradeDeletesClips`, `testClipFileHoldsEightSeconds` (keep-audio pump, own-voice tone, forced trigger through a test hook `CoachPump.forceTrigger(_:)` that is `internal` for `@testable` use: file duration 7.9...8.1 s), `testPrecisionAggregatesLabels`, `testCanPromoteNeedsTwentyAndNinetyPercent`.
- [ ] **Step 2: Run** `swift test --filter "ClipPlannerTests|CoachAdapterTests|CoachStoreTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** again. Expected: pass.
- [ ] **Step 5: Commit** `Keep own-voice clips at triggers and gate promotion on labels`.

### Task 9: Raised-voice proxies (log only), talk share and interruptions

**Files:**
- Create: `Sources/VoiceCoach/ProsodyProxies.swift`, `Sources/VoiceCoach/TurnTaking.swift`
- Modify: `VoiceCoach.swift`, `CoachHUDPanel.swift` (talk share ring around the gate dot when promoted)
- Test: `ProsodyProxiesTests.swift`, `TurnTakingTests.swift`

**Interfaces:**
- Produces:
  - `struct ProsodyProxies { mutating func observe(t: Double, f0: Double, db: Double, own: Bool, syllable: Bool); mutating func tick(t: Double, levelOffsetDB: Double?, rateRatio: Double?) -> Bool; var pitchOffsetST: Double?; var onsetSlope: Double? }`. Pitch offset = median semitones of own voiced f0 over the last 5 s minus the session median. Onset slope = mean dB rise over the 30 ms before each syllable peak in the last 5 s. `tick` returns true (a `raisedVoice` trigger, always shadow because `isPromotable` is false) when pitch offset >= 2.0 st and level offset >= 4.0 dB on 3 consecutive ticks, refractory 60 s. Samples log `pitchOffsetST`, `levelOffsetDB`, `rateRatio`, `onsetSlope`.
  - `struct TurnTaking { mutating func observe(t: Double, gate: GateState); var talkShare: Double?; var interruptedThem: Int; var wasInterrupted: Int }`. Talk share over the last 300 s = (own + overlap) / (own + them + overlap) frames, nil under 30 s of total. `interruptedThem` counts overlap runs of at least 300 ms that start while `.them` had lasted at least 500 ms. `wasInterrupted` counts `.them` onsets during an own run after which own frames stop within 1 s. HUD: `talkShare` set only when `.talkShare` is promoted; `talkShareHigh` when it exceeds `preset.talkShareHigh`. Samples log `talkShare`, `interruptedThem`, `wasInterrupted`.
- [ ] **Step 1: Write failing tests:** `testRaisedPitchAndLevelTriggersShadowOnly` (shown false, note `"shadow"`), `testPitchAloneDoesNotTrigger`, `testTalkShareHalf` (alternating 10 s own and 10 s them for 120 s -> 0.45...0.55), `testTalkShareHiddenUnlessPromoted`, `testInterruptionCounted`, `testBeingInterruptedCounted`, `testNoTextOrPitchOfOthersInSamples` (no sample event from TurnTaking carries a key other than the three above).
- [ ] **Step 2: Run** `swift test --filter VoiceCoachTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** again. Expected: pass.
- [ ] **Step 5: Commit** `Log raised-voice proxies and turn-taking`.

### Task 10: Presets from the calendar, one-click override

**Files:**
- Modify: `Sources/VoiceCoach/CoachPreset.swift`, `CoachAdapter.swift`, `RecorderModel.swift` (pass `activeMeeting?.attendees.count`), `CoachHUDPanel.swift` (context menu already wired, now persists the override for the session), `RecorderPanel.swift` (preset menu while recording with the coach on)
- Test: `CoachPresetTests.swift`

**Interfaces:**
- Produces: `public static func pick(attendeeCount: Int?) -> CoachPreset` (nil -> presentation, 0...2 -> oneOnOne, 3...7 -> group, 8 and more -> presentation). Override calls `VoiceCoach.setPreset`, which logs a `preset` event with note `"override"` (the pick at start logs note `"calendar"`).
- [ ] **Step 1: Write failing tests:** `testPickFromAttendeeCount` (nil, 1, 2, 3, 7, 8, 30), `testOverrideLogsPresetEvent`, `testPresetChangesPaceRatio` (same speech at 1.17 x baseline triggers under `.presentation`, not under `.oneOnOne`).
- [ ] **Step 2: Run** `swift test --filter CoachPresetTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** again. Expected: pass.
- [ ] **Step 5: Commit** `Pick coach presets from the meeting's attendee count`.

### Task 11: Docs and whole-branch verification

**Files:**
- Modify: `README.md` (Voice coach section: what it shows, shadow mode, coin flip and cue-off sessions in plain words, labelling, files written, privacy limits, the open legal points from the spec), `docs/2026-11-14-grill-live-voice-coach.md` (append an "Implemented" table mapping build steps to commits and listing what still needs real calls: step 0 recordings, `sharingType` test during a real share, Teams mic stream check)
- [ ] **Step 1: Run** `swift test -c release -j 4`. Expected: 0 failures; test count = 280 + new tests.
- [ ] **Step 2: Run** `./build.sh`, launch `Recorder.app`, record 60 s with the coach on and speaking, stop, and confirm: HUD visible and draggable, `coach.jsonl` with session, sample, and (after fast speech) trigger lines; with "Keep audio" a `coach-clips/` folder when a trigger fired during a quiet tap; the review window lists the triggers and labels persist.
- [ ] **Step 3: Run** `uv run ... pytest Tools/SpeakerTest -q`. Expected: pass.
- [ ] **Step 4: Scan** all new files for comments (`rg -n "^\s*//|/\*" Sources/VoiceCoach Sources/Recorder/Coach Tests/VoiceCoachTests` and `rg -n "^\s*#" Tools/SpeakerTest Tests/VoiceCoachTests/Fixtures`) and em dashes (`rg -n "\x{2014}" ...`). Expected: no hits.
- [ ] **Step 5: Commit** `Document the voice coach`.

## Deferred (from the spec)

Pace matching, a preset editor, the port to schriftlich.app, volume matching and live room balance (cut), Apple voice processing (rejected: its gain control distorts loudness).
