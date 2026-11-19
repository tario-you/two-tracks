#!/bin/bash
# Builds WisprFree.app into ./build. SIGN_IDENTITY names a codesigning identity, which keeps macOS's microphone and
# Accessibility permissions across rebuilds; without it the app is signed ad hoc. --install copies it into /Applications
# and opens it.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f Vendor/sherpa/lib/libsherpa-onnx-c-api.dylib ] && [ -d Vendor/whisper.xcframework ] || scripts/fetch-engine.sh
swift build -c release
app="build/WisprFree.app"
rm -rf "${app:?}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp .build/release/WisprFree "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
[ -f build/AppIcon.icns ] || { swift scripts/icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns; }
cp build/AppIcon.icns "$app/Contents/Resources/"
cp -R Resources/Fonts "$app/Contents/Resources/"
cp Vendor/sherpa/lib/libsherpa-onnx-c-api.dylib Vendor/sherpa/lib/libonnxruntime.dylib "$app/Contents/Frameworks/"
ditto Vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework "$app/Contents/Frameworks/whisper.framework"
id="${SIGN_IDENTITY:--}"
for f in "$app"/Contents/Frameworks/*.dylib "$app/Contents/Frameworks/whisper.framework"; do
  codesign --force --options runtime --sign "$id" "$f"
done
codesign --force --options runtime --entitlements Resources/WisprFree.entitlements --sign "$id" "$app"
echo "built $app"
if [ "${1:-}" = "--install" ]; then
  osascript -e 'quit app id "app.wisprfree.WisprFree"' 2>/dev/null || true
  rm -rf "/Applications/WisprFree.app"
  ditto "$app" /Applications/WisprFree.app
  open /Applications/WisprFree.app
  echo "installed /Applications/WisprFree.app"
fi
