#!/usr/bin/env bash
# Builds Shepit and installs it into /Applications, so launch at login and permissions
# are tied to a stable location. Use bundle.sh for day-to-day development builds.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh

TARGET=/Applications/Shepit.app
pkill -x Shepit 2>/dev/null && sleep 1 || true
rm -rf "$TARGET"
cp -R build/Shepit.app "$TARGET"
# Two registered copies with one bundle ID can leave notifications showing a stale, blank icon.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u build/Shepit.app 2>/dev/null || true
"$LSREGISTER" -f "$TARGET"
open "$TARGET"
echo "Installed $TARGET"
