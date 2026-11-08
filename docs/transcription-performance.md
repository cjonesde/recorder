# Immediate transcription without audio files

Measured on 1 November 2026 on an M1 Pro, 10 CPU cores, 16 GiB RAM, macOS 27.2.
The target is text while speaking, no stored recording, and prompt disposal of consumed
PCM. Whole-file throughput does not measure this use case.

## Decision

Apple's native streaming recognizer is the selected production backend, with an
explicit language choice before capture. The investigation on 1 November recommended
it; the implementation on 2 November replaces the live Whisper path. Whisper remains
available for saved audio only. See [the implementation record](apple-streaming.md).

Automatic switching remains deferred. The tested Nemotron profile needed replay
recovery to reduce omissions, which conflicts with prompt raw-audio disposal. Apple
streaming still needs a selected locale; choosing German does not promise accurate
English passages in the same recording.

The initial polling/retry/worker experiment was withdrawn. It improved neither the
fundamental windowed design nor the ownership of consumed audio. The old pipeline is
preserved under `Tests/RecorderTests/LegacyWhisper` solely to reproduce the baseline.

## Replay results

The same 52.42-second sequence contains four public FLEURS utterances: German, English,
German, English, with one-second gaps. It has 79 reference words. First speech starts
at 4.30 seconds, estimated from three consecutive 20 ms RMS blocks above 0.005.
The recognizers receive input at recording speed in 100 ms chunks, sequentially.

| Path | First correct word after speech onset | Final word-error rate on this sequence |
| --- | ---: | ---: |
| Previous app's Whisper Base, automatic language | 3.00 s | 40.5% |
| Standalone Apple SpeechTranscriber, selected German | 0.63 s | 25.3% |
| Integrated Apple pipeline, selected German (2 November) | 0.71 s | 25.3% |
| Nemotron 3.5 Latin, 560 ms, ANE, automatic, recovery off | 0.99 s | 44.3% |
| Nemotron 3.5 Latin, 560 ms, ANE, automatic, recovery on | 0.99 s | 21.5% |
| Nemotron, same recovery-off profile on GPU | 6.79 s | 53.2% |

The previous app first displayed `[BLANK_AUDIO]` at 4.10 seconds into the recording. Usable
speech text appeared at 7.30 seconds. Its first committed lines arrived at 31.60
seconds, and its final transcript omitted the last English utterance.

Apple's selected-German profile recognized the German passages much better than the
English passages. A selected locale is not equivalent to automatic language switching.
Nemotron's recovery-off profile dropped large portions of English. Recovery restored
some missing speech: the first English word, “however,” appeared at 21.44 seconds with
recovery; it never appeared without recovery. The previous app emitted it at 31.60 seconds.

These are four utterances, not a representative meeting corpus or a statistical
ranking. Names and tokenization affect the score. WER uses case-folded words,
punctuation removal, and word edit distance. The legacy app includes its actual desktop/mic
mixing, with a silent mic; the standalone prototypes receive the full-level mono
fixture. Therefore app-versus-prototype WER also includes that input-level difference.
The standalone Apple/Nemotron comparisons use identical PCM. The new integrated
Apple path adds desktop and mic samples with clipping instead of halving a single
active source, so the silent-mic replay has the same level as the prototypes.

The integrated run finalized in 66 ms, reported complete, and left no pending input.
It uses the production input handoff, result accumulator and session lifecycle, but
replays a public file into capture callbacks; it does not measure hardware input
latency or a real video call. The English JFK replay separately verifies the selected
English path. Raw results are indexed [here](benchmarks/README.md).

## Audio lifetime

| Path | Retention finding |
| --- | --- |
| Legacy Whisper live path | Re-decodes a growing window; confirms around 25 seconds. Transcript-only has a 90-second window cap and the input inbox has a 60-second per-source cap. |
| Native prototype / production Apple path | No audio-file output in transcript-only mode. A custom PCM deallocator overwrites each submitted input allocation when the framework releases it. The integrated capture handoff is bounded to 500 ms per source and the analyzer queue to four chunks of at most 100 ms. |
| Nemotron SDK without recovery | Consumed PCM remains in its input array until periodic compaction: up to roughly 9.5 seconds with 560 ms chunks. Removal does not explicitly overwrite it. |
| Nemotron SDK with recovery | Also retains up to 15 seconds of speech and 240 ms pre-roll for replay. Unsuitable unchanged for prompt audio removal. |

In the native lifetime probe, 110 buffers of 100 ms each were submitted. Peak
app-owned submitted PCM was 3,200 bytes. Median buffer lifetime was 0.053 ms, maximum
0.661 ms, and no submitted allocation remained after finalization. Erasure uses
`memset_s` in the deallocator.

This measures those allocations only. Apple can copy audio into private buffers;
the result does not establish their lifetime or prove immediate erasure of every
copy. An auditable raw-audio-erasure requirement needs ownership and cleanup guarantees
through the recognizer as well as the app. Streaming also necessarily retains model
state derived from earlier sound.

## Cleanup investigation and implementation

Regression tests reproduced cancellation retaining the inbox backlog and consumed
ring slots retaining their samples. The changes:

- Overwrite ring slots before publishing them as available to the producer; also wipe the allocation on destruction.
- Erase app-owned capture conversion and writer buffers after their consumers return.
- Discard pending input, channel carry, and resampler state on cancellation and session restart.
- Clear the live window and inbox after finalization, including when no model was ready.
- Use `memset_s` for owned-buffer erasure instead of ordinary stores that could be optimized away.

Those cleanup regressions are preserved as tests. The rolling Whisper window and
60-second inbox are no longer linked into the app: their implementations now belong
to the historical test fixture. Production uses a separate fixed-capacity input
handoff, erases consumed PCM slots and scratch buffers, and stops capture on overflow.
The desktop capture ring was reduced from four seconds to half a second; the requested
microphone callback size was reduced from 4096 to 1024 frames. The OS may choose the
actual callback size.

Verification also exposed an overlapping-timestamp error when floating-point seconds
were converted to a different timebase. Inputs now use integer sample positions at
their actual sample rate; a regression test checks adjacent chunk boundaries. The
corrected real-time replay passes. Cancellation/restart is exercised against the
native recognizer. The final release suite passes 127 tests, with 15 opt-in checks skipped and no failures.
The native German and English replay/cancellation checks pass separately. See the
implementation record for packaging validation and remaining gaps.

## Hardware and deployment limits

The native API requires macOS 26+, and needs locale assets installed before capture.
The app now requires macOS 26+ in both Package.swift and Info.plist. The former macOS 15
support was removed rather than retaining an implicit non-streaming fallback.
Start capture only after recognition is prepared; buffering while downloading models
conflicts with the requested audio lifetime.

The [MacBook Neo specifications](https://www.apple.com/macbook-neo/specs/) list A18 Pro,
8 GB unified memory, and 60 GB/s bandwidth. It is not an M1. Neither it nor an M1 Air
was available for testing. No sustained thermal, battery, memory-pressure, or
concurrent-video-call claim is established here. Process RSS alone excludes separate
speech/Core ML services and is not a total memory budget.

ANE model-loading attempts encountered long compiler waits while the system's
ANECompilerService was already busy. Those waits are not valid isolated cold-start
comparisons. Later Nemotron ANE runs loaded in roughly 27–29 seconds; the GPU run
loaded in about 10 seconds. Asset preparation must happen before recording.

## Other models researched

Parakeet Ultra and V3 are fast multilingual file recognizers, but their short warm
decode times do not remove the need for streaming context and audio-lifetime control.
Redux prioritizes download size; upstream documents expensive first-use ANE compilation.
The local Redux attempt was abandoned while the shared compiler was busy, so it did
not produce a defensible model-specific loading time. Qwen3-ASR
0.6B/1.7B offer broader language coverage but add another runtime to this Swift app.
English-only EOU/Unified models cannot replace a German/English default.

See [preliminary whole-file measurements](benchmarks/whole-file-notes.md) for the
Tiny/Base/V3/Ultra throughput tests. They are supplementary, not the decision criterion.

Primary sources:

- [Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer) and the installed SDK interfaces for streaming, locales, and input-buffer ownership.
- [FluidAudio v0.18.0](https://github.com/FluidInference/FluidAudio/releases/tag/v0.18.0), the pinned benchmark runtime.
- [Nemotron processing buffer](https://github.com/FluidInference/FluidAudio/blob/v0.18.0/Sources/FluidAudio/ASR/Parakeet/Streaming/Nemotron/StreamingNemotronMultilingualAsrManager.swift) and [blank-span replay recovery](https://github.com/FluidInference/FluidAudio/blob/v0.18.0/Sources/FluidAudio/ASR/Parakeet/Streaming/Nemotron/StreamingNemotronMultilingualAsrManager%2BBlankRescue.swift).
- [Parakeet Ultra](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md), [Redux](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetRedux.md), and [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR).
- [Public FLEURS fixture mirror](https://huggingface.co/datasets/FluidInference/fleurs-full).

## Reproduce

From the repository root:

```sh
python3 Tools/ASRBenchmark/fleurs.py
swift build -c release --package-path Tools/ASRBenchmark -j 4

# Legacy baseline (Whisper test fixture):
RECORDER_STREAM_BENCHMARK=1 \
RECORDER_TEST_AUDIO="$PWD/Tools/ASRBenchmark/fixtures/bilingual.wav" \
RECORDER_STREAM_OUTPUT="$PWD/docs/benchmarks/stream-app-bilingual.json" \
swift test -c release --filter LiveStreamingBenchmarkTests

# Current production Apple pipeline:
RECORDER_APPLE_STREAM=1 RECORDER_STREAM_LANGUAGE=de-DE \
RECORDER_TEST_AUDIO="$PWD/Tools/ASRBenchmark/fixtures/bilingual.wav" \
RECORDER_STREAM_OUTPUT="$PWD/docs/benchmarks/stream-app-apple-bilingual-de.json" \
swift test -c release --filter AppleStreamingVerificationTests

Tools/ASRBenchmark/.build/release/ASRBenchmark stream-apple \
  Tools/ASRBenchmark/fixtures/bilingual.wav de-DE \
  docs/benchmarks/stream-apple-bilingual-de.json

Tools/ASRBenchmark/.build/release/ASRBenchmark stream-nemotron \
  Tools/ASRBenchmark/fixtures/bilingual.wav auto \
  docs/benchmarks/stream-nemotron-bilingual-auto-ane.json
```

Set `RECORDER_BENCH_RESCUE=1` for the recovery comparison or `RECORDER_BENCH_GPU=1`
for the GPU profile. Run one recognizer at a time. The native JSON includes PCM
lifetimes. Test audio is public/synthetic and ignored by Git; no user recordings were
read or uploaded. JSON results contain text and timings, not audio.

Score the bilingual final transcripts with:

```sh
python3 Tools/ASRBenchmark/score.py docs/benchmarks/stream-*bilingual*.json
```

The script counts case-folded Unicode word tokens with `re.findall(r"\w+", text)`
and computes Levenshtein edit distance divided by 79 reference tokens. Its first-word
metric locates the first reference word, “für,” in a result event and subtracts 4.30 s.
That shortcut is specific to this fixture and was checked against the emitted text;
it is not a general word-alignment or hallucination detector. Native prototype events
are individual recognition results; app events are snapshots of the rendered transcript.

Results already in the repo should be archived before rerunning a command that overwrites
them. Fixtures and downloaded models are ignored by Git. Only text, metrics, scripts,
and documentation are included. No private meeting audio was used in these experiments.
