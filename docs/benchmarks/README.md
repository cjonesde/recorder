# Benchmark artifacts

The [investigation](../transcription-performance.md) explains the decision and limits.
Runs were made sequentially on an Apple M1 Pro, 10 CPU cores, 16 GiB RAM, macOS 27.2
(build 26B123), with Swift 6.4.2 and release builds. Initial experiments ran on
1 November 2026; the integrated Apple verification ran on 2 November.

| Artifact | Input and meaning |
| --- | --- |
| [stream-app-bilingual.json](stream-app-bilingual.json) | Previous production Whisper Base live pipeline, automatic language, real-time bilingual replay, desktop speech plus silent mic. Preserved as the baseline. |
| [stream-apple-bilingual-de.json](stream-apple-bilingual-de.json) | Native standalone prototype, selected German, same bilingual fixture at original level. |
| [stream-app-apple-bilingual-de.json](stream-app-apple-bilingual-de.json) | New production Apple pipeline, selected German, real-time bilingual replay through its bounded handoff. |
| [stream-app-apple-en.json](stream-app-apple-en.json) | New production Apple pipeline, selected English, real-time JFK replay. |
| [stream-nemotron-bilingual-auto-ane.json](stream-nemotron-bilingual-auto-ane.json) | Nemotron 3.5 Latin, 560 ms chunks, automatic language, ANE, blank-span recovery disabled. |
| [stream-nemotron-bilingual-auto-rescue-ane.json](stream-nemotron-bilingual-auto-rescue-ane.json) | Same Nemotron profile with blank-span recovery enabled. |
| [stream-nemotron-bilingual-auto-gpu.json](stream-nemotron-bilingual-auto-gpu.json) | Same recovery-disabled profile on CPU/GPU. |
| [stream-apple-buffer-lifetimes.json](stream-apple-buffer-lifetimes.json) | 110 submitted buffers on the JFK fixture; custom-deallocator release timings, peak and remaining owned input bytes. Excludes internal Apple copies. |
| [stream-apple-en.json](stream-apple-en.json), [stream-apple-de.json](stream-apple-de.json) | Earlier standalone native English JFK and synthetic German probes. Their first-word times are relative to file start. |
| [tiny-en-auto.json](tiny-en-auto.json), [tiny-de-auto.json](tiny-de-auto.json) | Whole-file Whisper Tiny with automatic language. |
| [base-en-auto.json](base-en-auto.json), [base-de-auto.json](base-de-auto.json) | Whole-file Whisper Base with automatic language. |
| [base-en-fixed.json](base-en-fixed.json), [base-de-fixed.json](base-de-fixed.json) | Same Base model with fixed language. |
| [base-de-no-retry.json](base-de-no-retry.json) | Base German with temperature fallback disabled. This experimental policy was not adopted. |
| [v3-en.json](v3-en.json), [v3-de.json](v3-de.json) | Whole-file Parakeet V3. |
| [ultra-en.json](ultra-en.json), [ultra-de.json](ultra-de.json) | Whole-file Parakeet Ultra. |
| [fixture-sha256.json](fixture-sha256.json) | Hashes of the local public/synthetic fixtures and bilingual reference manifest used in the experiments. |

The standalone benchmark package pins WhisperKit 1.1.0 and FluidAudio 0.18.0. The
Nemotron downloaded metadata identifies `nvidia/nemotron-3.5-asr-streaming-0.6b`, Latin
vocabulary 2828, chunk_mel_frames 56 and att_context_size [42,13]. Its source code and
asset metadata were checked because some SDK documentation described an older,
locally converted intermediate model. The production app has no FluidAudio dependency.

Whole-file JSON records load time (possibly including downloads), first decode, five
warm decodes, their median, real-time multiplier, transcript text and peak process RSS.
These are throughput measurements, not live word latency. See
[the preliminary notes](whole-file-notes.md) for those tradeoffs.

Streaming JSON records provisional/final text events and their wall times. Standalone
events also include the corresponding audio-time boundary; app events snapshot the
rendered transcript and confirmed-line count. Finalization time starts after the last
submitted input. The new app measurements assert successful completion, no pending
source PCM, and an unloaded Whisper host.

The integrated Apple runs reported about 43 MiB (bilingual) and 35 MiB (English) peak
process RSS. These are test-process values, not whole-app or unified-memory budgets:
Apple speech services, Core ML services, the UI, browser/video calls and OS memory
are outside that number. Asset load times were warm/cached and are not fresh-install
startup measurements. No Air or Neo measurement is implied.

The Redux loading attempt was stopped while ANECompilerService was already busy;
there is no completed Redux result. Initial Nemotron ANE attempts were also affected
by compiler contention. No result is invented for aborted experiments. Long/noisy
fixtures and corresponding cases exist in the harness, but only the JSON files listed
above are completed measurements.

Test audio is ignored by Git. `fixtures.py` creates the JFK/synthetic/noisy fixtures;
`fleurs.py` downloads the four public FLEURS clips and creates the bilingual sequence
plus reference manifest. `score.py` reproduces the reported final-text WER and the
fixture-specific first-word calculation. Hashes permit detecting a changed upstream
fixture; they do not make synthetic voice generation deterministic across OS versions.

Run commands in [the investigation](../transcription-performance.md). Archive results
before rerunning commands that overwrite them. No private recordings were read,
retained, or uploaded for these benchmarks.
