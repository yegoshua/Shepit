#!/usr/bin/env bash
# Builds Shepit and wraps the binary into build/Shepit.app.
set -euo pipefail

cd "$(dirname "$0")/.."
APP=build/Shepit.app

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Shepit" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# SwiftPM resource bundles of dependencies, if any.
find "$BIN" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

# A stable identity lets macOS keep Accessibility/Microphone permissions across rebuilds.
# Create a self-signed "Code Signing" certificate named "Shepit Dev" in Keychain Access,
# or point SIGN_IDENTITY at another one. Without it we fall back to ad-hoc signing.
IDENTITY="${SIGN_IDENTITY:-Shepit Dev}"
if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    echo "warning: signing identity '$IDENTITY' not found, using ad-hoc signature (permissions reset on every rebuild)"
    IDENTITY=-
fi
codesign --force --deep --sign "$IDENTITY" --identifier dev.yegor.shepit "$APP"

echo "Built $APP"
