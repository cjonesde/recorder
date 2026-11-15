#!/bin/bash
set -euo pipefail
out="${1:-${TMPDIR:-/tmp}/recorder-panel.png}"
here="$(cd "$(dirname "$0")" && pwd)"
clicker="${TMPDIR:-/tmp}/recorder-menubar-click"
[ -x "$clicker" ] || swiftc -O -o "$clicker" "$here/click.swift"
windows() { osascript -e 'tell application "System Events" to tell process "Recorder" to count windows'; }
if [ "$(windows)" = "0" ]; then
    read -r x y w h < <(osascript -e 'tell application "System Events" to tell process "Recorder"
        set p to position of menu bar item 1 of menu bar 2
        set s to size of menu bar item 1 of menu bar 2
        return (item 1 of p as text) & " " & (item 2 of p as text) & " " & (item 1 of s as text) & " " & (item 2 of s as text)
    end tell')
    if [ "$x" -lt 0 ]; then
        echo "Recorder's menu bar icon is hidden (menu bar manager overflow); ask the user to reveal it" >&2
        exit 1
    fi
    "$clicker" "$((x + w / 2))" "$((y + h / 2))"
    for _ in $(seq 1 12); do [ "$(windows)" != "0" ] && break; sleep 0.25; done
fi
[ "$(windows)" != "0" ] || { echo "panel did not open" >&2; exit 1; }
sleep 0.5
read -r px py pw ph < <(osascript -e 'tell application "System Events" to tell process "Recorder"
    set p to position of window 1
    set s to size of window 1
    return (item 1 of p as text) & " " & (item 2 of p as text) & " " & (item 1 of s as text) & " " & (item 2 of s as text)
end tell')
screencapture -x -R"$px,$py,$pw,$ph" "$out"
echo "screenshot $out"
osascript -l JavaScript "$here/panel-text.js"
