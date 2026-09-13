#!/usr/bin/env bash
# Runs Swift Testing suites with only the Command Line Tools installed (no Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."

DEV=/Library/Developer/CommandLineTools/Library/Developer
# The Testing+Foundation cross-import overlay isn't shipped with the Command Line Tools,
# so tests that import Foundation only compile with overlays disabled.
swift test \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xswiftc -F"$DEV/Frameworks" \
    -Xlinker -F"$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/usr/lib" \
    "$@"
