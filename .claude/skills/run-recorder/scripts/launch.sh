#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../../.." && pwd)"
binary="$repo/Recorder.app/Contents/MacOS/Recorder"
if pgrep -f "$binary" >/dev/null; then
    echo "Recorder from this repo is already running (pid $(pgrep -f "$binary")). It may be recording: ask the user to quit it, do not kill it." >&2
    exit 2
fi
identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
cd "$repo"
if [ -n "$identity" ]; then
    CODESIGN_IDENTITY="$identity" ./build.sh
else
    echo "No Apple Development identity: ad-hoc build, macOS will ask for permissions again." >&2
    ./build.sh
fi
open "$repo/Recorder.app"
for _ in $(seq 1 20); do
    pid="$(pgrep -f "$binary" || true)"
    [ -n "$pid" ] && break
    sleep 0.25
done
[ -n "${pid:-}" ] || { echo "Recorder did not start" >&2; exit 1; }
sleep 2
pgrep -f "$binary" >/dev/null || { echo "Recorder exited right after launch" >&2; exit 1; }
echo "running pid $pid, commit $(/usr/libexec/PlistBuddy -c 'Print :RecorderGitCommit' "$repo/Recorder.app/Contents/Info.plist" 2>/dev/null || echo unknown)"
