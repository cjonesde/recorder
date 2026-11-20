# Recorder

A native macOS menu-bar app for live, on-device meeting transcription. It captures
system audio and your microphone, shows words while you speak, and saves the transcript.
While it records, the menu bar shows a red capsule with the elapsed time (ochre with a
pause sign while paused), in the same design as the Schriftlich app.

**Transcript only** is the default for new installations. In this mode the app creates
no audio files, including temporary recordings. Consumed app-owned PCM buffers are
wiped. Apple's internal audio buffers are opaque; this is not a guarantee that every
copy inside macOS is immediately erased.

Existing installations keep their saved audio-handling preference. Select **Transcript
only** in the panel if you previously kept audio.

## About this fork

This fork of [tobi/recorder](https://github.com/tobi/recorder) keeps the original
recording, calendar, library, and silence auto-stop features. It replaces Gemini cloud
transcription with on-device live engines (Apple, Nemotron, Parakeet) and an optional
local WhisperKit and SpeakerKit pass over saved audio. It adds audio-retention modes,
structured transcripts, speaker renaming, optional voice profiles and a debug view, plus
sample-rate and microphone route-change fixes, with tests for capture, transcription,
retention, and speaker profiles. No API key is required, and the app does not upload
audio or transcripts.

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
A recording that starts during a polish pass interrupts it (see Back-to-back calls).

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
input queue to forty chunks (about 2 s at the usual 50 ms chunk size, 4 s at most).
Each source's PCM handoff is capped at 500 ms. These are queue bounds, not a guarantee
of private framework buffer lifetimes or a hard real-time deadline.

A recording ends only when you save or trash it, or when the silence timeout fires.
Nothing else stops it. If live text overloads or the engine fails, the app restarts live
text inside the same recording, keeps every line from before, and marks the gap with an
`[incomplete: …]` line; a restart that fails is retried after 1, 2, 4 … up to 30 s. The
words spoken during the gap are missing from the live transcript. When audio is kept, the
high-quality pass or a later transcription fills them in. If a capture source fails (a
microphone route change to an unusable device, a desktop tap that cannot be rebuilt, a
disk write error), the other source keeps recording, the failed one is retried, and the
status line says so.

Desktop audio passes through a ring between the capture callback and the thread that
writes `desktop.caf`. In transcript-only mode it holds half a second, and audio older
than that is dropped. When audio is kept it holds 10 s: after a stall under heavy memory
pressure the backlog is written to disk in full and only its newest quarter second goes to
live text. Audio lost to a longer stall, a desktop tap rebuild or a microphone outage is
written as silence, so the desktop and microphone tracks stay aligned. Each stall is
logged as "desktop audio stalled" in `debug.json`.

## Recording modes

| Mode | Saved files | Transcription |
| --- | --- | --- |
| Transcript only (new default) | `transcript.md`, `transcript.json` | Live engine; no later audio pass |
| Keep audio | Transcript plus `desktop.caf`, `mic.caf`, `audio.m4a` | Live engine when enabled |
| Keep audio and run a high-quality pass | Transcript and audio files | Live engine, then Whisper / SpeakerKit on saved audio |

You can downgrade a running recording to transcript-only; this closes and removes its
partial audio files. You cannot start retaining audio halfway through a transcript-only
recording. Language and live-transcription settings are fixed until the recording ends.
Pause gates both audio feeds. Save waits only for the live engine to finish its last
words (about a second), writes the live transcript, and the app is ready for the next
call. Mixing `audio.m4a` continues in the background. Trash cancels recognition and
removes the session folder.

### Back-to-back calls

Local transcriptions of saved audio (the polish pass, and **Transcribe** in Recent
recordings) go into a queue and run one at a time, oldest first. They never run while a
recording is preparing or in progress: pressing Record stops the running pass and puts it
back at the front of the queue, and it starts again from the beginning once the recording
ends. The panel shows what is transcribing and how many are waiting. A finished
transcript for an earlier call does not replace the one on screen; it is announced in the
status line and appears in Recent recordings. The queue is kept in memory, so quitting the
app drops waiting transcriptions; their audio stays on disk.

While a recording runs, the mix of the previous call may still be finishing. The mixer
reads both tracks into memory at once (48 kHz float, about 690 MB per track per hour), so
the mix of a long call briefly uses a few GB alongside the new recording.

Saved stereo audio has desktop sound on the left and the microphone on the right.
Whisper models are downloaded only when transcribing a saved file. SpeakerKit can
separate remote voices into Speaker 1, Speaker 2, etc. Voice profiles remain opt-in.
No recording audio is sent to a transcription service.

Transcript-only recordings cannot be transcribed again. Their transcript is written when
you save, so a crash can lose the transcript even though no audio files remain.

## Speaker profiles and privacy

In **Settings > Speakers**, enable **Match voices to saved profiles** to recognize desktop voices in later offline transcriptions. After an offline transcription, rename a speaker under the finished transcript to create or update a profile. Renaming **You** changes only the display name and never creates a microphone voiceprint.

Automatic matches apply names without adding voiceprints to profiles. Correcting a name retracts that recording's contribution from the previous profile before adding it to the corrected profile. Matching and enrollment require at least six seconds of speech from the cluster. Unmatched voices keep their generic speaker labels.

Voiceprints stay in `~/Library/Application Support/Recorder/Speakers/`, outside recording folders. Pending voiceprints are pruned after 30 days when the app initializes. You can delete individual profiles or use **Delete all voice data** to remove profiles and pending voiceprints. Turning matching off does not delete stored voice data.

Transcripts contain speaker names, meeting titles, invited attendees, and spoken content. They contain no voiceprint vectors, but can still contain personal information. Deleting voice data leaves names already written into transcripts intact.

## Voice coach

An optional prompter for your own voice during calls. Switch it on with the **Voice coach**
switch in the panel or under Settings > Coach. It is off by default.

While you record, a small bar sits just below the menu bar, a third of the screen width to the
right of the camera, so Teams' sharing bar and notch apps don't cover it. It stays above slides
and full-screen apps. Drag it anywhere; it opens where you left it next time. It shows no text,
only colour and shape:

- **Dot:** green while you speak, blue while the other side speaks, purple when you talk over
  them, gray in silence.
- **Bar:** your energy, meaning your speaking level against your own usual level. It turns from
  dull gray to warm orange as you speak with more energy.
- **Tortoise:** lights for four seconds when you speak noticeably faster than your usual pace.

Right-click the bar to pick a preset (Presentation, 1on1, Group) or hide it until the next
recording. The preset starts from the calendar: no meeting or 8 and more attendees means
Presentation, up to 2 means 1on1, otherwise Group. It is excluded from screen sharing
(`sharingType = .none`, not yet tested in a real share).

**It only listens to you while the other side is quiet.** Recorder has no echo cancellation,
so on desk speakers the microphone also hears the call. The coach compares the microphone with
the system audio, which is exactly what plays through the speakers, and ignores your microphone
from 0.3 s before the other side makes sound until 0.5 s after it stops. A burst of microphone
sound only counts as your voice once it contains at least 30 ms of voicing (a measurable
pitch), so typing, clicks and desk knocks count as silence instead of dragging your pace and
energy down.

**Talking over someone has to beat the echo.** On desk speakers the microphone hears the call
again about 0.1 s later, often louder than the system audio itself, and the two streams can drift
up to 0.2 s apart before the coach lines them up again. So the coach learns, during each call,
how loud that echo usually is (the 90th percentile of microphone minus system audio while the
other side speaks) and only counts you as talking over someone when your microphone is 4 dB
above the echo it expects from the call audio of the last 0.5 s and the next 0.15 s. Talk share
and interruptions build on that. With headphones the learned echo is tiny, so quieter talking
over still counts. Replayed on a real call on laptop speakers in which only 9 seconds were
yours, this took talk share from 26% to about 1% and interruptions from 106 to at most 1.

**Everything except pace and energy runs silently at first.** "So" at the start of your
sentences (English "so", German "so" and "also", Apple engine only), rising statement endings,
trailing endings, raised pitch and level, talk share and interruptions are all measured and
logged, but stay off the bar. A check can join the bar only after you labelled at least 20 of
its moments and at least 90% were right. Raised pitch and level never joins the bar. Talk share
is the exception: it is a measurement, not an alarm, so it has no moments to label, and you can
show it as a ring around the dot whenever you like.

**Half of the cues are skipped on purpose.** Each time a cue would light, a coin flip decides
whether it shows. Some calls show no cues at all, more often as the weeks go on (every 5th of
the first 10 calls, every 3rd up to 20, then every 2nd). The skipped moments are still logged,
so you can later compare cued and uncued moments and see whether the cue changed anything.
Switch this off under Settings > Coach; that also ends the calls without any cues.

**Labelling.** Settings > Coach > Review flagged moments lists every flagged moment per
recording, plays its clip and lets you mark it Right or False alarm. The same window shows each
check's precision and lets you put it on the bar once it qualifies.

Pace only counts while you are actually speaking, and the ending checks only fire on a fresh
phrase, so a cue never lights while you listen. Pausing the recording turns off any lit cue.
Talking over someone only counts as an interruption while their audio is actually playing, so
starting your turn right after they stop is not one. An ending counts as rising when your pitch
climbs at least 2.5 semitones over its last 0.4 seconds, and each rising ending is flagged on its
own, at most once every 45 seconds. The flag waits 6 seconds after the ending, so a sentence
that ends in a question mark in the live transcript is not flagged as a rising statement when
its line arrives up to 6 seconds late. If the system audio drops out (macOS rebuilds the
audio tap now and then), the coach notices the missing stretch, scores it as unknown and lines the
two streams up again.

Pace and energy are measured against your own baseline: the median of your last 10 recordings
with at least 2 minutes of your speech, per language for pace and per microphone for level.
Until 3 such recordings exist, the coach uses the current call once it has 2 minutes (pace) or
30 seconds (energy) of your speech, and shows no pace cue before that.

What it writes, all next to the recording:

- `coach.jsonl`: one JSON line per event (session settings, once-per-second raw values per
  check, every trigger with whether it was shown, withheld or shadow, clip decisions). No
  transcript text and nothing about the other side beyond who spoke when.
- `coach-clips/<id>.m4a`: your microphone around each flagged moment (8 seconds, or the whole
  transcript line for "So" at sentence starts, at most 16.5 seconds), only in the audio-keeping
  modes, and only when the other side was silent for the whole clip. A moment flagged just before
  you stop gets a clip cut at the end of the recording. Switching to
  transcript only during the call deletes them.
- `coach-labels.json`: your Right / False alarm labels.

The baseline lives in `~/Library/Application Support/Recorder/coach-baseline.json`.

Not settled yet: whether an own-voice baseline counts as a biometric profile, whether acoustic
self-feedback falls under the EU AI Act's workplace emotion rules (Art. 5(1)(f)), and what notice
turn-taking analysis needs. All three matter before this becomes a product. See
`docs/2026-11-14-grill-live-voice-coach.md`.

## Other features

- Calendar-aware recording names and a meeting-end notification.
- Level meters for both sources and configurable silence auto-stop.
- Recent recordings and transcript copy/export.
- Core Audio process-tap watchdog for desktop capture interruptions.

## Requirements and build

- Apple Silicon and **macOS 26 or later**. The streaming migration raises the previous
  macOS 15 minimum; there is no silent fallback to windowed Whisper recognition.
- Xcode 26 or later, with an SDK that includes `SpeechAnalyzer`.
- Internet access for first-use Apple language assets, Nemotron and Parakeet models,
  and optional Whisper/SpeakerKit downloads. Recognition itself runs on-device.

```sh
./build.sh
open ./Recorder.app
```

The build assembles and ad-hoc signs `Recorder.app`. Set `CODESIGN_IDENTITY` to use a
stable signing identity. Ad-hoc rebuilds can cause macOS to ask again for permissions.

The implementation and benchmarks were tested on an M1 Pro with 16 GiB. M1 Air and
MacBook Neo still need direct thermal, memory-pressure, and concurrent-call validation.

## Permissions

Granted on first use via standard system prompts (declared in `Info.plist`):

- **Microphone:** capture your voice.
- **System Audio Recording:** capture desktop audio via the Core Audio process tap. This uses the audio permission and does not require Screen Recording.
- **Calendars (full access):** list nearby meetings and include their titles and invited attendees in transcripts.
- **Notifications:** show the meeting-end alert.

## File layout

Recordings land in `~/Documents/Recordings/{YYYY-M-D}-{HHMM}[-{meeting}]/`:

```
desktop.caf      raw mono system audio (audio-retaining modes)
mic.caf          raw mono microphone (audio-retaining modes)
audio.m4a        stereo AAC mix: desktop = L, mic = R (produced on Save; raw files kept)
transcript.md    timestamped Markdown transcript (if transcription produced text)
transcript.json  structured transcript, metadata, speaker IDs, and display names
debug.json       numbers and events only, written while Show debug info is on
coach.jsonl      voice coach events, written while the voice coach is on
coach-clips/     voice coach clips of your own voice (audio-retaining modes)
coach-labels.json  your labels for those clips
```

In transcript-only mode, the folder contains only the transcript files (and `debug.json`
when debug is on). Downloaded models and optional voice profiles are stored separately:

```text
~/Library/Application Support/Recorder/
  WhisperModels/             downloaded Whisper and diarization models
  SpeechModels/              downloaded Nemotron and Parakeet models
  Speakers/
    profiles.json            named profiles and their voiceprints
    pending/<uuid>.json      voiceprints associated with finished transcriptions
```

`transcript.json` can refer to pending voiceprints by UUID, but stores no voiceprint vectors.

## Tests and investigation

```sh
swift test -c release -j 4
```

Hardware capture and real model tests are opt-in. The desktop tap's rate check plays an
inaudible tone into BlackHole 2ch and switches it between 48 and 24 kHz, the way AirPods
change rate when a call starts: `RECORDER_LIVE_ROUTE=1 swift test --filter TapOutputRateTests`.
See the complete
[investigation and benchmark results](docs/transcription-performance.md), including
model comparisons, source links, audio-lifetime limits, raw JSON results, and reproduction
commands. The [Apple streaming implementation](docs/apple-streaming.md) documents the
session lifecycle, memory ownership, error behavior, and verification gaps. The
[live engine audit](docs/live-engines.md) covers Nemotron and Parakeet.

The older [capture research](docs/research-notes.md) is retained as historical context;
its transcription and default-retention descriptions have been superseded.

### Voice coach speaker test

Step 0 of the voice coach checks whether pace and statement endings survive desk speaker
bleed. It reads a kept `audio.m4a` (desktop left, mic right), gates the mic on a quiet
system audio tap, and runs the intonation code from `coach.py` (pass `--coach <path>` if it
is not in the default location). Run from the repository root:

```sh
uv run --python 3.12 --with "numpy<2" --with praat-parselmouth==0.4.7 --with pytest \
  python -m pytest Tools/SpeakerTest -q
uv run --python 3.12 --with "numpy<2" --with praat-parselmouth==0.4.7 \
  python Tools/SpeakerTest/speaker_test.py analyze ~/Documents/Recordings/<folder>/audio.m4a \
  --csv endings.csv --clips clips
uv run --python 3.12 --with "numpy<2" --with praat-parselmouth==0.4.7 \
  python Tools/SpeakerTest/speaker_test.py score endings.csv
```

Listen to each clip, write `rise`, `fall` or `level` in the `ear` column of `endings.csv`,
then run `score`. It reads `scorable_share` from `endings.report.json`, which `analyze` writes
next to the CSV. The verdict is "desk speakers usable" when at least 15 gated endings are
marked, at least 0.8 of them agree, and at least half of the own speech is scorable. With
15 or more marks and either condition missed, it is "headset tool". With fewer than 15 marked
gated endings it says "needs ear marks", because too few marks are missing evidence, not a
failed test. Record three real calls on desk speakers with **Keep audio** first.

### Voice coach replay

`coach-replay` runs the coach core over a finished recording, faster than real time, and
writes the same `coach.jsonl` events the app writes plus a TSV of every bar change. Use it to
check thresholds on real calls before changing them. It takes a kept `audio.m4a` (desktop
left, mic right) or a separate mic file and call audio file, for example from another
recorder:

```sh
swift build -c release --product coach-replay
.build/release/coach-replay --recording ~/Documents/Recordings/<folder>/audio.m4a \
  --events coach.jsonl --hud hud.tsv
.build/release/coach-replay --mic Microphone.m4a --desktop Teams.m4a --attendees 6 \
  --lines lines.json --events coach.jsonl
```

`--lines` takes a JSON array of `{start, end, text, isOwn}` and delivers each line three
seconds after it ends (`--line-lag`). `--desktop-offset` shifts the call audio when the two
files did not start together. The summary on stdout lists own speech, the session rate and
level, gate shares, and per check how often it triggered, how often the cue was shown and
for how many seconds it was lit.

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
| `VoiceCoach` (target) | Dependency-free coach core: gate, detectors, cue policy, event log, clip planning |
| `CoachAdapter`, `CoachHUDPanel`, `CoachReviewWindow` | Recorder glue for the coach: sample relay, log and clip files, floating bar, labelling |
| `coach-replay` (target) | Runs the coach core over a finished recording for threshold checks |
| `TranscriptDocument` | JSON source document and rendered Markdown |
| `SpeakerProfileStore`, `SpeakerNaming` | Voice profiles, pending voiceprints, and speaker renaming |
| `Tests/RecorderTests/LegacyWhisper` | Previous live pipeline retained only for regression benchmarks |
| `Tools/ASRBenchmark` | Standalone model and streaming experiments; not an app dependency |

## Limitations and possible future work

- Voice-profile matching can misidentify speakers. You can correct their names in the transcript.
- Re-encoding the kept raw files to Opus/`.ogg` (the raw `.caf` files make this lossless).
- Continuous clock-drift slope correction for multi-hour recordings (sub-100 ms residual drift is acceptable for personal use).
- Acoustic echo cancellation (assumes headphones; AEC would muddy the deliberate hard channel separation). The voice coach gates on a quiet system audio tap instead; whether that is enough on desk speakers is what the speaker test decides.
- Streaming model-based diarization (Speaker N labels updating live). Live labels are channel-based (You/Them); clustered per-voice labels currently require the offline pass over the saved file.

## License

[MIT](LICENSE).
