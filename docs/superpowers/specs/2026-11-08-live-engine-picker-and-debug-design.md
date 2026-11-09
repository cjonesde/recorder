# Live engine picker and debug view

Date: 8 November 2026. Branch: `model-picker`, based on `speaker-profiles` at `9746a80`.

## Intent

The model investigation (see `docs/transcription-performance.md`) narrowed live
transcription to three engines: Apple SpeechTranscriber, Nemotron 3.5 streaming and
Parakeet Ultra. Benchmarks on four public clips cannot settle which one works in real
meetings. The user wants to test all three in real life, on this M1 Pro and later on an
M1 Air and a MacBook Neo, and see *why* an engine does well or badly: does it fit in
memory or push the Mac into swap, how far behind the speech is the text, and how much
audio does it hold and for how long.

Early real-life tests of the Apple engine "performed not so great". That turned out to
be a startup bug (fixed in `9746a80`: the input pump starved while the main thread
started the audio devices). The Apple engine has therefore not had a fair real-life
test yet. This feature is what makes that test, and the comparison, possible.

## Goals

1. A picker with exactly three live engines: **Apple**, **Nemotron**, **Parakeet**.
2. An optional debug view that shows, live, whether the engine fits in memory, how far
   the text lags, how much audio is held and where, and why a recording stopped.
3. A per-recording numbers-only report so engines can be compared after the meeting.
4. Every engine is fed by the same capture and pump path, so differences come from the
   engines, not the plumbing.

## Non-goals

- Running two engines at once, or replaying one meeting through several engines.
- Automatic engine choice.
- Whisper as a live engine (it stays only for the "keep audio and polish" saved-file pass).
- Fixing the ~1.5 s UI freeze when pressing Record (separate small fix; the debug view
  measures it).
- Shipping all three engines long term. This is a test phase; the winner is chosen later.

## Anti-goals (a failure even if it technically works)

- Debug numbers that look precise but measure the wrong thing (for example, Recorder's
  own memory presented as "the engine's memory" for Apple, whose recognizer runs in a
  separate system process).
- Any audio written to disk in transcript-only mode, including inside the debug report.
- Buffering microphone or desktop audio while a model downloads or compiles.
- A generic "could not keep up" message that hides which limit tripped.

## Decided by the user

- The three engines are Apple, Nemotron, Parakeet. Parakeet means **Parakeet Ultra**.
- Switching is manual: pick an engine, record, stop. To compare, record again with
  another engine, or use different meetings. No parallel transcription.
- No switching engines mid-recording. An engine must be fully loaded before capture
  starts.
- The speech-language picker applies only to Apple. Nemotron and Parakeet detect the
  language automatically.
- Whisper stays as-is for the polish mode.
- During this test phase Nemotron and Parakeet may hold the audio they need to work
  (roughly 10 to 15 s in memory). The debug view must show exactly how much and how old.
  Apple keeps its current tight bounds.
- Nemotron and Parakeet may **fall behind a bit** without stopping the recording. This
  is documented as a constraint of those engines, not hidden.
- No engine may accumulate the whole conversation. It must stay live transcription:
  audio that has been turned into final text is deleted, and what is held stays bounded
  however long the meeting runs.
- Debug placement: a **drawer** in the recorder panel with a **Pop out** button that
  opens a fuller window with history charts and an event log.

## Builder's calls already made (by the assistant, open to the user's correction)

- Debug info is **off by default**, switched on by a "Show debug info" toggle in
  Settings. When off, the drawer, the pop-out and the report do not exist.
- The pop-out window floats above other windows so it stays visible over a video call.
- With debug on, each recording writes a `debug.json` next to its transcript. Numbers
  and events only, never audio. The pop-out has a "Copy summary" button for a short text
  version.
- Nemotron runs with blank-span recovery **on**, on the Neural Engine, 560 ms chunks:
  its best benchmark profile (21.5% vs 44.3% word errors without recovery; 0.99 s first
  word vs 6.79 s on GPU).
- Parakeet runs through FluidAudio's `SlidingWindowAsrManager` with
  `SlidingWindowAsrConfig.streaming` (11 s chunks, 2 s left and right context, 1 s
  hypothesis updates, confirmation after 10 s), using `AsrModelVersion.ultra`.
- Only one engine is resident at a time. Selecting another engine unloads the previous
  one, so memory numbers belong to the engine under test.
- You/Them labels use the existing channel-energy attribution for all three engines.
- FluidAudio is added to the app at the version the benchmark pinned:
  `exact: "0.18.0"`, `traits: []`.
- The transcript header names the engine that produced the text. Today it prints
  ``WhisperKit `Apple SpeechTranscriber (en_US)` ``, which is wrong. When the polish
  pass replaces the live text, the header names Whisper and the model, and
  `transcript.json` also records which live engine ran during the recording. The new
  field is optional so older `transcript.json` files still load.
- Nemotron's live text is split into timed lines while recording. Its partial callback
  is a bare string, so lines come from `getTokenTimings()`: text up to a pause of at
  least 0.8 s, or a sentence-ending punctuation token, becomes a confirmed line with that
  token range's start and end. The trailing part stays the hypothesis. This gives all
  three engines the same transcript shape (timed lines with You/Them labels) and makes
  "text behind (final)" mean the same thing for each. Parakeet uses its own
  `isConfirmed` updates and their `tokenTimings`. If a safety stop hits, Nemotron's
  unconfirmed tail is saved with the existing `[unconfirmed]` prefix.
- Before the polish pass loads Whisper, the live engine is unloaded, so an 8 GB Mac
  never holds both. The next recording reloads it (a cached load, not a first compile).
- The engine picker is hidden while "Stream the transcript live" is off, because no
  live engine runs then.
- Debug sampling starts when Record is pressed, not when capture starts. Samples and
  events are tagged with a phase (preparing, recording, finishing), and the charts
  shade the preparing phase. A first-time model compile is then visible on its own and
  is not blamed on the recording, nor hidden.
- `Package.swift` moves from tools-version 6.0 to 6.2, needed for FluidAudio's
  `traits: []`.

## The three engines

| | Apple | Nemotron | Parakeet |
|---|---|---|---|
| Runtime | `SpeechAnalyzer` + `SpeechTranscriber` (Speech framework) | FluidAudio `StreamingNemotronMultilingualAsrManager` | FluidAudio `SlidingWindowAsrManager` |
| Model | Apple language asset | `nvidia/nemotron-3.5-asr-streaming-0.6b`, Latin vocab, 560 ms | Parakeet Ultra |
| Language | user picks (existing picker) | automatic | automatic |
| Preparation | asset install if missing, then `prepareToAnalyze` | download, then Core ML / ANE compile (27 to 29 s first load measured) | download, then Core ML / ANE compile |
| Audio held (expected) | app side ≤ 0.5 s per source plus ≤ 4 queued 100 ms chunks; Apple-internal unknown | up to ~9.5 s in its input array, up to 15 s plus 240 ms pre-roll with recovery | sliding window, about 15 s |
| Text cadence | provisional and final results, sub-second | partial transcript per chunk; final at finish | rough hypothesis about every 1 s; confirmed text after ≥ 10 s of context |

The benchmark tool shows working call sequences for both FluidAudio engines:
`Tools/ASRBenchmark/Sources/ASRBenchmark/NemotronStreamingBenchmark.swift` and the
`parakeet` branch of `main.swift` (both at commit `5647f5e`).

## How a test session works

1. The panel shows an engine picker (Apple / Nemotron / Parakeet) above the live
   transcript, and the language picker only when Apple is selected. The same choice is
   in Settings → Transcription. The choice persists.
2. The picker is disabled while preparing, recording or finishing.
3. Pressing Record prepares the selected engine first: language asset or model
   download, compile, load. The panel shows "Preparing Parakeet…" with progress when the
   engine reports it. The user can cancel. Capture starts only after preparation
   succeeds; a preparation failure leaves the app idle with a readable message. This is
   the existing Apple lifecycle (`docs/apple-streaming.md`), extended to all engines.
4. While recording, all three engines receive the same 16 kHz mono mix through
   `StreamingAudioInput` and `StreamingInputPump`.
5. Save finalizes the engine and writes `transcript.md` / `transcript.json` as today,
   with the engine named in the header, and `debug.json` when debug is on.
6. A loaded engine stays loaded between recordings until the user selects another
   engine, so the second recording does not pay the compile cost again. The debug view
   shows whether a load was first-time or cached.

## Architecture

### Engine boundary

Introduce one live-engine interface that `LocalTranscriptionEngine` drives, with three
implementations. The current `AppleLiveTranscriber` becomes the Apple implementation
with its behavior unchanged. Shape (names are the builder's choice):

- `prepare(language:progress:) async throws`: everything that may download or compile.
- `startSession()`: begin accepting chunks; capture starts after this returns.
- chunk delivery from the pump, synchronous and non-blocking (see below).
- `finish() async -> SessionResult` and `cancel()`, with the existing generation guard
  so late results from a cancelled session never reach a new transcript.
- observable transcript state (confirmed lines plus hypothesis), as today.
- `diagnostics` snapshot (see the debug section).
- `unload()`.

`StreamingInputPump` calls a synchronous `deliver`. FluidAudio managers are actors with
async `process` / `streamAudio` calls, so each FluidAudio engine needs a bounded handoff
between the pump and its actor. Apple keeps its current bound (at most four 100 ms
chunks). Nemotron and Parakeet may lag (user decision), with these limits (the numbers
are the assistant's call):

- The handoff to a FluidAudio engine holds at most **10 s** of audio waiting to be
  processed. Exceeding it is the named safety stop "engine fell more than 10 s behind".
- Their finalization watchdog is 30 s instead of 10 s, because Nemotron recovery can
  replay up to 15 s and Parakeet flushes a full window at the end.
- Consumed handoff chunks are erased and released as soon as the engine call that took
  them returns.

### Bounded audio, no whole-conversation buffer

Each engine's total held audio (app handoff plus the engine's own buffers) must stay
under a fixed ceiling for the whole recording, whatever its length:

| Engine | Ceiling on audio held |
|---|---|
| Apple | 0.5 s per source plus 0.4 s queued, app side (unchanged) |
| Nemotron | 10 s handoff plus its compacted input array (about 9.5 s) and recovery window (15 s plus 240 ms) |
| Parakeet | 10 s handoff plus one sliding window (chunk plus left and right context, about 15 s) |

Before building on FluidAudio, the builder confirms in the 0.18.0 source that
`StreamingNemotronMultilingualAsrManager` compacts consumed samples and that
`SlidingWindowAsrManager` drops audio behind its window. If either keeps everything it
was given, that engine is not acceptable as-is: stop and report rather than shipping it.
A wrapper that feeds the library only bounded windows is an acceptable fix if it keeps
transcript quality.

This is documented as a constraint in `docs/apple-streaming.md` (or a new
`docs/live-engines.md`): Nemotron and Parakeet hold up to roughly 25 to 35 s of audio in
memory, cannot erase it, and their text can lag by up to 10 s before the recording
stops.

### Audio ownership per engine

- Apple: unchanged. Owned PCM with an erasing deallocator.
- Nemotron and Parakeet take Swift `[Float]` arrays or `AVAudioPCMBuffer`s that the
  library copies and keeps. The app cannot erase those copies. That is accepted for the
  test phase (user decision) and must be visible: the debug view reports the held
  amount for these engines as *estimated from engine configuration and samples fed*, not
  as measured, and says that erasure is not guaranteed.
- Transcript-only mode still writes no audio file for any engine.

### Named safety stops

Replace the single `StreamingSpeechError.inputOverrun` with distinct reasons, each
carried into the transcript's `[incomplete: …]` marker, the panel status, the debug
event log and `debug.json`:

| Reason | Where it fires today |
|---|---|
| desktop audio waited longer than 0.5 s | `StreamingAudioInput.ingest` / `drain` age check, desktop channel |
| microphone audio waited longer than 0.5 s | same, mic channel |
| handoff full | `StreamingAudioInput.ingest` capacity check |
| engine queue full | Apple `AsyncStream` yield `.dropped` |
| engine fell more than 10 s behind | the new FluidAudio handoffs |
| desktop capture ring overflowed | `SystemAudioTap` writer thread, `ring.totalDropped > 0` |
| engine error | engine result stream or analysis throws (message included) |
| finalization timed out | the 10 s finalization watchdog |

User-facing wording is the builder's; the reason identity must survive to the report.

## Debug view

Visible only when "Show debug info" is on. Each value is labeled as **measured**,
**estimated** or **unknown**; the UI never shows an estimate as if it were measured.

### Drawer (inside the panel, under the live transcript)

A disclosure titled "Debug" with a "Pop out ↗" button and about six rows, colored
green / yellow / red where a threshold is meaningful:

1. Text behind live audio: rough / final, in seconds.
2. Recorder memory.
3. Memory pressure and swap growth since Record.
4. Oldest audio held in memory.
5. Audio files on disk for this recording: none / list.
6. Safety stops this recording: count, last reason.

### Pop-out window

A small floating window with:

- Header: engine, language (Apple) or "auto", compute units, recording time.
- Engine block: load time, first-time vs cached load, model size on disk.
- Charts over the whole recording (Swift Charts is fine): text lag (rough and final),
  memory (Recorder, Apple speech service when Apple is selected, swap growth), oldest
  audio held.
- Per-engine rows (below).
- Event log with timestamps: preparation start/end, capture started, longest main-thread
  stall at start, first text, first final text, each safety stop, finalization duration.
- "Copy summary" button.

### Metrics and how to get them

| Metric | Definition | Source (builder verifies) |
|---|---|---|
| Recorder memory | physical footprint of this process | `task_info` `TASK_VM_INFO`, `phys_footprint` |
| Apple speech service memory | footprint of the process that runs Apple recognition, Apple engine only | find the process serving `com.apple.speech.localspeechrecognition` during a session; `proc_pid_rusage` `ri_phys_footprint`. If it cannot be identified or read, show "unknown", never Recorder's number |
| Memory pressure | normal / warning / critical | `DispatchSource.makeMemoryPressureSource` plus `sysctl kern.memorystatus_vm_pressure_level` for the current level |
| Swap growth | swap used now minus at Record; plus swap-ins and swap-outs since Record | `sysctl vm.swapusage`; `host_statistics64` `HOST_VM_INFO64` `swapins` / `swapouts` |
| Text behind (rough) | latest submitted audio time minus end time of the latest provisional result | engine results vs pump position |
| Text behind (final) | same, against the latest final result | engine results vs pump position |
| First word / first final | wall time from capture start to first non-empty provisional / final text | engine results |
| Oldest audio held | age of the oldest sample the app or engine still holds | app side: `StreamingAudioInput` oldest timestamp plus engine queue; Nemotron / Parakeet: estimated from config and samples fed; Apple internal: unknown |
| Main-thread stall | longest gap of a main-queue heartbeat, measured from a background timer | heartbeat |
| Audio files | files present in the session folder that are not transcript or debug files | directory listing at sample time and at save |

Sampling once per second is enough for charts; the drawer may refresh at the same rate.
Sampling must not run when debug is off.

### Per-engine rows

- **Apple:** speech service memory; the existing buffer-release timing (median and max
  lifetime of submitted buffers, from the erasing deallocator); Apple-internal audio
  held shown as "unknown".
- **Nemotron:** estimated input buffer held; whether recovery replayed audio and how
  much (if FluidAudio exposes it; otherwise state that it is not observable).
- **Parakeet:** window held (chunk plus contexts); time of each window decode and its
  duration.

### `debug.json`

Written next to the transcript when debug is on, in every audio-handling mode. Contains:
app build (git commit if available), machine model, RAM, macOS version, engine and its
settings, language, load timings, the per-second samples, the event log, safety stops,
and final summary values. No audio, no transcript text. Schema details are the
builder's; it must be stable enough for a small script to compare recordings.

## Constraints

- macOS 26+ (already the minimum).
- Must run on 8 GB machines (MacBook Neo, M1 Air), so one engine resident at a time and
  no extra model loaded for debug purposes.
- Keep the existing Apple audio-lifetime guarantees exactly as documented in
  `docs/apple-streaming.md`.
- No code comments (repository owner's rule); explanations go in commit messages.
- Existing tests keep passing: `swift test -c release -j 4` (130 tests, 16 opt-in
  skipped at `9746a80`).

## Verification expected

- Unit tests: engine selection persistence and lock while recording; named safety stop
  reasons propagate to transcript marker and report; metrics sampler math with injected
  readings; `debug.json` written only when debug is on and containing no audio or
  transcript text; FluidAudio handoff overflow becomes a named stop.
- Replay verification per engine on the public bilingual fixture, extending the pattern
  of `AppleStreamingVerificationTests` (opt-in env vars, real-time pacing).
- Bounded-audio check per FluidAudio engine: a real-time replay of at least 5 minutes
  (looped public fixtures) where the held-audio measure never exceeds the ceiling above
  and does not trend upward. This is the test for "no whole-conversation buffer".
- Real-device check per engine, extending `LiveRecordingStaysUpTests`
  (`RECORDER_LIVE_MODES=1`): recording still running after 6 s, no safety stop.
- `ModeMatrixIntegrationTests` still pass: transcript-only leaves no audio for every
  engine.
- Manual: build with `./build.sh`, record a short real call with each engine and debug
  on, check the drawer, pop-out and `debug.json` by eye.

## Left to the builder

- Type and file names, the engine protocol's exact signatures.
- Exact thresholds for green / yellow / red.
- Progress reporting granularity during model download and compile.
- Where FluidAudio models are cached (alongside `WhisperModels` under
  `~/Library/Application Support/Recorder/` is the expected place).
- `debug.json` field names.
- Whether the drawer's open/closed state persists.

## Open risks

- FluidAudio 0.18.0 may not expose internal buffer sizes or recovery activity; then
  those rows say "not observable" rather than guessing.
- The Apple speech service process may not be readable from a non-sandboxed, ad-hoc
  signed app; then its memory shows "unknown" and the report says so.
- First-time ANE compilation can stall when `ANECompilerService` is busy (seen during
  the investigation). Preparation must stay cancellable.
- Adding FluidAudio enlarges the app and its build time.
