#!/usr/bin/env python3
"""Read `idb ui describe-all --json` on stdin, print one line per labelled element."""
import json
import sys

for line in sys.stdin:
    try:
        j = json.loads(line)
    except Exception:
        continue
    for i in (j if isinstance(j, list) else [j]):
        if i.get("AXLabel") or i.get("AXValue"):
            print(i.get("type"), "|", i.get("AXLabel"), "|", i.get("AXValue"), "|", i.get("frame"))
