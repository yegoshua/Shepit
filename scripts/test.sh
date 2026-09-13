#!/usr/bin/env bash
# Runs Swift Testing suites with only the Command Line Tools installed (no Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."

DEV=/Library/Developer/CommandLineTools/Library/Developer
swift test \
    -Xswiftc -F"$DEV/Frameworks" \
    -Xlinker -F"$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/usr/lib" \
    "$@"
