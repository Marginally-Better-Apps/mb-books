"""Prints an xcodebuild destination for the newest available iPhone simulator."""
import json
import re
import subprocess
import sys


def version(runtime):
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    return tuple(int(part) for part in match.groups()) if match else (0, 0)


def pick(devices):
    candidates = [
        (version(runtime), device["name"], device["udid"])
        for runtime, entries in devices.items() if "iOS" in runtime
        for device in entries
        if device.get("isAvailable") and device["name"].startswith("iPhone")
    ]
    if not candidates:
        raise SystemExit("No available iPhone simulator")
    # Newest runtime first, then prefer the standard "iPhone NN" models for stable layouts.
    candidates.sort(key=lambda item: (item[0], bool(re.fullmatch(r"iPhone \d+", item[1]))), reverse=True)
    return f"platform=iOS Simulator,id={candidates[0][2]}"


if __name__ == "__main__":
    listing = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
    print(pick(listing["devices"]))
    sys.exit(0)
