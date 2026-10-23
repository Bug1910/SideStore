#!/usr/bin/env python3
"""Tap tab number N (0-based, of COUNT tabs) using the real 'Tab Bar' frame from idb describe-all.
usage: idb_tabtap.py UDID INDEX COUNT"""
import json
import subprocess
import sys

udid, index, count = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
out = subprocess.run(["idb", "ui", "describe-all", "--udid", udid, "--json"], capture_output=True, text=True).stdout
items = []
for line in out.splitlines():
    try:
        j = json.loads(line.strip())
    except Exception:
        continue
    items.extend(j if isinstance(j, list) else [j])
bars = [i for i in items if (i.get("AXLabel") or "") == "Tab Bar"]
if not bars:
    print("NOT FOUND Tab Bar")
    sys.exit(1)
f = bars[0]["frame"]
x = f["x"] + f["width"] * (index + 0.5) / count
y = f["y"] + f["height"] / 2
subprocess.run(["idb", "ui", "tap", "--udid", udid, str(int(x)), str(int(y))])
print("tapped tab", index, "of", count, "at", int(x), int(y))
