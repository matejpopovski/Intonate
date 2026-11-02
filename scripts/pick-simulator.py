#!/usr/bin/env python3
"""Print '<device type> <runtime>' for the newest iPhone on the newest available iOS runtime.

Asks simctl instead of naming a device, because GitHub's macos-latest image and a developer's Mac
have different simulators and both change over time.
"""

import json
import subprocess
import sys

MINIMUM = (17, 0)


def version(text: str) -> tuple[int, ...]:
    return tuple(int(part) for part in text.split("."))


listing = json.loads(
    subprocess.run(
        ["xcrun", "simctl", "list", "--json", "runtimes"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
)
runtimes = [
    runtime
    for runtime in listing["runtimes"]
    if runtime.get("platform") == "iOS"
    and runtime["isAvailable"]
    and version(runtime["version"]) >= MINIMUM
]
if not runtimes:
    sys.exit(f"no available iOS runtime at or above {MINIMUM}")
runtime = max(runtimes, key=lambda item: version(item["version"]))
iphones = [
    device
    for device in runtime["supportedDeviceTypes"]
    if device["productFamily"] == "iPhone"
]
if not iphones:
    sys.exit(f"runtime {runtime['identifier']} supports no iPhone")
# simctl lists device types newest first.
print(iphones[0]["identifier"], runtime["identifier"])
