---
name: run-recorder
description: Use when asked to build, launch, run, open, screenshot or click through the Recorder menu-bar app in this repo, or to check that a change works in the real app rather than in tests.
---

# Run Recorder

Recorder is a menu-bar-only app: no Dock icon, no main window. Its whole UI is a panel under the microphone icon in the menu bar, and that panel opens only on a real mouse click. Accessibility `click` and `AXPress` on the menu bar item report success and open nothing.

## Quick reference

All paths are relative to the repo root.

| Goal | Command |
|---|---|
| Build signed and launch | `bash .claude/skills/run-recorder/scripts/launch.sh` |
| Open the panel, screenshot it, print its text | `bash .claude/skills/run-recorder/scripts/open-panel.sh <png path>` |
| Close the panel | `bash .claude/skills/run-recorder/scripts/close-panel.sh` |
| Is it idle? | `osascript -e 'tell application "System Events" to tell process "Recorder" to get name of menu bar item 1 of menu bar 2'` prints `Microphone` when idle |
| Read settings | `defaults read com.tobi.Recorder` (for example `coachEnabled`) |

After `open-panel.sh`, look at the screenshot with the Read tool. A blank or cropped image means the panel closed before the capture: run the script again.

## Rules

- **Never kill a running Recorder.** It may be recording a meeting. `launch.sh` exits with code 2 when the repo's app is already running: use the running app, or ask the user to quit it if you need a fresh build.
- **Sign with the Apple Development identity.** `launch.sh` picks it from `security find-identity`. An ad-hoc build (plain `./build.sh`) makes macOS ask again for microphone, system audio and calendar access.
- **Look, don't change.** Pressing Record captures the microphone and system audio. Changing the live engine, the speech language, the recording mode or the Voice coach switch changes the user's next real recording. Do these only when the user asked for them.
- **Open and read in one command.** The panel closes by itself when focus moves, so `open-panel.sh` opens it, captures it and prints its text in a single run. The text walk takes about 7 seconds.

## What the printed text looks like

Shortened; the real output also lists the meter labels, the meeting list and the recent recordings.

```
Ready
[PopUpButton] Live engine = Apple
[PopUpButton] Speech language = English
[MenuButton] Transcript only
[CheckBox] Voice coach = 1
[Button] Refresh meetings
[MenuButton] More
[Button] Open ~/Documents/Recordings in Finder
[Button] Open Preferences
```

The first line is the state (`Ready` when idle). The `MenuButton` after the language is the recording mode. `Voice coach = 1` means the coach is on. The unnamed first and last buttons are Record and Quit.

## Common mistakes

| Mistake | Fix |
|---|---|
| Clicking the menu bar item through System Events | Use `open-panel.sh`; it posts a real mouse click at the icon's centre |
| `entire contents of window 1` in AppleScript | Fails on the SwiftUI panel; `scripts/panel-text.js` walks `uiElements()` recursively |
| Icon position is negative | A menu bar manager hid it in its overflow; ask the user to reveal the icon |
| Checking the coach only through tests | After a live recording, read `coach.jsonl` in the recording's folder under `~/Documents/Recordings` and compare it with `coach-replay` (README, "Voice coach replay") |
