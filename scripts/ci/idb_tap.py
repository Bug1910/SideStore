#!/usr/bin/env python3
"""Tap an on-screen element by accessibility label using idb. usage: idb_tap.py UDID LABEL
Preference: exact Button label, Button containing label, any element containing label."""
import json
import subprocess
import sys

udid, label = sys.argv[1], sys.argv[2]
out = subprocess.run(["idb", "ui", "describe-all", "--udid", udid, "--json"], capture_output=True, text=True).stdout
items = []
for line in out.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        j = json.loads(line)
    except Exception:
        continue
    items.extend(j if isinstance(j, list) else [j])


def lab(it):
    return (it.get("AXLabel") or "").strip()


want = label.lower()
cands = [
    [it for it in items if it.get("type") == "Button" and lab(it).lower() == want],
    [it for it in items if it.get("type") == "Button" and want in lab(it).lower()],
    [it for it in items if want in (lab(it) + " " + (it.get("AXValue") or "")).lower()],
]
for group in cands:
    if group:
        f = group[0]["frame"]
        x = f["x"] + f["width"] / 2
        y = f["y"] + f["height"] / 2
        subprocess.run(["idb", "ui", "tap", "--udid", udid, str(int(x)), str(int(y))])
        print("tapped", group[0].get("type"), label, int(x), int(y))
        sys.exit(0)
print("NOT FOUND", label)
sys.exit(1)
