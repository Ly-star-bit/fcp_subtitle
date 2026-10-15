#!/bin/zsh
# Run the unit tests (swift-testing). With only the Command Line Tools
# installed (no Xcode), SwiftPM doesn't find swift-testing on its own, so
# point the compiler and the test runner at the CLT copy.
set -euo pipefail
cd "$(dirname "$0")/.."

CLT_DEV=/Library/Developer/CommandLineTools/Library/Developer
args=()
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools && -d "$CLT_DEV/Frameworks/Testing.framework" ]]; then
    args=(
        -Xswiftc -F"$CLT_DEV/Frameworks"
        -Xlinker -rpath -Xlinker "$CLT_DEV/Frameworks"
        -Xlinker -rpath -Xlinker "$CLT_DEV/usr/lib"
    )
fi
swift test "${args[@]}" "$@"
