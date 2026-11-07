"""Väljer en iPad-simulator ur `xcrun simctl list devices available -j` (på stdin) och skriver ut dess UDID.
Den nyaste iOS-versionen först, och helst en iPad Air, som liknar Edvins iPad mest."""

import json
import re
import sys


def version(runtime):
    numbers = re.findall(r"\d+", runtime.split("iOS")[-1])
    return tuple(int(n) for n in numbers)


devices = json.load(sys.stdin)["devices"]
candidates = []
for runtime, entries in devices.items():
    if "iOS" not in runtime:
        continue
    for device in entries:
        if device.get("isAvailable", True) and device["name"].startswith("iPad"):
            candidates.append((version(runtime), "Air" in device["name"], device["name"], device["udid"]))

if not candidates:
    sys.exit("Hittade ingen iPad-simulator")

candidates.sort(key=lambda c: (c[0], c[1]), reverse=True)
best = candidates[0]
print(f"{best[2]}, iOS {'.'.join(map(str, best[0]))}", file=sys.stderr)
print(best[3])
