#!/usr/bin/env bash
# Takes the README images from the running app on the demo voice, with `simctl io`.
# Nothing here is composed: each image is what the simulator's screen held at that moment.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${INTONATE_SIM_UDID:-}" ]]; then
    exec scripts/with-simulator.sh "$0" "$@"
fi

bundle=com.matejpopovski.Intonate
shots=docs/screenshots
mkdir -p "$shots" build/capture

xcodebuild build \
    -quiet \
    -project Intonate.xcodeproj \
    -scheme Intonate \
    -configuration Release \
    -derivedDataPath build/DerivedData \
    -destination "platform=iOS Simulator,id=$INTONATE_SIM_UDID" \
    CODE_SIGNING_ALLOWED=NO

xcrun simctl boot "$INTONATE_SIM_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$INTONATE_SIM_UDID" -b >/dev/null
xcrun simctl status_bar "$INTONATE_SIM_UDID" override --time "9:41" --batteryState charged --batteryLevel 100
xcrun simctl install "$INTONATE_SIM_UDID" build/DerivedData/Build/Products/Release-iphonesimulator/Intonate.app

launch() {
    xcrun simctl launch --terminate-running-process "$INTONATE_SIM_UDID" "$bundle" --demo --voice tenor "$@" >/dev/null
}
shot() {
    xcrun simctl io "$INTONATE_SIM_UDID" screenshot --type=png "$shots/$1.png" >/dev/null 2>&1
    echo "captured $1"
}

# A run to the end, so that the notices and the best score on the programme come from a real run.
launch --exercise arpeggio
sleep 12
shot stage
sleep 11
shot notices

launch
sleep 3
shot programme

launch --exercise free
sleep 7.6
shot free-stage

# Video for the README animation; scripts/make-demo-gif.swift turns it into a GIF.
launch --exercise five-note-scale
sleep 6.5
xcrun simctl io "$INTONATE_SIM_UDID" recordVideo --codec=h264 --force build/capture/stage.mov >/dev/null 2>&1 &
recorder=$!
sleep 8
kill -INT "$recorder"
wait "$recorder" || true

swift scripts/make-demo-gif.swift build/capture/stage.mov "$shots/stage.gif"
xcrun simctl status_bar "$INTONATE_SIM_UDID" clear
xcrun simctl terminate "$INTONATE_SIM_UDID" "$bundle" || true
