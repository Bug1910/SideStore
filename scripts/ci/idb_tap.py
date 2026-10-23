#!/usr/bin/env python3
"""Tap an on-screen element by (part of) its accessibility label using idb. usage: idb_tap.py UDID LABEL"""
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
for it in items:
    lab = (it.get("AXLabel") or "") + " " + (it.get("AXValue") or "")
    if label.lower() in lab.lower():
        f = it["frame"]
        x = f["x"] + f["width"] / 2
        y = f["y"] + f["height"] / 2
        subprocess.run(["idb", "ui", "tap", "--udid", udid, str(int(x)), str(int(y))])
        print("tapped", label, int(x), int(y))
        sys.exit(0)
print("NOT FOUND", label)
sys.exit(1)
