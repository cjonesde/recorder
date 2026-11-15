# Grill: live voice coach

Date: 2026-11-13 to 2026-11-14. Output type: shaped scope with a build order.

## Verdict

Build the coach as a module in the Recorder fork: a dependency-free core (audio samples and transcript lines in, HUD state and events out) plus one adapter file. Start with a one-day test on real speaker calls, then a thin live loop with pace and energy on the HUD. Every other detector runs silently and joins the HUD only once labelled clips show it is right about nine times in ten.

## Intent (confirmed in the interview)

| Dimension | Answer |
|:-|:-|
| Job | "I know what to fix, I forget in the moment." A prompter, not a report. |
| Habits, own voice | Rising or trailing statement endings, sounding irritated, too fast, "so" at sentence starts |
| Energy | Excitement is wanted. Show an always-visible energy level so going flat is noticed. |
| Channel | Small always-on-top HUD under the webcam. Slides sit on the same display. |
| Other side | Turn-taking and pace only. No tone reading of others, nothing stored about them. |
| Scenarios | Presentation, 1on1, group as presets. Calendar picks, one-click override. |
| Platform | macOS, German and English (one per call), desk speakers from day one |
| Prior evidence | A low-tech cue has changed his delivery mid-call before |
| Kill criteria | Distraction, false alarms, others noticing |
| After a call | Event log plus short clips of his own voice at flagged moments |
| Build | Full scope over weeks, HUD in real calls from the start, irritation logged first |
| Home | Main `recorder` repo. schriftlich.app is the split-off product and a possible later port. |

## Still open (asked, not answered: the session restarted)

The build order below assumes the recommended option for each. Change any of them and the plan shifts as noted.

1. **Proof.** Assumed: a coin flip on each trigger decides whether the cue is shown. Without withheld cues, "I corrected within seconds" cannot fail.
2. **Labelling.** Assumed: he marks flagged clips as right or false alarm, at least weekly. Without labels, thresholds are tuned by feel.
3. **Skill or recall.** Assumed: he can already produce each target on demand. Any habit he cannot produce in a practice take needs drills first, since a cue only reminds.
4. **Cuts.** Assumed: volume matching and live room balance are dropped.

Also open: the SECJUR AI Firewall returned UNKNOWN on § 5 (private use of company AI accounts). Whether this project is business or private use is Christopher's call.

## Panel

Feynman, Torvalds, Kahneman, Christensen (wildcard, arguing the ambitious product case), a speech-coach skeptic (added after The Critic found nobody argued against building live), The Critic. ColleagueBots were skipped: their persona files are missing and this is a personal project. The skill's `deliberation/protocol.md` is also missing, so the phases followed `SKILL.md`. The Critic's cross-examination and an independent source check were lost in a session restart. The code claims below were re-checked by hand.

| Voice | Position |
|:-|:-|
| Feynman | Pitch slope, syllable rate and who-makes-sound-when are measurable live. Irritation has no physical definition yet. Volume matching and room balance are not measurable on these streams. |
| Torvalds | Passive listener on two existing streams plus one floating panel. Gate on the echo, do not cancel it. Shadow mode for every detector. |
| Kahneman | The success test passes with a blank HUD (regression to the mean). Coin flip per trigger. Live with pace only, 90% labelled precision before promotion. |
| Christensen | Build the thinnest live loop, not the thinnest feature set. Acoustic vocabulary only, never an "irritation score". Wedge: secrecy-bound professions. |
| Skeptic | A live cue buys compliance while on, not learning. Pace and "so" suit a live cue, tone never. Fade the cue and measure with it off. |
| The Critic | Speakers break Recorder's headphone assumption. Room balance is a should-want. |

## Where the panel agrees

- **Gate, do not cancel.** Score his voice on the mic only while the system audio tap is quiet. The tap is the exact signal driving the speakers. Apple voice processing is the wrong fix here: its gain control distorts the loudness that irritation and energy rely on.
- **Cut volume matching and room balance.** Teams has already levelled the remote voices, and "who is silent" needs voiceprints of other people.
- **Endings and "so" are shown as a rate** over the last few sentences. The event is over when it is detected.
- **Irritation stays log-only.** If it ever reaches the HUD, it is an action ("slower, lower"), never a label.
- **No text on the HUD.** Colour and shape only.

## Layer tensions (ideal versus real)

| Tension | Ideal | Real | Resolution |
|:-|:-|:-|:-|
| Success measure | "I correct within seconds" | Extremes return to normal without any cue | Coin-flip withholding, plus some cue-off calls |
| Learning | The cue fixes the habit | Cue-on gains can vanish when the cue goes | Fading schedule from the start |
| First step | Real HUD in a real call | Speakers may make the signals unusable | One day of recorded speaker calls first, then the HUD |
| Presets | Three scenarios in v1 | Each preset multiplies the tuning work | Last build step, as three small threshold sets |
| Clips | Kept for tuning | schriftlich.app forbids audio files | Clips live in the Recorder adapter only |
| Day-one HUD | Everything visible, rough edges accepted | False alarms are a kill criterion | Only pace and energy visible, the rest in shadow mode |

## Build order

0. **Speaker test (about a day).** Record three real calls on desk speakers in "Keep audio" mode. `audio.m4a` holds desktop left, mic right. Run `coach.py` on the mic channel with and without the tap-quiet gate, and mark 20 sentence endings by ear. If pace and endings do not survive the bleed, this is a headset tool.
1. **Core, HUD, gate.** New dependency-free target. Floating panel modelled on `DebugWindowController`. Own-voice gate from mic and tap energy.
2. **Event log.** Every detector's raw values and every trigger, shown or withheld.
3. **Pace and energy on the HUD.** Syllable rate and level against his own baseline, language independent.
4. **"So" counter** from his transcript lines (Apple engine only, Parakeet lags 11 to 13 s).
5. **Statement endings** as a rolling rate. Port `clean_f0` and `terminal_contour` from `coach.py`. Trailing off is a separate quantity that `coach.py` does not measure yet.
6. **Clips** of his own voice, only where the tap was quiet.
7. **Irritation proxies,** log only.
8. **Talk share and interruptions,** ambient.
9. **Presets,** picked from the calendar attendee count.

Deferred: pace matching, a preset editor, the port to schriftlich.app.

## Pre-mortem

The most likely failure: after weeks of building, the first important call on desk speakers produces a late or false cue, he hides the HUD and never turns it back on. Step 0 and shadow mode exist to prevent exactly that.

## Code facts checked

| Claim | Status |
|:-|:-|
| `configureCaptures()` wires `tap.onSamples` and `mic.onSamples` (`RecorderModel.swift:221`, `237`, `240`) | Confirmed |
| `TranscriptLine` has time, text, speaker, no word timings (`TranscriptLine.swift:10-12`) | Confirmed |
| `confirmedLines` on the live engine protocol (`LiveSpeechEngine.swift:45`) | Confirmed |
| You/Them from a 4x energy rule (`SpeakerAttribution.swift:45-46`) | Confirmed |
| One recognizer hears desktop plus mic mixed (`docs/apple-streaming.md`, Mix/submission row) | Confirmed |
| `audio.m4a` is desktop left, mic right (`StereoMixer.swift:5-6`) | Confirmed |
| `CalendarAccess.currentMeeting` with attendees (`CalendarAccess.swift:117`, `135`) | Confirmed |
| Floating `NSPanel` template (`DebugWindowController.swift:23`, `31`) | Confirmed |
| `MicCapture` uses `AVAudioEngine`, no voice processing (`MicCapture.swift:54`, `132`) | Confirmed |
| `terminal_contour` can return "unmeasured" (`coach.py:1187-1196`) | Confirmed |
| No echo cancellation, live labels are You/Them only (`README.md:204-205`) | Confirmed |
| Transcript aborts when audio ages 0.5 s | Partly: channels hold at most 500 ms, exact abort path not traced |
| `sharingType = .none` hides the HUD from Teams screen sharing | Untested, needs one real share |
| Teams leaves Recorder's mic stream untouched | Unverified |

## Before any product step

Legal review of three points: whether acoustic self-feedback counts as workplace emotion inference under EU AI Act Art. 5(1)(f), whether an own-voice baseline is a biometric profile, and what notice covers turn-taking analysis of other participants.

## The one thing to do first

Record three real calls on desk speakers with audio kept, and run `coach.py` on the mic channel.

## Implemented (2026-11-14, branch `voice-coach`)

Plan: `docs/superpowers/plans/2026-11-14-live-voice-coach.md`. The four open questions were built as assumed: coin flip per trigger (a setting, on by default), labelling in a review window, cuts kept. Drills for habits he cannot produce on demand are outside the code.

| Step | What exists | Commit |
|:-|:-|:-|
| 0 Speaker test | `Tools/SpeakerTest/speaker_test.py`: bleed lag and level, gated vs ungated pace and endings, ear-mark scoring | `ca5f364` |
| 1 Core, HUD, gate | `VoiceCoach` target (Foundation only), own-voice gate, floating bar | `6fb1b7a`, `ef64b8f`, `581fcc4` |
| 2 Event log | `coach.jsonl` per recording, shown, withheld and shadow triggers | `350728e`, `581fcc4` |
| 3 Pace and energy | Syllable nuclei rate and level against his baseline, on the bar | `e19ec1f`, `581fcc4` |
| 4 "So" counter | Own lines, Apple engine only, shadow | `33e66d9` |
| 5 Endings | `clean_f0` and `terminal_contour` ported and checked against `coach.py` output, plus a trailing-off rate, shadow | `d17ba8c` |
| 6 Clips | 8 s own-voice clips where the tap was quiet, labels, promotion at 20 labels and 90% | `7745752` |
| 7 Irritation proxies | `raisedVoice`: pitch and level offsets, onset slope, log only, never promotable | `2806895` |
| 8 Talk share, interruptions | Logged; talk share can be put on the bar as a ring | `2806895` |
| 9 Presets | From the calendar attendee count, override from the bar or panel | `21432c9` |

Still needs real calls, in this order:

1. Step 0: three calls on desk speakers with Keep audio, then `speaker_test.py analyze` and 20 ear marks.
2. One real screen share to confirm `sharingType = .none` hides the bar.
3. One Teams call to confirm Teams leaves Recorder's mic stream untouched.
4. Thresholds (pace ratio per preset, ending and trailing rates, raised-voice offsets) are first guesses and get tuned from labels.
