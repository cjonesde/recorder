# Recorder

A native macOS menu-bar app for live, on-device meeting transcription. It captures
system audio and your microphone, shows words while you speak, and saves the transcript.

**Transcript only** is the default for new installations. In this mode the app creates
no audio files, including temporary recordings. Consumed app-owned PCM buffers are
wiped. Apple's internal audio buffers are opaque; this is not a guarantee that every
copy inside macOS is immediately erased.

Existing installations keep their saved audio-handling preference. Select **Transcript
only** in the panel if you previously kept audio.

## Live transcription

Three live engines are available. Pick one in the panel or in Settings under **Live
engine** before recording; the choice is remembered and fixed for that recording.

| Engine | Notes |
| --- | --- |
| Apple (default) | `SpeechAnalyzer` / `SpeechTranscriber`. Needs a language choice. Recognition runs in Apple's speech service process (`localspeechrecognition`), outside Recorder. |
| Nemotron | FluidAudio multilingual streaming model. Detects the language itself. |
| Parakeet | FluidAudio sliding-window model. Shows no text for the first 13 s of a recording, and its newest words arrive 11 to 13 s late by design. |

The language picker (German, English, French, Spanish, Italian) applies only to the
Apple engine; Nemotron and Parakeet hide it. The selected locale stays fixed for that
recording; automatic language switching is not supported for Apple. Old language choices
migrate to the matching locale. A former Auto choice resolves to a supported system
language, or English, and is shown in the picker.

Nemotron and Parakeet hold audio inside the library that the app cannot erase. Steady
state is about 25 s for Nemotron with recovery on and about 26 s for Parakeet, and decode
passes add transient copies of up to about 16 s (Nemotron recovery) and about 30 s
(Parakeet window). The samples are freed, not zeroed. Details and sources are in
[docs/live-engines.md](docs/live-engines.md).

In the polish mode the resident live engine is unloaded before Whisper loads, and
Whisper and the speaker diarizer are unloaded when the polish pass ends, so a live engine
and Whisper are not kept in memory together. The next recording loads the live engine again.

### Debug view

Turn on **Show debug info** in Settings to get a debug drawer in the panel. It shows
memory, swap, text lag and held audio while recording, and can be popped out into its own
window. While it is on, each recording also writes `debug.json` beside the transcript. The
file records timing, memory and engine events, never audio or transcript text. Held audio
for Nemotron and Parakeet is an estimate from the engine configuration, and erasure is not
guaranteed.

On first use, macOS may download language assets. The app finishes preparation before
opening either capture source. Cancel is available during preparation. Words initially
appear as provisional text; finalized results become timestamped lines. Copy works
while recording. Live speaker labels use channel energy: **You** for the microphone,
**Them** for system audio, with no label when attribution is ambiguous.

The new pipeline has no rolling audio window or replay recovery buffer. It drains
capture input every 50 ms, submits chunks of at most 100 ms, and limits the analyzer
input queue to four chunks. Each source's PCM handoff is capped at 500 ms. Overload
stops capture and marks the saved transcript incomplete. These are queue bounds,
not a guarantee of private framework buffer lifetimes or a hard real-time deadline.

## Recording modes

| Mode | Saved files | Transcription |
| --- | --- | --- |
| Transcript only (new default) | `transcript.md`, `transcript.json` | Apple live streaming; no later audio pass |
| Keep audio | Transcript plus `desktop.caf`, `mic.caf`, `audio.m4a` | Apple live streaming when enabled |
| Keep audio and run a high-quality pass | Transcript and audio files | Apple live, then Whisper / SpeakerKit on saved audio |

You can downgrade a running recording to transcript-only; this closes and removes its
partial audio files. You cannot start retaining audio halfway through a transcript-only
recording. Language and live-transcription settings are fixed until the recording ends.
Pause gates both audio feeds. Save finishes the transcript before allowing another
recording. Trash cancels recognition and removes the session folder.

Saved stereo audio has desktop sound on the left and the microphone on the right.
Whisper models are downloaded only when transcribing a saved file. SpeakerKit can
separate remote voices into Speaker 1, Speaker 2, etc. Voice profiles remain opt-in.
No recording audio is sent to a transcription service.

## Other features

- Calendar-aware recording names and a meeting-end notification.
- Level meters for both sources and configurable silence auto-stop.
- Recent recordings and transcript copy/export.
- Core Audio process-tap watchdog for desktop capture interruptions.

## Requirements and build

- Apple Silicon and **macOS 26 or later**. The streaming migration raises the previous
  macOS 15 minimum; there is no silent fallback to windowed Whisper recognition.
- Xcode 26 or later, with an SDK that includes `SpeechAnalyzer`.
- Internet access for first-use Apple language assets and optional Whisper/SpeakerKit
  downloads. Recognition itself runs on-device.

```sh
./build.sh
open ./Recorder.app
```

The build assembles and ad-hoc signs `Recorder.app`. Set `CODESIGN_IDENTITY` to use a
stable signing identity. Ad-hoc rebuilds can cause macOS to ask again for permissions.
The app requests Microphone, System Audio Recording, Calendar, and Notification access.

The implementation and benchmarks were tested on an M1 Pro with 16 GiB. M1 Air and
MacBook Neo still need direct thermal, memory-pressure, and concurrent-call validation.

## Tests and investigation

```sh
swift test -c release -j 4
```

Hardware capture and real model tests are opt-in. See the complete
[investigation and benchmark results](docs/transcription-performance.md), including
model comparisons, source links, audio-lifetime limits, raw JSON results, and reproduction
commands. The [Apple streaming implementation](docs/apple-streaming.md) documents the
session lifecycle, memory ownership, error behavior, and verification gaps. The
[live engine audit](docs/live-engines.md) covers Nemotron and Parakeet.

The older [capture research](docs/research-notes.md) is retained as historical context;
its transcription and default-retention descriptions have been superseded.

## Main components

| Component | Responsibility |
| --- | --- |
| `RecorderModel` | Capture preparation, session lifecycle, preferences and saving |
| `AppleLiveTranscriber`, `NemotronLiveEngine`, `ParakeetLiveEngine` | Live engines behind `LiveSpeechEngine`: provisional/final text, bounded submission |
| `StreamingAudioInput` | Bounded channel handoff, resampling, mixing and PCM erasure |
| `SystemAudioTap`, `MicCapture` | Desktop and microphone capture; optional file writes |
| `LocalTranscriptionEngine` | Resident live engine selection and optional saved-file Whisper/SpeakerKit |
| `DiagnosticsRecorder`, `DebugReport` | Debug drawer data and `debug.json` |
| `StereoMixer` | Align and combine retained channel files |
| `TranscriptDocument` | JSON source document and rendered Markdown |
| `Tests/RecorderTests/LegacyWhisper` | Previous live pipeline retained only for regression benchmarks |
| `Tools/ASRBenchmark` | Standalone model and streaming experiments; not an app dependency |

Recordings are saved under `~/Documents/Recordings/`. Transcript-only sessions contain
text files; audio-retaining sessions also contain the CAF channels and stereo M4A.

## License

[MIT](LICENSE).
