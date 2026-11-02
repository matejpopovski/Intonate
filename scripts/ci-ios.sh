#!/usr/bin/env bash
# The simulator half of CI: the app's unit tests on the newest available iPhone.
# GitHub's macOS runners are virtual machines without a dependable GPU or audio device, so when CI is
# set, the tests that read pixels back from Metal or start AVAudioEngine are left out. They run
# everywhere else, including a local run of this script.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${INTONATE_SIM_UDID:-}" ]]; then
    exec scripts/with-simulator.sh "$0"
fi

skip=()
if [[ -n "${CI:-}" ]]; then
    skip+=("-skip-testing:IntonateTests/WaterfallRendererTests")
    skip+=("-skip-testing:IntonateTests/AudioInputTests/testReferenceToneThroughAVAudioEngineHasThePitchRequested")
fi

xcodebuild test \
    -quiet \
    -project Intonate.xcodeproj \
    -scheme Intonate \
    -derivedDataPath build/DerivedData \
    -destination "platform=iOS Simulator,id=$INTONATE_SIM_UDID" \
    -parallel-testing-enabled NO \
    -only-testing:IntonateTests \
    CODE_SIGNING_ALLOWED=NO \
    ${skip[@]+"${skip[@]}"}
