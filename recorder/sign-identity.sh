#!/bin/zsh
# Prints the code-signing identity both apps are signed with, or nothing when there is none.
# macOS lists identities in a changing order, and its permissions (Screen Recording,
# folder access) follow the certificate's name. So: keep the name the recorder is already
# signed with; failing that, the first Apple Development name in alphabetical order.
# Set SIGN_ID to choose yourself.
if [[ -n "$SIGN_ID" ]]; then echo "$SIGN_ID"; exit 0; fi
HERE="$(cd "$(dirname "$0")" && pwd)"
ALL="$(security find-identity -v -p codesigning | grep '"Apple Development' | sort -t'"' -k2,2 -k1,1)"
[[ -z "$ALL" ]] && exit 0
for APP in "$HERE/build.noindex/Meeting Recorder.app" "/Applications/Meeting Notes.app"; do
  NAME="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Apple Development.*\)$/\1/p' | head -1)"
  if [[ -n "$NAME" ]]; then
    HIT="$(echo "$ALL" | grep -F "\"$NAME\"" | awk '{print $2; exit}')"
    if [[ -n "$HIT" ]]; then echo "$HIT"; exit 0; fi
  fi
done
echo "$ALL" | awk '{print $2; exit}'
