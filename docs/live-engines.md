# Live engines: FluidAudio retention audit

Audited on 8 November 2026 against FluidAudio 0.18.0 (tag `v0.18.0`, commit
`e15287985625dbf544a343df679436789ffb03fb`), resolved by
`.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.0", traits: [])`.
The question is whether the two FluidAudio managers used for live text keep only a bounded
amount of the audio they are given, or everything.

Paths below are relative to `.build/checkouts/FluidAudio/Sources/FluidAudio/`:

- `NM` is `ASR/Parakeet/Streaming/Nemotron/StreamingNemotronMultilingualAsrManager.swift`
- `NM+Rescue` is `ASR/Parakeet/Streaming/Nemotron/StreamingNemotronMultilingualAsrManager+BlankRescue.swift`
- `NM+Shared` is `ASR/Parakeet/Streaming/Nemotron/StreamingNemotronMultilingualAsrManager+Shared.swift`
- `SW` is `ASR/Parakeet/SlidingWindow/SlidingWindowAsrManager.swift`

All sample counts are 16 kHz mono Float32 (4 bytes per sample, 64 KB per second).

## Gate result

| Engine | Result | Evidence |
|---|---|---|
| Nemotron (`StreamingNemotronMultilingualAsrManager`) | PASS, bounded | Consumed prefix of `audioBuffer` is dropped every 17 chunks (`NM:1007-1010`); the recovery span is capped at 15 s and discarded on overflow (`NM+Rescue:47`, `NM+Rescue:175-180`). |
| Parakeet (`SlidingWindowAsrManager`) | PASS, bounded, with an unbounded input queue the app must control | `sampleBuffer` is trimmed after every window to 13 s behind the next window centre (`SW:372-377`). The `streamAudio` queue in front of it is an unbounded `AsyncStream` (`SW:79`, `SW:219`). |

Neither manager keeps all the audio it was given. Both hold more than the design spec's
ceiling table assumed for Parakeet (see "Corrections to the spec" below).

## Nemotron: `StreamingNemotronMultilingualAsrManager`

### Sample buffers and when they are trimmed

1. `audioBuffer: [Float]` with read offset `audioBufferOffset` (`NM:90-91`).
   - `process(samples:)` appends every call's samples (`NM:983`), then consumes whole
     chunks by advancing the offset (`NM:990-1003`).
   - Compaction: once `audioBufferOffset > 16 * chunkSamples`, the consumed prefix is
     removed with `removeFirst` and the offset reset (`NM:1007-1010`). That fires after
     the 17th consumed chunk.
   - `chunkSamples = chunkMelFrames * 160` (`ASR/Parakeet/Streaming/Nemotron/NemotronMultilingualStreamingConfig.swift:51`),
     read from the variant's `metadata.json` (same file, line 81). For the 560 ms variant
     that is 56 frames, 8,960 samples per chunk.
   - Maximum size: up to 16 consumed chunks plus an unconsumed remainder under one chunk
     survive a call, and the next call appends before compacting. With 560 ms chunks and
     app calls of at most one chunk each, the array peaks under 18 chunks, 161,280
     samples, about 10.1 s. A single large `process(samples:)` call adds its full length on
     top, so the app must feed small slices.
   - Transient copies per chunk: the chunk itself (`NM:993`) and the look-ahead next chunk
     (`NM:996-1001`), 2 x 0.56 s, released after the iteration.
   - `finish()` clears the array only when a remainder exists (`NM:1031-1044`). When the
     fed audio ends exactly on a chunk boundary, up to 16 consumed chunks (about 9 s) stay
     in the array until `reset()` or `cleanup()`.
   - `appendAudio(_:)` (`NM:958-960`) appends to the same array without processing it.
     Calling it repeatedly would grow the buffer without limit. The app must not use it;
     feed `process(samples:)` instead.

2. Blank-span recovery buffers (issue #838), only when recovery is enabled
   (`NM+Rescue:114`):
   - `rescuePreRollTail: [Float]` (`NM:237`): last 240 ms of silence before a speech
     span, capped at `preRollWindows * 1280 = 3,840` samples (`NM+Rescue:45`,
     `NM+Rescue:181-186`). It is not cleared when a span opens, only when the span
     closes (`NM+Rescue:210`), so it coexists with the span buffer.
   - `rescueSpanAudio: [Float]` (`NM:235`): starts as a copy of the pre-roll
     (`NM+Rescue:170`) and grows by one 80 ms window per speech or short-silence window
     (`NM+Rescue:175-176`). When it exceeds `maxSpanSamples = 15 * 16000 = 240,000`
     (`NM+Rescue:47`), it is emptied and marked overflowed, and no more audio is
     appended for that span (`NM+Rescue:177-180`). Peak is 241,280 samples (15.08 s) for
     the one window before the overflow check clears it. A span closes after 160 ms of
     silence (`NM+Rescue:44`, `NM+Rescue:189-191`), which empties the buffer
     (`NM+Rescue:198-205`).
   - Transient copy during a recovery decode: `closeSpanAndMaybeRescue` keeps the span in
     a local (`NM+Rescue:198`), and `rescueDecode` makes a padded copy, adding up to two
     chunks of zeros (`NM+Rescue:317-324`). During that decode up to about 15 s plus
     about 16.1 s are alive at once. Both are released when the decode returns.
   - `resetRescueState()` (`NM+Rescue:468-482`) clears both arrays and is called from
     `resetStates()` (`NM:954`), so `reset()` and `cleanup()` clear them.

### Nemotron ceiling

| State | Audio held by the library |
|---|---|
| Steady, recovery off | about 10.1 s (`audioBuffer`) plus 1.1 s transient chunk copies |
| Steady, recovery on | about 10.1 s plus 15.08 s span plus 0.24 s pre-roll, about 25.4 s |
| During a recovery decode | about 10.1 s plus 15 s plus 16.1 s, about 41 s for the length of one re-decode |

These figures assume the app passes at most one chunk (560 ms) per `process(samples:)` call.
The app's own 10 s handoff sits in front of this.

### Recovery switch

There is no API. Recovery is controlled by the environment variable
`FLUIDAUDIO_DISABLE_BLANK_RESCUE`, read once into a `nonisolated static let`
(`NM+Rescue:35-41`):

- unset: recovery on (default)
- `"0"`, `"false"` or `"no"` (case-insensitive): recovery on
- any other value: recovery off

Because it is a lazily initialised static, the value is fixed the first time any manager
reads it (the first `processChunkTracked`, `NM+Rescue:114`), for the life of the process.
To guarantee recovery on, call `setenv("FLUIDAUDIO_DISABLE_BLANK_RESCUE", "0", 1)` before the
first Nemotron chunk is processed, or leave it unset. Recovery also requires
`rescueRmsThreshold > 0`, which defaults to 0.0025 and is overridable by
`FLUIDAUDIO_RESCUE_RMS_THRESHOLD` (`NM+Rescue:26-33`). The public counters
`detectedBlankSpanCount` and `blankRescueCount` (`NM:243`, `NM:247`) report recovery
activity for the debug view.

With recovery on, the partial callback only publishes settled text: an open blank span can
hold back later text by the 15 s span cap plus the rest of that chunk (`NM:5-10`,
`NM+Rescue:85-109`).

### Text, token timings and the word join rule

- Live text: `setPartialCallback(_:)` (`NM:296-298`) delivers the cumulative transcript
  (`NemotronMultilingualPartialCallback`, `NM:11`), only when it changes. Polling
  alternative: `getPartialTranscript()` (`NM:1100-1107`).
- Token timings: `getTokenTimings()` (`NM:1125-1127`) returns the accumulated
  `[TokenTiming]`; `finishWithTokenTimings()` (`NM:1116-1119`) returns final text and
  timings. `startTime` and `endTime` are absolute seconds from the start of fed audio,
  80 ms per encoder frame (`ASR/Parakeet/Streaming/Nemotron/StreamingNemotronMultilingualAsrManager+Decode.swift:535-544`).
- Join rule: `TokenTiming.token` is the raw SentencePiece piece including the `▁`
  word-boundary marker (`+Decode.swift:539`, via `rawToken(for:)` at
  `ASR/Parakeet/Streaming/Nemotron/NemotronMultilingualTokenizer.swift:70-77`). A token
  whose text starts with `▁` begins a new word; other tokens continue the current word.
  Replace `▁` with a space (or strip it at word start) and concatenate. Language-tag
  tokens are excluded from timings (`+Decode.swift:534`). The tokenizer also collapses
  double spaces caused by a standalone `▁` token (`NemotronMultilingualTokenizer.swift:51-57`),
  so a token that is exactly `▁` must not produce an empty word. The
  `finishWithTokenTimings` doc says the same: group by the SentencePiece word-boundary
  marker (`NM:1110-1113`).
- `getTokenTimings()` grows with the transcript (token metadata, not audio) until
  `finish()` or `reset()`.

### Lifecycle, unload, compute units

- Compute units: `init(configuration:)` defaults to `.cpuAndNeuralEngine` (`NM:285-290`,
  `Shared/MLModelConfigurationUtils.swift:11-16`). `loadFromShared(_:)` adopts the shared
  bundle's configuration (`NM+Shared:238-242`), so pass a `.cpuAndNeuralEngine`
  `MLModelConfiguration` to `downloadAndPreloadShared(configuration:)` (or leave it nil).
- Per session: `reset()` (`NM:816-840`) clears `audioBuffer`, tokens, timings and recovery
  buffers but keeps models.
- Unload: `cleanup()` (`NM:890-905`) calls `reset()` and then drops the model references
  and caches. The `SharedNemotronMultilingualModels` bundle holds the `MLModel` handles
  too (`NM+Shared:82-85`), so the app must also drop its own reference to the shared
  bundle to free the about 1.5 GB of models (`NM+Shared:77-79`).
- Recommended stop sequence: `finishWithTokenTimings()`, then `reset()` (to clear the
  boundary case above), then `cleanup()` when unloading.

### Download and cache

- `downloadAndPreloadShared(languageCode:chunkMs:to:configuration:progressHandler:)`
  (`NM+Shared:343-353`) calls `downloadVariant` then `preloadShared(from:configuration:)`.
- `downloadVariant(languageCode:chunkMs:to:progressHandler:)` (`NM+Shared:359-436`):
  - Root: the `to:` URL, else `~/Library/Application Support/FluidAudio/Models`
    (`NM+Shared:369-375`).
  - Files go to `<root>/nemotron-multilingual/<latin|multilingual>/<chunkMs>ms/`
    (`NM+Shared:366-378`; folder name from `ModelNames.swift:431-432`).
    Latin-script languages (en, es, fr, it, pt, de) use `latin`, everything else
    `multilingual` (`NM+Shared:324-329`).
  - Existing `metadata.json` means cached, no download (`NM+Shared:382`).
- For Recorder pass `to: ~/Library/Application Support/Recorder/SpeechModels`. The
  560 ms latin variant then lives at
  `SpeechModels/nemotron-multilingual/latin/560ms/`.
- In-flight downloads are written next to the destination as `<file>.partial`
  (`Shared/Download/FileDownloader.swift:74`).

## Parakeet: `SlidingWindowAsrManager`

Configuration `SlidingWindowAsrConfig.streaming` (`SW:805-812`): chunk 11 s, left context
2 s, right context 2 s, confirmation after 10 s of context at confidence 0.80. Samples:
chunk 176,000, left 32,000, right 32,000 (`SW:901-904`). The assembled window is 15 s,
exactly the model maximum of 240,000 samples (`Shared/ASRConstants.swift:12`, `SW:914-924`).
`hypothesisChunkSeconds` is stored but not used by this manager.

### Sample buffers and when they are trimmed

1. Input queue: `inputSequence: AsyncStream<AVAudioPCMBuffer>` (`SW:16-17`), created with
   `AsyncStream.makeStream()` and the default unbounded buffering policy (`SW:79-81`).
   `streamAudio(_:)` only yields into it and returns immediately (`SW:218-220`). The
   recognizer task takes one buffer at a time, resamples it, then processes every window
   that buffer completes before taking the next (`SW:187-193`). Buffers fed while a
   window is being decoded wait here. There is no public way to read the queue depth,
   so it is bounded only by how fast the app feeds compared with how fast the model
   decodes. The app cannot use `streamAudio` itself for backpressure.

2. `sampleBuffer: [Float]` with absolute index `bufferStartIndex` and `nextWindowCenterStart`
   (`SW:45-47`).
   - `appendSamplesAndProcess` appends each resampled buffer (`SW:346`) and processes a
     window whenever the buffer reaches `nextWindowCenterStart + chunk + right` (`SW:355`).
   - After each window: the centre advances by one chunk (`SW:368`), and everything before
     `nextWindowCenterStart - left - chunk` is removed (`SW:372-377`). The same trim runs
     in `flushRemaining` (`SW:420-425`).
   - Maximum size: after a trim the buffer starts 13 s before the next centre and the next
     window fires when it reaches 13 s past the centre. So it peaks at 26 s (416,000
     samples) plus the overshoot of the last appended input buffer.
   - Transient copies per window: the 15 s window (`SW:364`), and a frame-aligned,
     zero-padded copy of up to 240,000 samples inside `transcribeChunk`
     (`ASR/Parakeet/SlidingWindow/TDT/AsrManager+Transcription.swift:448-450`). Both are
     released after the window.
   - `finish()` does not clear `sampleBuffer` (`SW:237-289`). `cleanup()` does not clear it
     either (`SW:320-325`). Only `reset()` empties it (`SW:299`).

### Parakeet ceiling

| State | Audio held by the library |
|---|---|
| Steady | up to 26 s in `sampleBuffer`, plus whatever waits in the input queue |
| During a window decode | the above plus up to 30 s of transient window copies (15 s window, 15 s padded copy) |

### Updates, `isConfirmed`, `tokenTimings`

- Stream: `transcriptionUpdates: AsyncStream<SlidingWindowTranscriptionUpdate>` (`SW:223-233`).
  Each access creates a new stream and replaces the previous continuation, so read it
  exactly once per manager, before `startStreaming`. There is no callback API.
- One update per processed window, yielded at `SW:576-588`. The first update arrives once
  13 s of audio have been fed (chunk plus right context), then one per 11 s of audio,
  plus decode time. `flushRemaining` emits the tail windows after `finish()` (`SW:384-428`).
- No text for the first 13 s: Parakeet shows nothing, not even a provisional hypothesis, for
  the first 13 s of a recording. `appendSamplesAndProcess` decodes a window only once the fed
  audio reaches `nextWindowCenterStart + chunk + right`, with the centre starting at 0
  (`SW:354-365`), so the first window needs 11 s plus 2 s. `hypothesisChunkSeconds` is stored
  in the config but never read by `SlidingWindowAsrManager`, so there is no faster partial
  path. Measured on the bilingual fixture: first text at 13.4 s.
- A window that throws yields no update (`SW:590-603`) but still advances the window centre,
  so the app's window count would stall. Recorder stops the session with an engine error
  when an expected window update is 9 s overdue, before the 10 s handoff overflows.
- Fields (`SW:933-968`): `text` (this window's new text only, not cumulative: built from
  the current window's tokens, `SW:495-505`), `isConfirmed` (confidence at least 0.80 and
  at least 10 s of audio received, `SW:530-533`), `confidence`, `timestamp` (wall clock),
  `tokenIds`, `tokenTimings`, and the vocabulary-boost fields `ctcDetectedTerms`,
  `ctcAppliedTerms`, `ctcReplacements` (nil unless boosting is configured). The
  convenience `tokens` returns `tokenTimings.map(\.token)`.
- `tokenTimings` are in absolute seconds: window timestamps are shifted by the window's
  start frame (`SW:487-490`, `SW:705-712`). Token text is normalised with `▁` replaced by
  a space (`ASR/Parakeet/SlidingWindow/TDT/AsrManager.swift:560-562`, applied in
  `AsrManager+TokenProcessing.swift:90-92`), so a leading space starts a new word.
- Seam word: a window can re-decode the previous window's last word in full and retire it
  from the manager's internal state (`SW:465-485`). The update does not announce the
  retirement; the new update's text and timings simply begin with that word again. A
  consumer that appends update text will duplicate that word unless it replaces earlier
  words whose `startTime` is at or after the first new token's `startTime`.

### `AudioSource` when feeding `streamAudio` directly

`AudioSource` has two cases, `.microphone` and `.system` (`Shared/AudioSource.swift:3-6`).
`SlidingWindowAsrManager` only stores and logs it (`SW:25`, `SW:54-56`, `SW:165`,
`SW:315`); it changes no behaviour. Call `startStreaming()` with the default `.microphone`
(`SW:156`). `streamAudio` accepts `AVAudioPCMBuffer` in any format and converts to 16 kHz
mono internally (`SW:190`), so the app must hand over an `AVAudioPCMBuffer` copy that it
cannot later erase.

### Lifecycle, unload, compute units

- Load: `AsrModels.downloadAndLoad(to:configuration:version:...)`
  (`ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift:797-818`) with `version: .ultra`
  (`AsrModels.swift:14`), then `SlidingWindowAsrManager(config: .streaming)` and
  `loadModels(_ models:)` (`SW:138-146`). Default compute units are `.cpuAndNeuralEngine`
  with the preprocessor on CPU (`AsrModels.swift:658-661`, `AsrModels.swift:722-737`).
- Single use: the input stream is created in `init` (`SW:79-81`) and finished by
  `finish()` (`SW:241`) or `cancel()` (`SW:329`). A finished stream cannot be restarted,
  so create a new `SlidingWindowAsrManager` per recording. Models can be shared by
  passing the same `AsrModels` to each new manager.
- Stop: `finish()` (`SW:237-289`) waits for the queue to drain and returns final text.
  `cancel()` (`SW:328-334`) finishes the input, cancels the task and ends the update
  stream without a result.
- Unload: `cleanup()` (`SW:320-325`) calls `cancel()` and `AsrManager.cleanup()`
  (`ASR/Parakeet/SlidingWindow/TDT/AsrManager.swift:272-281`), which drops the models.
  It leaves `sampleBuffer` and any queued input buffers inside the actor. Call `reset()`
  (`SW:292-316`) and then drop the manager reference so the actor and its stream are
  deallocated.

### Download and cache

- `AsrModels.download(to:force:version:encoderPrecision:progressHandler:)`
  (`AsrModels.swift:689-755`). If `to:` is nil the target is
  `~/Library/Application Support/FluidAudio/Models/parakeet-ultra`
  (`AsrModels.swift:890-891`, `Shared/MLModelConfigurationUtils.swift:37-47`; folder
  name `parakeet-ultra` from repo `FluidInference/parakeet-ultra-coreml`,
  `ModelNames.swift:21`, `ModelNames.swift:187-188`, `ModelNames.swift:482-483`).
- Gotcha: the `to:` URL is treated as the model folder itself. Files are written to
  `to.deletingLastPathComponent()/parakeet-ultra/` (`AsrModels.swift:699`,
  `AsrModels.swift:740-747`, `AsrModels.swift:263-266`,
  `Shared/Download/ModelHub.swift:331`). For Recorder pass
  `to: ~/Library/Application Support/Recorder/SpeechModels/parakeet-ultra`. Passing
  `SpeechModels` itself would write to `Application Support/Recorder/parakeet-ultra`.
- Cached models are detected by `modelsExist(at:version:)` and reused
  (`AsrModels.swift:701-704`).

## What later tasks need

- Nemotron: feed `process(samples:)` in slices of at most one chunk (560 ms) from the app's
  bounded handoff. `process` awaits decoding, so the handoff applies backpressure
  naturally. Never call `appendAudio(_:)`.
- Nemotron recovery: ensure `FLUIDAUDIO_DISABLE_BLANK_RESCUE` is unset or `"0"` before the
  first chunk in the process; there is no per-manager switch.
- Nemotron words: group `getTokenTimings()` by tokens starting with `▁`.
- Parakeet: `streamAudio` never blocks, so the backlog the "engine fell more than 10 s
  behind" stop must catch is inside FluidAudio's unbounded queue, not in the app's
  handoff. The app has to estimate it from samples fed versus windows reported.
- Parakeet text is structurally late: newest words arrive when audio reaches 13 s past
  the start of their window, so text lag of 11 to 13 s is normal operation, not a fault.
- Parakeet updates are per window, not cumulative, and the seam word must be reconciled by
  timing.
- Both engines: call `reset()` after the final result and before releasing the manager, so
  the library's copy of the last seconds of audio is dropped promptly.

## Corrections to the spec

The design spec's ceiling table ("Bounded audio, no whole-conversation buffer") lists
Parakeet as 10 s handoff plus one sliding window of about 15 s. The 0.18.0 source keeps up
to 26 s in `sampleBuffer` (13 s behind and 13 s ahead of the window centre), plus up to
30 s of transient copies during each window decode, plus the unbounded `streamAudio`
queue. Nemotron matches the spec (about 9.5 to 10.1 s compacted array, 15 s plus 240 ms
recovery), with an additional transient copy of up to about 16 s during each recovery
decode.

## Constraint: audio held by FluidAudio engines

Nemotron and Parakeet hold up to roughly 25 to 35 s of audio in memory, the app cannot
erase their copies, and their text may lag up to 10 s before the recording stops with
"engine fell more than 10 s behind".

Measured against the 0.18.0 source, the steady-state figures are about 25.4 s for Nemotron
with recovery on and about 26 s for Parakeet, before the app's 10 s handoff and before
transient decode copies (up to about 16 s for a Nemotron recovery decode, up to about
30 s for a Parakeet window decode). The samples are Swift `[Float]` arrays and
`AVAudioPCMBuffer`s owned by the library; they are freed, not zeroed, when trimmed. The
debug view must therefore report the held amount for these engines as estimated from the
engine configuration and the samples fed, and must say that erasure is not guaranteed.
For Parakeet the 10 s lag limit applies to the backlog behind the engine, on top of the
13 s window latency described above.
