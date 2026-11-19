#!/bin/bash
# Puts the two prebuilt speech engines in Vendor/ (kept out of git), each pinned to its release's checksum:
#   sherpa-onnx v1.13.8's macOS library (Parakeet, Parakeet v3, X-ASR) and its C header,
#   whisper.cpp b5454's xcframework (whisper base names the language), its macOS slice only.
# WISPRFREE_ENGINE_CACHE: a folder already holding those two downloads, used instead of the network.
set -euo pipefail
cd "$(dirname "$0")/.."
cache="${WISPRFREE_ENGINE_CACHE:-$HOME/.cache/wisprfree}"
mkdir -p "$cache" Vendor
get() {   # url file sha256
  local f="$cache/$2"
  if ! { [ -f "$f" ] && echo "$3  $f" | shasum -a 256 -c - >/dev/null 2>&1; }; then
    curl -fsSL --retry 3 -o "$f.part" "$1"
    echo "$3  $f.part" | shasum -a 256 -c - >/dev/null || { echo "fetch-engine: $2 failed its checksum" >&2; rm -f "$f.part"; exit 1; }
    mv "$f.part" "$f"
  fi
}
get https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-osx-arm64-shared-lib.tar.bz2 \
  sherpa-onnx-osx-arm64-shared-lib.tar.bz2 ae77050cdae565496059d96f5ab33d77b397a0864282a4e4a26e3b3b3effb948
get https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip \
  whisper-xcframework.zip e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b
rm -rf Vendor/sherpa Vendor/whisper.xcframework
mkdir -p Vendor/sherpa/lib Vendor/sherpa/include
t="$(mktemp -d)"
tar xjf "$cache/sherpa-onnx-osx-arm64-shared-lib.tar.bz2" -C "$t"
find "$t" \( -name 'libsherpa-onnx-c-api.dylib' -o -name 'libonnxruntime*.dylib' \) -exec cp {} Vendor/sherpa/lib/ \;
[ -f Vendor/sherpa/lib/libonnxruntime.dylib ] || cp Vendor/sherpa/lib/libonnxruntime.*.dylib Vendor/sherpa/lib/libonnxruntime.dylib
curl -fsSL --retry 3 -o Vendor/sherpa/include/c-api.h https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.8/sherpa-onnx/c-api/c-api.h
unzip -q "$cache/whisper-xcframework.zip" 'build-apple/whisper.xcframework/macos-arm64_x86_64/*' 'build-apple/whisper.xcframework/Info.plist' -x '*dSYM*' -d "$t"
mv "$t/build-apple/whisper.xcframework" Vendor/
mkdir -p Vendor/whisper.xcframework/macos-arm64_x86_64/dSYMs
rm -rf "$t"
/usr/bin/python3 - <<'PY'
import plistlib
p = 'Vendor/whisper.xcframework/Info.plist'
d = plistlib.load(open(p, 'rb'))
d['AvailableLibraries'] = [l for l in d['AvailableLibraries'] if l.get('SupportedPlatform') == 'macos' and not l.get('SupportedPlatformVariant')]
for l in d['AvailableLibraries']: l.pop('DebugSymbolsPath', None)
plistlib.dump(d, open(p, 'wb'))
PY
echo "fetch-engine: sherpa-onnx v1.13.8 and whisper.cpp b5454 in Vendor" >&2
