#!/bin/bash
# Builds "Two Tracks.app" into ./build. Set SIGN_IDENTITY to a codesigning identity to keep
# macOS privacy permissions across rebuilds; without it the app is signed ad hoc.
# Pass --install to copy it into /Applications and open it.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app="build/Two Tracks.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/TwoTracks "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$app/Contents/Resources/"
# Swift package resources (the tokenizer data WhisperKit ships with).
find .build/release -maxdepth 1 -name '*.bundle' -exec cp -R {} "$app/Contents/Resources/" \;
codesign --force --deep --options runtime --entitlements Resources/TwoTracks.entitlements --sign "${SIGN_IDENTITY:--}" "$app"
echo "built $app"
if [ "${1:-}" = "--install" ]; then
  osascript -e 'quit app "Two Tracks"' 2>/dev/null || true
  rm -rf "/Applications/Two Tracks.app"
  cp -R "$app" /Applications/
  open "/Applications/Two Tracks.app"
  echo "installed /Applications/Two Tracks.app"
fi
