# Speaker profiles: per-channel decode, voice fingerprints, naming

Date: 2026-08-20. Status: approved, ready to plan.

This slice implements speaker naming and voice profiles from the
[2026-08-19 dual-model design](2026-08-19-dual-model-transcription-design.md), and
corrects one decision in it. The dual-model polish pass and calendar-attendee
guessing stay deferred.

## Correction to the 2026-08-19 spec

That spec assigned `AudioChannelLoader` to the polish pass and built naming rule 1
("mic-dominant cluster becomes You") on top of energy analysis of a mono mix. Reading
the code showed that framing was wrong in two ways.

`StereoMixer` already writes the two sources to known channels
(`ch0 = desktop / L`, `ch1 = mic / R`) and pads each by its host-time offset, so the
channels are sample-aligned on disk. The offline path then discarded that separation
by accident, not by design: it called
`AudioProcessor.loadAudioAsFloatArray(fromPath:)` and inherited the default
`channelMode: .sumChannels(nil)`. `ChannelMode.specificChannel(Int)` already exists,
so loading one channel is an argument, not a new unit. `AudioChannelLoader` does not
need to exist.

With the channels kept apart, "You" stops being a heuristic. The microphone channel
is the user by construction, so rule 1 needs no energy margin, no threshold, and has
no failure mode with headphones or a shared room mic. Per-channel decode moves into
this slice; the second model does not come with it.

## Scope

In scope:

1. Per-channel offline decode, replacing the mono sum.
2. Structured offline transcript lines, replacing the markdown-blob placeholder.
3. `SpeakerProfileStore`: voiceprint persistence, matching, enrollment, deletion.
4. Naming precedence and its two calibration constants.
5. Rename UI in the panel and a Speakers pane in Preferences.

Out of scope, still owned by a later slice: the high-quality polish pass and its
second model host and picker, and calendar-attendee guessing.

## Architecture

| Unit | Responsibility | Depends on |
| --- | --- | --- |
| `SpeakerProfileStore` (new) | `profiles.json` and `pending/`, matching, enrollment, retraction, deletion | injected base URL |
| `SpeakerNaming` (new) | naming precedence and the two constants, pure functions | nothing |
| `OfflineTranscription` (new) | the structured result of an offline pass: lines plus cluster evidence | nothing |
| `LocalTranscriptionEngine` (changed) | per-channel decode, desktop-only diarization, chronological merge | WhisperKit, SpeakerKit |
| `TranscriptDocument` (changed) | gains `speakerCentroidsID` | nothing |
| `RecorderModel` (changed) | owns the store, applies renames, exposes the chip list | store, engine |
| `RecorderPanel` (changed) | rename chips under a finished transcript | model |
| `PreferencesView` (changed) | Speakers tab | model, store |

`SpeakerNaming` holds no state and touches no disk, so precedence is testable without
a filesystem or a model. `SpeakerProfileStore` takes its base directory by injection,
so tests run against a temporary directory.

## Offline transcription flow

1. Read the audio file's channel count. One channel means a legacy or external
   recording: fall back to today's behaviour (sum, transcribe once, diarize
   everything, no "You" label) and skip to step 7.
2. Load `ch0` (desktop) and `ch1` (mic) separately via
   `.specificChannel(0)` and `.specificChannel(1)`.
3. Skip a channel whose RMS is below the silence floor, so a solo recording or a
   listen-only meeting does not pay for a second decode pass.
4. Transcribe each surviving channel through the existing `WhisperModelHost`,
   serialized. WhisperKit carries mutable decode state, so the two passes run one
   after the other through `host.withPipe`, never concurrently.
5. Diarize the desktop channel only. The mic channel needs no diarization: it is one
   person by construction, and diarizing it would risk splitting the user into
   several profiles.
6. Label: every mic segment gets id `you`; desktop segments get cluster ids `s1`,
   `s2`, ... in order of first speech.
7. Merge all segments chronologically by start time. The channels are sample-aligned,
   so the two timelines are directly comparable.

The result is an `OfflineTranscription`:

```swift
struct OfflineTranscription {
    var lines: [TranscriptLine]                    // speaker holds the id, not the display name
    var clusters: [String: ClusterEvidence]        // desktop clusters only, keyed by id
    var speakerNames: [String: String]             // id -> resolved display name
}

struct ClusterEvidence {
    var centroid: [Float]
    var speechSeconds: Double
}
```

Cluster evidence covers desktop clusters only. The mic channel never produces
evidence, so the rule that the microphone never creates or updates a profile is a
property of the data flow rather than a guard that can be forgotten.

## Naming precedence

Per speaker id, the first rule that fires wins.

| Condition | Label |
| --- | --- |
| Mic channel | `You` |
| Desktop cluster, profile match within threshold | the profile's name |
| Desktop cluster, otherwise | `Speaker N`, numbered by first speech |

Renaming `You` is allowed and changes the display label only. It never writes a
profile.

Two guards on matching:

- A cluster with less than the minimum speech duration may neither match nor enroll.
  Short clusters are the ones most likely to attach a real person's name to the wrong
  voice.
- A profile may be used at most once per recording. Matches are assigned greedily by
  ascending distance, and a cluster whose best profile is already taken falls back to
  `Speaker N`. Without this, two people in one meeting can both come out as "Anna".

## Constants and calibration

Both live together in `SpeakerNaming`, as the one place to tune.

| Constant | Value | Why |
| --- | --- | --- |
| `matchDistance` | `0.45` | Cosine distance in SpeakerKit's `[0, 2]` convention. |
| `minSpeechSeconds` | `6` | Below this, a centroid is too noisy to name a person by. |

SpeakerKit declines to define a universal same-speaker threshold, so `0.45` is ours.
The anchor: SpeakerKit's own *within-run* clustering threshold is `0.6`
(`SpeakerClustering.defaultThreshold`). Matching *across* recordings crosses changes
of microphone, room, and codec, and it attaches a named human being rather than an
anonymous cluster number, so this slice is deliberately stricter than the value used
to split clusters inside a single file. Both constants are provisional until
calibrated against real recordings.

`DiarizationResult.speakerCentroidEmbeddings` is populated by default: `centroidSource`
defaults to `.finalAssignment`, the mean of all embeddings under the final speaker
labels. Centroids are raw embedder output, unnormalised and pre-PLDA, which is fine
because `MathOps.cosineDistance` normalises by magnitude.

## Storage

`~/Library/Application Support/Recorder/Speakers/`

`profiles.json`:

```json
{
  "profiles": [
    {
      "id": "UUID",
      "name": "Anna",
      "createdAt": "ISO8601",
      "updatedAt": "ISO8601",
      "centroids": [
        { "vector": [0.1, 0.2], "sampleSeconds": 42.0, "addedAt": "ISO8601" }
      ]
    }
  ]
}
```

Up to **8 centroids per profile, FIFO**. Several centroids rather than one running
mean, so matching is nearest-of-any, which survives different microphones and rooms
far better than an average of them does.

`pending/<uuid>.json`, one per transcription that produced desktop clusters:

```json
{
  "id": "UUID",
  "createdAt": "ISO8601",
  "clusters": {
    "s1": { "vector": [0.1], "speechSeconds": 42.0, "appliedProfileID": "UUID or null" }
  }
}
```

`transcript.json` gains `speakerCentroidsID: String?`, holding that uuid and nothing
else. Adding an optional field is backward compatible, because synthesized `Codable`
decodes optionals with `decodeIfPresent`, so transcripts written before this change
still load.

Embeddings stay out of the recording folder deliberately. An embedding is biometric
data under GDPR Art. 9. Keeping it in Application Support means a transcript folder
you share carries no voiceprint, and "delete all voice data" stays a single directory
removal. Pending entries are pruned after 30 days.

When voice profiles are disabled, which is the default, no centroid is ever written:
no pending file is created, and renames change display names only.

## Enrollment by correction

Auto-matching names a speaker but never writes to disk. Only an explicit user action
enrolls, so the profile database never grows from a guess the user did not see.

Applying name `N` to cluster `c`:

1. If `pending.clusters[c].appliedProfileID` is set and that profile's name is not
   `N`, retract the centroid this recording contributed to it. That is the correction
   case: the user confirmed "Anna", then changed it to "Ben".
2. Append `c`'s centroid to the profile named `N`, creating that profile when it does
   not exist, and evicting the oldest centroid when the profile already holds 8.
3. Record `appliedProfileID` in the pending file.
4. Set `speakerNames[c] = N` in `transcript.json` and re-render `transcript.md` from
   it.

Confirming a correct auto-name is the same action as renaming, applied to the name
already shown, which is what makes profiles strengthen with use.

Two cases skip steps 1 to 3 and rename the display only: the `you` id, and any
cluster below `minSpeechSeconds`.

## UI surfaces

**Panel**, under a finished transcript: a row of chips, one per speaker id in order of
first speech, each showing the current display name. A chip marked as an automatic
profile match reads as such until applied. Clicking a chip opens a small popover with
a text field prefilled with the current name; applying it runs the enrollment steps
above and re-renders the markdown.

**Preferences, new Speakers tab**: the existing "Label speakers" toggle moves here
from the Transcription tab; a "Match voices to saved profiles" toggle, off by default,
with the Art. 9 implication stated plainly; the profile list with per-profile delete;
and "Delete all voice data", which removes `profiles.json` and `pending/` together.

## Error handling

- Diarization failure leaves desktop lines unlabeled. The mic lines keep "You", and
  the transcript is still written. Naming degrades; transcription does not.
- A decode failure on one channel keeps the other channel's transcript rather than
  failing the recording.
- An unreadable or corrupt `profiles.json` is moved aside to `profiles.json.corrupt`
  and treated as empty, so one bad file cannot crash the app or silently discard
  every profile on the next write.
- A missing pending file makes renames display-only. A transcript whose centroids were
  pruned can still be relabeled; it just cannot enroll.
- A store write failure surfaces in the status line and never blocks the transcript
  itself.

## Testing

Unit, no filesystem or model required:

- `SpeakerNaming`: precedence order, the duration gate, one-profile-per-recording,
  greedy assignment by ascending distance, `you` never enrolled.
- Chronological merge: interleaved channels come out in start-time order, ids assigned
  by first speech.
- `TranscriptDocument`: a `transcript.json` written before this change still decodes,
  with `speakerCentroidsID` nil.

Unit, against a temporary directory:

- `SpeakerProfileStore`: round-trip persistence, create-on-enroll, FIFO eviction at 8,
  match inside and outside the threshold, nearest-of-any across several centroids,
  retraction removing exactly the centroid this recording added, per-profile delete,
  delete-all clearing `pending/` too, corrupt-file quarantine.

Gated behind an environment variable, in the style of the existing verification tests:

- A real stereo recording produces populated `speakerCentroidEmbeddings`, mic segments
  labeled "You", and desktop segments clustered separately. This is the check that the
  default `centroidSource` really does populate centroids in practice.

## Deferred

The high-quality polish pass, the second model host and its picker, and
calendar-attendee guessing keep the design given in the 2026-08-19 spec. Per-channel
decode landing here removes the largest piece of groundwork that pass needed.
