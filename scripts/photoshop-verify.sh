#!/bin/zsh
# Opens a PSD in the running Adobe Photoshop 2026, records what Photoshop sees and exports it as PNG, via
# scripts/photoshop-verify.jsx: <out-dir>/<name>.verify.json, <name>.opened.png and <name>.retypeset.png.
#
#   scripts/photoshop-verify.sh [--raw] <file.psd> <out-dir>
#
# Photoshop opens the file itself, so give it a copy. The harness closes only the document it opened, without
# saving, and puts back the active document and the preferences it changed. The report holds hashes of layer
# names, text and the file's name; --raw also stores the strings themselves. See docs/psd-export.md.
#
# While Photoshop runs the harness, a watchdog looks for its dialogs every 2 s through System Events (it needs
# Accessibility access). An alert the file raises is cancelled, written to <out-dir>/alerts.txt and fails the run
# (exit 1), so Photoshop is never left waiting on it. A dialog already open before the run stops it (exit 3).
set -euo pipefail

usage() {
  print -u2 "usage: photoshop-verify.sh [--raw] <file.psd> <out-dir>"
  exit 2
}

MODE=hashed
if [[ ${1-} == --raw ]]; then
  MODE=raw
  shift
fi
(( $# == 2 )) || usage
[[ $1 != -* ]] || usage
INPUT=${1:A}
OUT_DIR=${2:A}
JSX=${0:A:h}/photoshop-verify.jsx
if [[ ! -f $INPUT ]]; then
  print -u2 "photoshop-verify.sh: no such file: $INPUT"
  exit 2
fi
mkdir -p "$OUT_DIR"
ALERTS=$OUT_DIR/alerts.txt
rm -f "$ALERTS"

# Photoshop's open dialogs, the windows whose accessibility subrole is AXDialog: for each, a "dialog" line and its
# static texts. With "cancel", each one's Cancel button is pressed, or the only button of a one-button alert; a
# dialog with neither is left open and reported. Nothing outside those dialogs is touched.
dialogs() {
  osascript \
    -e 'on run argv' \
    -e 'set report to ""' \
    -e 'tell application "System Events"' \
    -e 'if not (exists process "Adobe Photoshop 2026") then return ""' \
    -e 'tell process "Adobe Photoshop 2026"' \
    -e 'repeat with found in (every window whose subrole is "AXDialog")' \
    -e 'set report to report & "dialog" & linefeed' \
    -e 'set texts to {}' \
    -e 'try' \
    -e 'set texts to value of every static text of found' \
    -e 'end try' \
    -e 'repeat with line_ in texts' \
    -e 'if contents of line_ is not missing value then set report to report & (contents of line_ as text) & linefeed' \
    -e 'end repeat' \
    -e 'if item 1 of argv is "cancel" then' \
    -e 'if exists button "Cancel" of found then' \
    -e 'click button "Cancel" of found' \
    -e 'set report to report & "[pressed Cancel]" & linefeed' \
    -e 'else if (count of buttons of found) is 1 then' \
    -e 'set label to name of button 1 of found' \
    -e 'click button 1 of found' \
    -e 'set report to report & "[pressed " & label & "]" & linefeed' \
    -e 'else' \
    -e 'set report to report & "[left open: no Cancel button]" & linefeed' \
    -e 'end if' \
    -e 'end if' \
    -e 'end repeat' \
    -e 'end tell' \
    -e 'end tell' \
    -e 'return report' \
    -e 'end run' \
    "$1"
}

# Photoshop quotes layer and file names in its alerts; unless --raw, each quoted name becomes # and the first 12
# hex digits of its SHA-256, as in the report.
scrub() {
  setopt localoptions extendedglob multibyte
  local LC_ALL=en_US.UTF-8
  local text=$1 name hash
  if [[ $MODE == raw ]]; then
    print -r -- "$text"
    return
  fi
  while [[ $text == (#b)(*)“([^“”]#)”(*) ]]; do
    name=$match[2]
    hash=$(print -rn -- "$name" | shasum -a 256)
    text="$match[1]#${hash[1,12]}$match[3]"
  done
  print -r -- "$text"
}

if ! open=$(dialogs list 2>&1); then
  print -u2 -r -- "photoshop-verify.sh: can't watch Photoshop for alerts through System Events: $open"
  exit 3
fi
if [[ -n $open ]]; then
  print -u2 "photoshop-verify.sh: Photoshop already has a dialog open, so the run was not started:"
  print -u2 -r -- "$(scrub "$open")"
  exit 3
fi

output=$(mktemp -t photoshop-verify)
errors=$(mktemp -t photoshop-verify)
trap 'rm -f "$output" "$errors"' EXIT
osascript \
  -e 'on run argv' \
  -e 'with timeout of 900 seconds' \
  -e 'tell application "Adobe Photoshop 2026" to do javascript file (item 1 of argv) with arguments {item 2 of argv, item 3 of argv, item 4 of argv}' \
  -e 'end timeout' \
  -e 'end run' \
  "$JSX" "$INPUT" "$OUT_DIR" "$MODE" >"$output" 2>"$errors" &
harness=$!
alerts=""
stuck=false
while kill -0 $harness 2>/dev/null; do
  sleep 2
  kill -0 $harness 2>/dev/null || break
  found=$(dialogs cancel 2>/dev/null) || found=""
  [[ -n $found ]] || continue
  found=$(scrub "$found")
  print -r -- "$found" >>"$ALERTS"
  alerts+=$found$'\n'
  if [[ $found == *'[left open'* ]]; then
    # Photoshop waits on a dialog the watchdog can't dismiss: stop waiting for the harness.
    stuck=true
    kill $harness 2>/dev/null || true
    break
  fi
done
code=0
wait $harness || code=$?
result=$(<"$output")
[[ -z $result ]] || print -r -- "$result"
if [[ -n $alerts ]]; then
  print -u2 "photoshop-verify.sh: Photoshop raised a dialog during the run (also in $ALERTS):"
  print -u2 -rn -- "$alerts"
  if $stuck; then print -u2 "photoshop-verify.sh: that dialog is still open in Photoshop and needs a person to close it."; fi
  exit 1
fi
if (( code != 0 )); then
  cat "$errors" >&2
  exit 1
fi
[[ $result == ok* ]]
