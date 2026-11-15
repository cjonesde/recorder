#!/bin/bash
set -euo pipefail
count() { osascript -e 'tell application "System Events" to tell process "Recorder" to count windows'; }
[ "$(count)" = "0" ] && { echo "panel already closed"; exit 0; }
osascript -e 'tell application "System Events" to key code 53'
for _ in $(seq 1 8); do [ "$(count)" = "0" ] && { echo "panel closed"; exit 0; }; sleep 0.25; done
echo "panel still open" >&2
exit 1
