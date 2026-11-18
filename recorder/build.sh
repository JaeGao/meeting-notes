#!/bin/zsh
# Builds "Meeting Recorder.app" into build.noindex/ beside this script. Needs Xcode's
# command line tools. The .noindex folder keeps this helper out of Spotlight and the Apps
# list: it has no window, and the app to open is Meeting Notes.
set -e
cd "$(dirname "$0")"
APP="build.noindex/Meeting Recorder.app"
ID="$(./sign-identity.sh)"
rm -rf "$APP" "Meeting Recorder.app"   # the second is where older builds went
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/meeting-recorder"
cp Info.plist "$APP/Contents/Info.plist"
cp ../app/app.icns "$APP/Contents/Resources/app.icns"
# Sign with a real identity when there is one, so macOS keeps the Screen Recording
# permission across rebuilds. An anonymous ("ad hoc") signature loses it every build.
# sign-identity.sh picks the same one every time; it must run before the old app is removed.
if [[ -n "$ID" ]]; then
  codesign --force -s "$ID" "$APP" && echo "signed with ${ID:0:8}…"
else
  codesign --force -s - "$APP" && echo "signed ad hoc: allow Screen Recording again after each build"
fi
echo "built $PWD/$APP"
