#!/bin/zsh
# Builds the Meeting Notes app and puts it in /Applications. Run again after changing the app.
set -e
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:$PATH"
# Build inside a folder Spotlight does not index (build -> build.noindex), so the only
# Meeting Notes in Spotlight and the Apps list is the installed one.
if [[ ! -L build ]]; then
  rm -rf build
  mkdir -p build.noindex
  ln -s build.noindex build
fi
flutter build macos --release
SRC="build/macos/Build/Products/Release/Meeting Notes.app"
DEST="${1:-/Applications/Meeting Notes.app}"
osascript -e 'tell application id "local.meeting-notes.app" to quit' 2>/dev/null || true
rm -rf "$DEST"
ditto "$SRC" "$DEST"
# Sign the installed copy, never the one in the build folder: a build folder whose app was
# re-signed makes the next build fail once.
# A real identity (the same one as the recorder) lets macOS remember the app's permissions
# (Documents and Desktop folders) across rebuilds.
ID="$(../recorder/sign-identity.sh)"
if [[ -n "$ID" ]]; then
  codesign --force --deep -s "$ID" "$DEST" && echo "signed with ${ID:0:8}…"
else
  echo "no signing identity: left as built (macOS may ask for folder access again after each build)"
fi
echo "installed $DEST"
