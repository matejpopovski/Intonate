#!/usr/bin/env bash
# Writes results/simulator_timing.json from a Release build of the real app on the demo voice.
# Everything in that file is simulator timing on the host, and says nothing about a phone.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${INTONATE_SIM_UDID:-}" ]]; then
    exec scripts/with-simulator.sh "$0" "$@"
fi

seconds="${1:-30}"
bundle=com.matejpopovski.Intonate

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
xcrun simctl install "$INTONATE_SIM_UDID" build/DerivedData/Build/Products/Release-iphonesimulator/Intonate.app

host="$(sysctl -n machdep.cpu.brand_string), $(($(sysctl -n hw.memsize) / 1073741824)) GB"
SIMCTL_CHILD_INTONATE_HOST="$host" xcrun simctl launch --terminate-running-process \
    "$INTONATE_SIM_UDID" "$bundle" --measure "$seconds" >/dev/null

container=$(xcrun simctl get_app_container "$INTONATE_SIM_UDID" "$bundle" data)
report="$container/Documents/simulator_timing.json"
rm -f "$report"
sleep "$seconds"
for _ in $(seq 1 60); do
    [[ -s "$report" ]] && break
    sleep 1
done
cp "$report" results/simulator_timing.json
xcrun simctl terminate "$INTONATE_SIM_UDID" "$bundle" || true
echo "wrote results/simulator_timing.json"
