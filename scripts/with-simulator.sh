#!/usr/bin/env bash
# Runs a command with INTONATE_SIM_UDID set. An existing value is reused; otherwise a throwaway
# simulator is created for the command and deleted after it, so nothing else on the machine is touched.
set -euo pipefail

if [[ -n "${INTONATE_SIM_UDID:-}" ]]; then
    exec "$@"
fi

read -r device_type runtime < <(python3 "$(dirname "$0")/pick-simulator.py")
udid=$(xcrun simctl create "Intonate-$$" "$device_type" "$runtime")
trap 'xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true; xcrun simctl delete "$udid"' EXIT
echo "simulator $udid: $device_type on $runtime"

INTONATE_SIM_UDID="$udid" "$@"
