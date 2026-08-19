# Dual-model transcription with speaker naming and a no-retention mode

Date: 2026-08-19
Status: approved design, ready for implementation planning

## Goal

Three capabilities, one coherent design:

1. **Two selectable models.** A small fast model streams the transcript live while
   recording. A separate, larger model optionally re-transcribes the finished
   recording at higher quality.
2. **Speaker detection and names.** The high-quality pass labels speakers and names
   them, learning voices from your corrections over time.
3. **A GDPR "not recording, only transcription" mode.** When you do not want the
   high-quality pass, the app streams the transcript live and never writes audio to
   disk at all.

The three are linked: the high-quality pass needs audio to exist after the recording
ends, so choosing it is choosing retention. Making that trade visible in one control
is a requirement, not an implementation detail.

## Non-goals

- No language-model rewriting of transcripts, cloud or local. "Cleanup" means a
  better acoustic transcription with correct segment boundaries and speaker labels.
- No cloud services of any kind. Everything runs on this Mac.
- No changes to the recording folder layout beyond one new sidecar file.

## Decisions

| Question | Decision |
|---|---|
| What does "cleanup" mean | A second WhisperKit pass over the recorded file, with VAD chunking and diarization. No LLM stage. |
| Where speaker names come from | Auto-label, then rename; voice profiles and calendar guessing are both available as options. |
| How profiles are created | Enrollment by correction. Renaming a speaker stores that voice; confirming a correct guess reinforces it. |
| How retention is chosen | One three-way "Audio handling" mode, so the privacy guarantee is a single unambiguous statement. |
| Scope of that choice | A global default plus a per-recording override, changeable before or during a recording. |
| Model hosting | Split into a reusable single-model host, instantiated twice. |
| Decode strategy for the polish pass | Two independent per-channel decodes, not one decode of the downmix. |
| Where voiceprints live | Application Support, never beside the transcript. |
| What `transcript.md` contains | The best available transcript, polished when a pass ran. The live transcript is kept in the JSON sidecar. |

## Architecture

`LocalTranscription.swift` is 954 lines holding a model catalog, a resampler, a
thread-safe audio inbox, a live sliding-window decoder and an offline file
transcriber. Adding a second model to it would make its central invariant harder to
see, not easier: "one pipe must never transcribe twice concurrently" is enforced by
class-wide `ticking` and `offlineBusy` flags, and with two pipes that invariant
becomes per-pipe. So the file splits into focused units.

| Unit | Job | Depends on |
|---|---|---|
| `WhisperModelHost` | Owns one `WhisperKit`: download, load, state machine, and its own decode serialization | WhisperKit |
| `SampleInbox` (+ `StreamResampler`, `DrainedAudio`) | Thread-safe capture to consumer hand-off, resampling, per-channel energy | nothing |
| `LiveTranscriber` | Sliding-window tick loop, confirm and hypothesis, You/Them channel attribution | `liveHost`, `SampleInbox` |
| `PolishPass` | File to per-channel decode to diarize to named speakers to structured result | `polishHost`, `SpeakerProfileStore` |
| `SpeakerProfileStore` | Voiceprint persistence, cosine matching, enrollment, deletion | SpeakerKit embeddings |
| `AudioChannelLoader` | Reads `audio.m4a` into two 16 kHz mono arrays | AVFoundation |
| `TranscriptDocument` | `transcript.json` to `transcript.md` rendering, including re-render after a rename | nothing |

Two hosts, `liveHost` and `polishHost`, share the same on-disk model cache. The
concurrency story becomes one sentence: **each host serializes only itself, so a
polish pass on the large model runs while the next meeting streams on the small
one.** That matters in practice, because meetings run back to back.

When both selections name the same variant, `polishHost` is not instantiated and the
polish pass borrows `liveHost`, avoiding double resident memory for an identical
model.

`transcript.json` is written in every mode that produces a transcript, transcript-only
included. It holds text, timings and speaker labels, never audio and never
embeddings, so it is safe to keep alongside a recording that deliberately retains no
audio.

`TranscriptDocument` exists because of the rename requirement. Patching speaker names
by editing markdown is fragile, so the structured transcript in `transcript.json`
becomes the source of truth and `transcript.md` is a pure render of it. A rename
re-renders rather than patches, which makes it idempotent and testable.

## Audio handling modes

```swift
enum AudioHandlingMode { case transcriptOnly, keepAudio, keepAudioAndPolish }
```

`MicCapture.start(writingTo:)` and `SystemAudioTap.start(writingTo:)` take an
**optional** URL. Nil means no `AVAudioFile` is ever created. The ring buffer and
writer thread still run, so `onSamples` still feeds the inbox and levels, meters and
silence auto-stop are unaffected. `RecordingSession` gains optional `desktopURL`,
`micURL` and `outputURL`. The folder is still created, because `transcript.md` needs
a home, and `StereoMixer` is simply never invoked.

This is deliberately not "record then delete". Because the file handle is never
opened, a crash mid-recording leaks nothing, which a delete-afterwards design can
never promise. The compliance claim is structural rather than procedural.

### The RAM buffer is a privacy parameter

Today the live window may grow to `maxWindowSamples`, 15 minutes, when the model
falls behind. In transcript-only mode that buffer **is** the retention, so it drops
to **90 seconds**, and overflow drops the oldest samples with the existing gap
marker. In the two keep-audio modes the cap stays at 15 minutes, because the audio is
on disk anyway and a longer buffer only helps the transcript catch up. Ninety seconds absorbs a slow model on a busy Mac; past that, losing words
beats holding a quarter hour of a confidential call in memory. Dropped and
end-of-session buffers are explicitly zeroed before release, because the compliance
claim rests on exactly that.

### Mid-recording changes

Downgrading to transcript-only calls a new `stopWriting()` on both captures, which
closes the `AVAudioFile` while capture continues, then deletes the partial files.
Upgrading mid-recording is refused with a message, because the earlier audio no
longer exists and a half-recording would misrepresent itself.

### One preference is removed

`autoTranscribe` is fully subsumed by the mode matrix and is deleted.

| Live transcription | Mode | Result |
|---|---|---|
| on | transcriptOnly | live transcript only, no audio ever on disk |
| on | keepAudio | `audio.m4a` plus live transcript |
| on | keepAudioAndPolish | `audio.m4a` plus live transcript, replaced by the polished one |
| off | transcriptOnly | refused, nothing would be produced |
| off | keepAudio | audio only, no transcript |
| off | keepAudioAndPolish | audio plus polished transcript, no live streaming |

The refused combination is disabled in the picker rather than failing at runtime.

## The polish pass

Five stages, each reporting progress.

1. **Per-channel load.** `audio.m4a` is read into two 16 kHz mono arrays, `desktop`
   and `mic`. Not via `AudioProcessor.loadAudioAsFloatArray`, which sums to mono and
   destroys exactly the information the pass needs.
2. **Two independent decodes** on `polishHost`, with `wordTimestamps: true` and
   `chunkingStrategy: .vad`. A mic-channel segment is you by construction and a
   desktop-channel segment is a remote participant, so decoding separately preserves
   that certainty instead of asking a diarizer to rediscover it from a mixture. The
   cost is roughly 2x decode time on a pass that already runs after the fact.
3. **Two independent diarizations**, `centroidSource: .finalAssignment` so every
   cluster carries a centroid. Desktop yields the remote participants. Mic normally
   yields one cluster, you; when it yields more, as in an in-person meeting around one
   laptop, the cluster with the most total speech is you and the rest are treated as
   ordinary speakers.
4. **Alignment** via `DiarizationResult.addSpeakerInfo(to:strategy: .subsegment)`,
   which uses word timings and can split a Whisper segment when the speaker changes
   mid-sentence. This replaces the hand-rolled `assignSpeakers` overlap function,
   which cannot.
5. **Merge** both channels' labeled segments chronologically, name the speakers, and
   render.

## Speaker naming and voice profiles

Per cluster, the first rule that fires wins.

1. Mic-dominant cluster becomes **"You"**.
2. **Voice profile match**, when profiles are enabled: nearest stored centroid within
   the threshold.
3. **Calendar guess**, when enabled and the desktop cluster count equals the number of
   invited attendees excluding you: assign in order of first speech, rendered as
   `Anna (?)` until confirmed. An unmarked wrong name is worse than no name.
4. Otherwise **"Speaker N"**.

Renaming "You" is allowed and changes the display label only. The mic channel is
identified structurally rather than by voice, so it never creates or updates a
profile.

`SpeakerKit` exposes `DiarizationResult.speakerCentroidEmbeddings` publicly, along
with `nearestSpeakerCentroid(to:)` and `centroidCosineDistance(between:and:)`, so
profiles need no new model and no new math. Argmax explicitly declines to define a
universal same-speaker threshold, so these two constants are ours and live together
in one place, to be calibrated against real recordings:

- match at cosine distance <= 0.45
- require >= 6 s of speech in a cluster before it may match or enroll

### Storage

`~/Library/Application Support/Recorder/Speakers/`

- `profiles.json`: per person, an id, a name, up to **8 centroids FIFO**, sample
  seconds and timestamps. Several centroids rather than one running mean, so matching
  is nearest-of-any, which survives different mics and rooms far better than an
  average of them.
- `pending/<uuid>.json`: a finished recording's cluster centroids, awaiting a rename.

Pending centroids are deliberately **not** stored in the recording folder. An
embedding is biometric data under GDPR Art. 9, so keeping it out of `~/Documents`
means a transcript you share carries no voiceprint, and "delete all voice data"
remains a single directory removal. Pending entries are pruned after 30 days.

### Enrollment by correction

Renaming Speaker 2 to "Anna" appends that cluster's centroid to Anna's profile,
creating it when new. Confirming a correct auto-name also appends, so profiles
strengthen with use. Correcting a wrong auto-name retracts the centroid it just added
from the wrong profile before adding it to the right one.

Profiles are off by default. The Speakers pane lists every profile with per-profile
delete plus "Delete all voice data", which also clears `pending/`.

## UI surfaces

**Preferences, Transcription**: two model pickers, "Live model" defaulting to Base
and "High-quality model" defaulting to Large v3 Turbo compressed, each with its own
download and load status row because the hosts have independent state machines. A
note appears when both name the same variant.

**Preferences, Recording**: the three-way "Audio handling" picker, with a footer
stating exactly which files each mode leaves on disk.

**Preferences, Speakers**: label-speakers toggle; voice profiles toggle, off by
default, with the Art. 9 implication stated plainly; the profile list; the calendar
guess toggle.

**Panel**: a mode chip beside Record that changes the mode before or during a
recording, and a persistent "Transcript only, no audio saved" badge while recording
in that mode. After stop, polish progress, then the final transcript replacing the
live section, with a row of rename chips per detected speaker. Applying a rename
re-renders `transcript.md` from `transcript.json` and updates profiles.

## Error handling

- A failed polish pass is never destructive. `transcript.md` keeps the live
  transcript and the status line explains what happened.
- A missing or undownloadable polish model degrades to the live transcript, marked
  unpolished.
- One polish pass runs at a time so memory stays bounded, but it runs concurrently
  with the next recording's live stream.
- Renames are applied to `transcript.json` first and `transcript.md` is re-rendered
  from it, so a crash mid-rename cannot desynchronise the two.

## Testing

The design deliberately concentrates logic in pure units so most of it is testable
without audio hardware.

- `TranscriptDocument`: render, and rename idempotence across repeated applications.
- `SpeakerProfileStore`: matching at and around the threshold, minimum-speech
  gating, enrollment, reinforcement, and retraction on correction.
- `WhisperModelHost`: the state machine, including a failed switch keeping the
  previously loaded model alive.
- `AudioChannelLoader`: per-channel extraction against a known stereo fixture.
- Mode matrix: which files exist on disk after each of the three modes, plus the
  assertion that transcript-only never creates an audio file.
- Existing `RealtimeResampler`, `SampleInbox` and downmix tests continue to cover the
  capture layer.

## Build sequence

1. Extract `WhisperModelHost`, `SampleInbox` and `TranscriptLine` out of
   `LocalTranscription.swift` with no behaviour change, keeping tests green.
2. Extract `LiveTranscriber` onto `liveHost`.
3. Add `TranscriptDocument` and the `transcript.json` sidecar, rendering the existing
   transcript through it.
4. Add `AudioHandlingMode`, the optional capture URLs, and the mode matrix. Ship the
   GDPR mode here, before any of the polish work.
5. Add `AudioChannelLoader` and `PolishPass` on `polishHost`, without naming.
6. Add `SpeakerProfileStore`, naming precedence, and the rename UI.
7. Preferences and panel surfaces.

Step 4 delivers the privacy capability on its own, which is the part with a
compliance deadline attached. Steps 5 through 7 add quality on top.

This is too much for a single implementation plan, so it splits at that seam into two:

- **Plan A, steps 1 to 4**: the refactor plus the GDPR mode. Independently shippable,
  and valuable with no polish pass at all.
- **Plan B, steps 5 to 7**: the polish pass, speaker naming, profiles and the UI
  surfaces. Depends on Plan A's `WhisperModelHost` and `TranscriptDocument`.
