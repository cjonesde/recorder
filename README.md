# Recorder

A small, native macOS **menu-bar app** that records your meetings and voice notes with one click. It captures **two audio sources at once** and, when audio is retained, mixes them into a single stereo file:

- **Desktop / system audio → Left channel** (the people you hear through your speakers)
- **Your microphone → Right channel** (you, and anyone physically with you)

It also **transcribes and diarizes fully on-device** with local models (via [WhisperKit + SpeakerKit](https://github.com/argmaxinc/WhisperKit), CoreML on Apple Silicon): the transcript **streams live into the panel while you record**, with speaker labels, a copy button, and a model switcher. No API key is required, and the app does not upload audio or transcripts.

Pure Swift / SwiftUI. No Dock icon, no external runtime dependencies, no ffmpeg. Builds into a single ad-hoc-signed `.app`.

## About this fork

This fork of [tobi/recorder](https://github.com/tobi/recorder) keeps the original recording, calendar, library, and silence auto-stop features. It replaces Gemini cloud transcription with local WhisperKit and SpeakerKit models, adds live transcripts and audio-retention modes, and supports structured transcripts, speaker renaming, and optional voice profiles. It also adds sample-rate and microphone route-change fixes, with tests for capture, transcription, retention, and speaker profiles.

---

## Why two channels?

Most recorders give you one muddy mono mix. By hard-panning **system audio left** and **your mic right**, the channels stay cleanly separated:

- You can mute/solo either side in any audio editor.
- The channel layout helps attribute speech: the left channel carries desktop audio, and the right channel carries the microphone.
- When audio is retained, each source is written to its **own raw file continuously**, and the stereo mix is produced when you hit Save. The raw files remain available if the app crashes before mixing. Transcript-only mode writes no audio files.

---

## Features

- **One-click Record / Pause / Save / Trash** from a compact menu-bar panel.
- **Live level meters** for both channels (desktop L, mic R).
- **Calendar-aware**: the panel lists nearby meetings (last couple, the current one, and the next couple). Click one to start a recording named after it; the in-progress meeting is highlighted.
- **Live transcription** while recording: a local Whisper model transcribes the mixed desktop + mic audio in a sliding window and streams the text into the panel as it is spoken. A **copy button** grabs the transcript so far at any moment, and a **model switcher** (Tiny up to Large v3 Turbo) works even mid-recording.
- **Speaker labels** (toggleable): live lines are attributed **You** / **Them** in real time from the channel layout (mic = you, desktop = remote). Transcribing a saved file instead runs **on-device pyannote diarization** (SpeakerKit, CoreML) and labels voices **Speaker 1, 2, ...**, which also separates multiple remote participants.
- **Audio-retention modes**: save only the live transcript, keep audio with an optional live transcript, or keep audio with offline transcription as a fallback.
- **Markdown and JSON transcripts**: save `transcript.md` alongside a structured `transcript.json` used for speaker renaming and Markdown rendering.
- **Speaker renaming and optional voice profiles**: rename speakers under a finished transcript and recognize saved desktop voices in later offline transcriptions. Voice profiles are disabled by default.
- **Recordings library**: browse and re-open past recordings and their transcripts right from the panel, even after a relaunch.
- **Silence auto-stop**: ends a recording after a configurable period of two-channel silence (default 5 min), so a forgotten recording doesn't run forever.
- **Meeting-end notification** with a "Stop Recording" action when a meeting's scheduled end passes while you're still recording.
- **System-audio watchdog** that rebuilds the Core Audio tap if macOS's known process-tap regression makes it go silent mid-recording.

---

## How it works (architecture)

The design is documented in depth in [`docs/research-notes.md`](docs/research-notes.md). The short version:

| Concern | Approach |
| --- | --- |
| **Desktop audio** | Core Audio **process tap** (`CATapDescription` + `AudioHardwareCreateProcessTap`) wrapped in a tap-only private aggregate device, driven by an IOProc. Needs only the *Audio Recording* permission, **not** Screen Recording. |
| **Microphone** | A separate `AVAudioEngine` input tap. Format is read from the device (never hardcoded, Bluetooth mics report odd sample rates). |
| **Two captures, merged on stop** | When retaining audio, each source streams to its own raw `.caf`. They're aligned (via first-buffer host-time skew), resampled to a common 48 kHz, interleaved (L=desktop, R=mic), and encoded to AAC `.m4a` on Save. The raw files are kept. Transcript-only mode feeds live transcription without destination audio files. |
| **Realtime safety** | The system-audio callback downmixes incoming samples into a lock-free single-producer/single-consumer [ring buffer](Sources/Recorder/FloatRingBuffer.swift). A background writer drains it for persistence and transcription, keeping file I/O off the realtime callback. |
| **Transcription** | On-device Whisper via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML, ANE-accelerated). While recording, both captures feed a lock-guarded inbox on their non-realtime writer paths, get resampled to 16 kHz mono and mixed, and a tick loop re-transcribes a sliding ~25 s window every few seconds, confirming all segments but the trailing one. Saved files are transcribed offline through the same model. |
| **Diarization** | Live: per-channel energy envelopes attribute speech to **You**/**Them** when one channel dominates; ambiguous speech can remain unlabeled. Offline: decode desktop and microphone channels separately through the selected Whisper model, label the microphone **You**, diarize desktop voices with SpeakerKit, then merge timestamped results. |
| **Model lifecycle** | One model host manages downloading, loading, and switching, and serializes access to the selected Whisper model. Live and offline transcription share that model. |
| **Transcripts and profiles** | JSON stores text, metadata, stable speaker IDs, and display names; Markdown is rendered from it. Optional voiceprints are stored separately in Application Support. |

---

## Requirements

- **macOS 15+** (the realtime ring buffer uses the `Synchronization` module's `Atomic`).
- **Xcode 26 / Swift 6.x** to build. Developed and tested on macOS 26.3, Apple Silicon.
- **Network on first use of a model**: transcription runs fully offline, but each Whisper model (~110 MB to ~630 MB) is downloaded once from Hugging Face into `~/Library/Application Support/Recorder/WhisperModels`.

---

## Build & run

```sh
./build.sh           # swift build -c release, then assemble + ad-hoc-sign Recorder.app
open ./Recorder.app  # launches as a menu-bar item (no Dock icon)
```

You can also open `Package.swift` in Xcode and run from there.

The app is **non-sandboxed** and **ad-hoc signed**. If you rebuild with a different signature, macOS may re-issue the permission prompts (TCC tracks the code signature). To use an installed signing identity, set `CODESIGN_IDENTITY` when running `build.sh`; a stable identity helps preserve permission grants across rebuilds.

---

## Permissions

Granted on first use via standard system prompts (declared in `Info.plist`):

- **Microphone:** capture your voice.
- **System Audio Recording:** capture desktop audio via the Core Audio process tap. This uses the audio permission and does not require Screen Recording.
- **Calendars (full access):** list nearby meetings and include their titles and invited attendees in transcripts.
- **Notifications:** show the meeting-end alert.

---

## Transcription setup

Nothing to configure for a first run: the default **Base** model (~150 MB, multilingual) downloads automatically the first time you record or transcribe. In the panel or under **Settings → Transcription** you can:

1. **Switch models**: Tiny / Base / Small / Small compressed / Large v3 Turbo compressed. All listed models handle German and English.
2. **Pick a language** or leave it on auto-detect (re-detected per window, so mixed German/English meetings work).
3. Toggle **live transcription**, which shows text in the panel while recording. Speaker labels are controlled separately in **Settings > Speakers**, and audio retention in **Settings > Recording**.

Transcription runs on-device; the app does not upload audio or text. Live recordings can label speakers **You**/**Them** from channel energy. An offline pass decodes each channel separately: the microphone is **You**, and desktop voices receive **Speaker 1, 2, ...** labels through SpeakerKit's pyannote diarization (an approximately 50 MB one-time model download). This assumes the app's desktop-left, microphone-right layout. Multiple people sharing the microphone receive the same **You** label.

Transcripts are saved as `transcript.md` and `transcript.json`. Both live and offline transcription use the selected Whisper model, with no separate high-quality model.

## Audio handling

In **Settings > Recording**, choose what a recording saves:

| Mode | Audio files | Transcript |
| --- | --- | --- |
| **Transcript only** | None, including temporary audio files. | Saves the live transcript as Markdown and JSON. Requires live transcription. |
| **Keep audio** | Raw desktop and microphone CAF files, plus the stereo AAC mix. | Saves the live transcript when enabled. Saved audio can be transcribed later. |
| **Keep audio and run a high-quality pass** (default) | The same files as Keep audio. | Saves a complete live transcript if available; otherwise transcribes the saved mix offline. |

A complete live transcript is saved directly, including in the default mode. In the default mode, an unavailable or incomplete live transcript triggers an offline pass over the saved mix. You can also request transcription of saved audio from the Recent list.

During a recording, you can switch to **Transcript only**. This closes and deletes partial audio files while transcription continues. You cannot switch back to keeping audio during that recording, because the earlier audio is gone.

Transcript-only recordings cannot be transcribed again. Their transcript is written when you save, so a crash can lose the transcript even though no audio files remain.

## Speaker profiles and privacy

In **Settings > Speakers**, enable **Match voices to saved profiles** to recognize desktop voices in later offline transcriptions. After an offline transcription, rename a speaker under the finished transcript to create or update a profile. Renaming **You** changes only the display name and never creates a microphone voiceprint.

Automatic matches apply names without adding voiceprints to profiles. Correcting a name retracts that recording's contribution from the previous profile before adding it to the corrected profile. Matching and enrollment require at least six seconds of speech from the cluster. Unmatched voices keep their generic speaker labels.

Voiceprints stay in `~/Library/Application Support/Recorder/Speakers/`, outside recording folders. Pending voiceprints are pruned after 30 days when the app initializes. You can delete individual profiles or use **Delete all voice data** to remove profiles and pending voiceprints. Turning matching off does not delete stored voice data.

Transcripts contain speaker names, meeting titles, invited attendees, and spoken content. They contain no voiceprint vectors, but can still contain personal information. Deleting voice data leaves names already written into transcripts intact.

---

## File layout

Recordings land in `~/Documents/Recordings/{YYYY-M-D}-{HHMM}[-{meeting}]/`:

```
desktop.caf      raw mono system audio (written during capture)
mic.caf          raw mono microphone (written during capture)
audio.m4a        stereo AAC mix: desktop = L, mic = R (produced on Save; raw files kept)
transcript.md    timestamped Markdown transcript (if transcription produced text)
transcript.json  structured transcript, metadata, speaker IDs, and display names
```

CAF (not WAV) is used for the raw files so long meetings don't hit the 4 GB WAV ceiling.

In transcript-only mode, the folder contains only the transcript files when transcription succeeds. Downloaded models and optional voice profiles are stored separately:

```text
~/Library/Application Support/Recorder/
  WhisperModels/             downloaded Whisper and diarization models
  Speakers/
    profiles.json            named profiles and their voiceprints
    pending/<uuid>.json      voiceprints associated with finished transcriptions
```

`transcript.json` can refer to pending voiceprints by UUID, but stores no voiceprint vectors.

---

## Project structure

```
Sources/Recorder/
  RecorderApp.swift          MenuBarExtra scene + app delegate adaptor
  AppDelegate.swift          .accessory activation policy; notification setup
  RecorderModel.swift        @Observable state machine; owns captures, monitors, meetings
  Preferences.swift          typed UserDefaults wrapper (model, language, retention, profiles)
  PreferencesView.swift      General, Recording, Transcription, and Speakers settings
  AudioHandlingMode.swift    retention modes and rules for changing mode while recording
  SystemAudioTap.swift       process tap + aggregate + IOProc → desktop.caf; watchdog
  FloatRingBuffer.swift      lock-free SPSC ring buffer (realtime-safe capture path)
  MicCapture.swift           AVAudioEngine input tap → mic.caf
  AudioMonitors.swift        RMS → dBFS metering + dual-channel silence monitor
  StereoMixer.swift          align + resample + interleave (L=desktop, R=mic) + AAC → m4a
  LocalTranscription.swift   model catalog, per-channel offline decode, SpeakerKit diarization
  LiveTranscriber.swift      sliding-window transcription and live You/Them labels
  ModelHost.swift            serialized model loading, switching, and inference
  WhisperModelStorage.swift  model downloads and local paths
  SampleInbox.swift          sample buffering, mixing, and channel energy envelopes
  RealtimeResampler.swift    sample-rate conversion for live audio
  OfflineTranscription.swift merges per-channel segments and speaker evidence
  TranscriptDocument.swift   structured JSON, speaker renaming, and Markdown rendering
  TranscriptLine.swift       timestamped transcript lines
  SpeakerNaming.swift        resolves generic labels and saved voice matches
  SpeakerProfile.swift       voice centroids, profile types, and matching
  SpeakerProfileStore.swift  profile persistence, pending voiceprints, and deletion
  CalendarAccess.swift       EventKit: full-access auth, meetings-around-now
  NotificationManager.swift  meeting-end alert + "Stop Recording" action
  RecordingsLibrary.swift    reads ~/Documents/Recordings for the past-recordings list
  RecorderPanel.swift        the menu-bar .window panel: controls, meters, meetings, settings
  Shared.swift               small shared types/helpers
docs/research-notes.md       SDK-verified API rationale behind the design
docs/superpowers/            transcription and speaker-profile designs and plans
Tests/RecorderTests/         unit tests and opt-in hardware/model verification
```

---

## Tests

On a Mac with the build requirements installed, run:

```sh
swift test
```

Hardware and model verification tests are opt-in through `RECORDER_*` environment variables documented in their test files. They cover live capture, microphone route changes, model inference, the retention-mode matrix, and real-recording diarization. Some require audio permissions, download models, or change the default input device.

## Limitations and possible future work

- Voice-profile matching can misidentify speakers. You can correct their names in the transcript.
- Re-encoding the kept raw files to Opus/`.ogg` (the raw `.caf` files make this lossless).
- Continuous clock-drift slope correction for multi-hour recordings (sub-100 ms residual drift is acceptable for personal use).
- Acoustic echo cancellation (assumes headphones; AEC would muddy the deliberate hard channel separation).
- Streaming model-based diarization (Speaker N labels updating live). Live labels are channel-based (You/Them); clustered per-voice labels currently require the offline pass over the saved file.

---

## License

[MIT](LICENSE).
