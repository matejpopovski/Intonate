#!/usr/bin/env bash
# Runs the simulator tests: everything by default, or the targets named as arguments.
#   scripts/test-ios.sh
#   scripts/test-ios.sh IntonateTests/WaterfallRendererTests
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${INTONATE_SIM_UDID:-}" ]]; then
    exec scripts/with-simulator.sh "$0" "$@"
fi

selection=()
for target in "$@"; do
    selection+=("-only-testing:$target")
done

xcodebuild test \
    -quiet \
    -project Intonate.xcodeproj \
    -scheme Intonate \
    -derivedDataPath build/DerivedData \
    -destination "platform=iOS Simulator,id=$INTONATE_SIM_UDID" \
    -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO \
    ${selection[@]+"${selection[@]}"}
