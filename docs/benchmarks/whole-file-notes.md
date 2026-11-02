# Preliminary whole-file measurements

These measurements preceded the clarified requirement: immediate live text, no audio
files, and prompt disposal of consumed audio. They do not select the live backend.
See [the streaming assessment](../transcription-performance.md) for that decision.

Measured on 1 November 2026, on an Apple M1 Pro with 10 CPU cores and 16 GiB RAM,
running macOS 27.2. These are local measurements, not estimates for an M1 Air or MacBook Neo.

## Initial recommendation (superseded for live speech)

Keep Whisper Base as the default for its small footprint. Tiny offers a faster option
when recognition errors are acceptable. Parakeet Ultra is the strongest candidate for
an additional German/English backend: it matched V3's speed closely and has stronger
published multilingual accuracy. The initial app used WhisperKit for live speech; the experimental
Parakeet dependency belongs only to the benchmark tool.

The previous app's polling interval matters more than inference time on these clips.
An initial polling/retry/worker experiment was withdrawn after the requirements were
clarified. It did not address the need for an incremental, low-retention live pipeline.

## Local model comparison

Each cell is the median of five warm decodes in a release build. English is an
11-second real JFK speech excerpt. German is 16.93 seconds synthesized with the macOS
Anna voice. Models run sequentially, with one model in each process. Both use 16 kHz
mono input, automatic language selection, and timestamps where supported.

| Model | English decode | German decode | German word errors on this clip |
| --- | ---: | ---: | ---: |
| Whisper Tiny | 104 ms | 220 ms | 7.3% |
| Whisper Base | 178 ms | 426 ms | 2.4% |
| Parakeet V3 | 97 ms | 221 ms | 0% |
| Parakeet Ultra | 99 ms | 228 ms | 0% |

Ultra was about 1.8 times faster than Base on both clips. Tiny was about as fast as
the Parakeet models on this input, with more German errors. All four had zero word
errors on the English clip after lowercasing and removing punctuation. These two
clips do not establish meeting accuracy, robustness to accents, or overlapping speech.

Selecting German explicitly reduced Base's median from 426 to 386 ms in this run.
Selecting English did not improve it. Removing retries on clean German changed 426
to 401 ms; that small difference does not establish a general speedup.

Initialization is separate from decoding. Base's first measured decode took 1.12 s;
later warm decodes took 0.18 s. The previous app loaded downloaded models at launch. The Apple migration removes that preload.
Parakeet's first measurements include downloads and Core ML compilation, so their
load times must not be compared directly with cached Whisper loads.

## Memory and smaller hardware

Peak process RSS ranged from about 100 to 666 MiB across these short runs. It includes
initialization and downloads, and excludes some shared allocations and separate Core ML
services. It is not the total unified-memory requirement. During first-use Redux
compilation, ANECompilerService alone occupied about 1.4 GiB.

An 8 GB machine must also accommodate macOS, the meeting application, audio buffers,
and diarization. The benchmark excludes diarization, stereo mixing, UI work, and
simultaneous calls. Saved recordings decode desktop and microphone channels separately.
Do not turn single-channel real-time multipliers into promises for a complete meeting.

The [MacBook Neo specifications](https://www.apple.com/macbook-neo/specs/) list an A18 Pro,
8 GB unified memory, and 60 GB/s memory bandwidth. It is not an M1 configuration.
Neither the Neo nor an M1 Air was available for direct testing. Repeat the harness on
both, including a sustained meeting with a browser or video-call app open, before
claiming supported latency or a memory budget.

## Model research

| Candidate | Fit for this app |
| --- | --- |
| Parakeet Ultra | 25 European languages, including German and English; native Swift/Core ML. Best candidate for another backend. |
| Parakeet Redux | About 220 MB download. Its 2-bit encoder has expensive first-use ANE compilation; smaller does not imply faster. |
| Nemotron multilingual streaming | A streaming design with cached state avoids repeatedly decoding a growing Whisper window. Needs a separate live pipeline and validation of model distribution and language switching. |
| Apple SpeechAnalyzer / SpeechTranscriber | Native on-device streaming with provisional/final results. Requires macOS 26+, the previous app supported macOS 15+. Locale and asset availability need runtime checks. Not locally benchmarked here. |
| Qwen3-ASR 0.6B / 1.7B | Wider language coverage. The official runtime targets Python/Transformers or vLLM; a Mac integration needs another runtime. Not locally benchmarked, and GPU/server numbers do not predict M1 latency. |
| English-only EOU, Unified, Phonon, Bark | Potentially useful for English dictation, but cannot replace this app's German/English default. |

Primary sources checked:

- [FluidAudio v0.18.0](https://github.com/FluidInference/FluidAudio/releases/tag/v0.18.0), the benchmarked runtime.
- [Parakeet Ultra accuracy and speed](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md). Its full-corpus comparisons favor Ultra over V3; those are upstream results, not this Mac's results.
- [Redux compilation and speed tradeoffs](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetRedux.md).
- [FluidAudio streaming benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md), including Nemotron and Unified. Device and model configuration differ from this test.
- [Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer).
- [Qwen3-ASR official repository](https://github.com/QwenLM/Qwen3-ASR).

## Reproduce

From the repository root, with Swift 6.2+ and the Anna voice installed:

```sh
python3 Tools/ASRBenchmark/fixtures.py
swift build -c release --package-path Tools/ASRBenchmark -j 4
python3 Tools/ASRBenchmark/run.py
```

The tool downloads public Parakeet models into `.build/asr-models`. Whisper Tiny/Base
must already be downloaded through the app. Successful result files are kept; move
them elsewhere before repeating a measurement. You can pass case names to `run.py`
to run a subset. Raw durations, startup times, transcripts, and RSS are stored in
this directory. Logs and audio fixtures are ignored by Git.

The word-error checks use lowercased words with punctuation removed, and total word
edits divided by reference words. They are a fixture sanity check, not a leaderboard
score. The long-file fixture repeats the English excerpt twelve times; it measures
worker behavior, not long-meeting recognition quality.
