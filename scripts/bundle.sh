#!/usr/bin/env bash
# Builds VoiceType and wraps the binary into build/VoiceType.app.
set -euo pipefail

cd "$(dirname "$0")/.."
APP=build/VoiceType.app

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/VoiceType" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# SwiftPM resource bundles of dependencies, if any.
find "$BIN" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

# Ad-hoc signature: macOS forgets granted permissions after each rebuild.
# Set SIGN_IDENTITY to a (self-signed) certificate name to keep them.
codesign --force --deep --sign "${SIGN_IDENTITY:--}" --identifier dev.yegor.voicetype "$APP"

echo "Built $APP"
