#!/usr/bin/env python3
"""Read `simctl list devices -j` on stdin, print the UDID of an iOS 26 iPhone (prefer iPhone 17 Pro)."""
import json
import sys

d = json.load(sys.stdin)["devices"]
c = []
for rt, ds in d.items():
    if "iOS-26" in rt:
        for x in ds:
            if "iPhone" in x["name"]:
                c.append((x["name"] != "iPhone 17 Pro", x["name"], x["udid"]))
c.sort()
print(c[0][2] if c else "")
