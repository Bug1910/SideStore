#!/bin/bash
# Simulator walkthrough for sidestore://refresh-all and auto refresh. Output -> sim-out/ (small files only).
# No Apple ID / password / secrets are used anywhere here.
set -u
OUT=sim-out; mkdir -p "$OUT"
APP=$(find build/dd/Build/Products -maxdepth 2 -name 'SideStore.app' | head -1)
echo "app: $APP" | tee "$OUT/notes.txt"
BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
echo "bundle id: $BID" | tee -a "$OUT/notes.txt"

# pick a device: iPhone 17 Pro on iOS 26, else any iPhone
UDID=$(xcrun simctl list devices available -j | python3 -c "
import json,sys
d=json.load(sys.stdin)['devices']
c=[]
for rt,ds in d.items():
    if 'iOS-26' in rt:
        for x in ds:
            if 'iPhone' in x['name']: c.append((x['name']!='iPhone 17 Pro',x['name'],x['udid']))
c.sort(); print(c[0][2] if c else '')")
echo "udid: $UDID" | tee -a "$OUT/notes.txt"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
sleep 5
xcrun simctl status_bar "$UDID" override --time 9:41 >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
echo "install rc=$?" | tee -a "$OUT/notes.txt"

shot() { xcrun simctl io "$UDID" screenshot --type=jpeg "$OUT/$1.jpg" 2>>"$OUT/notes.txt"; }
alive() { # prints pid of app or DEAD
  p=$(xcrun simctl spawn "$UDID" launchctl list | grep "$BID" | grep -v 'UIKitApplication:.*\.\(AltWidget\|SideBackup\)' | awk '{print $1}' | head -1)
  echo "${p:-NONE}"
}
note() { echo "[$(date +%T)] $*" | tee -a "$OUT/notes.txt"; }
dumplogs() { # $1 = label
  C=$(xcrun simctl get_app_container "$UDID" "$BID" data 2>/dev/null)
  for f in "$C"/Documents/ConsoleLogs/*; do [ -f "$f" ] && { echo "== $1 $(basename "$f")"; grep -a -i "AutoRefresh\|LaunchViewController\|MyApps\|crash\|fatal" "$f" | tail -40; } ; done >> "$OUT/app-log-$1.txt" 2>&1
  xcrun simctl spawn "$UDID" log show --last 3m --style compact --predicate 'eventMessage CONTAINS "AutoRefresh"' 2>&1 | tail -40 >> "$OUT/oslog-$1.txt"
  ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -i sidestore >> "$OUT/crash-$1.txt"
  true
}

# T0: first launch, NOT onboarded (default state)
xcrun simctl launch "$UDID" "$BID" | tee -a "$OUT/notes.txt"; sleep 12; shot 00-first-launch; note "T0 pid=$(alive)"; dumplogs t0
xcrun simctl terminate "$UDID" "$BID"; sleep 2

# T1: cold openurl while NOT onboarded (should not crash)
xcrun simctl openurl "$UDID" "sidestore://refresh-all"; sleep 12; shot 01-cold-url-not-onboarded; note "T1 pid=$(alive)"; dumplogs t1
xcrun simctl terminate "$UDID" "$BID"; sleep 2

# mark onboarding complete (same key the app uses)
xcrun simctl spawn "$UDID" defaults write "$BID" hasCompletedOnboarding -bool YES
xcrun simctl spawn "$UDID" defaults read "$BID" hasCompletedOnboarding | tee -a "$OUT/notes.txt"

# T2: launch onboarded -> main UI + sceneDidBecomeActive auto-check
xcrun simctl launch "$UDID" "$BID" | tee -a "$OUT/notes.txt"; sleep 15; shot 02-launch-onboarded; note "T2 pid=$(alive)"; dumplogs t2
xcrun simctl terminate "$UDID" "$BID"; sleep 2

# T3: COLD openurl (app not running)
xcrun simctl openurl "$UDID" "sidestore://refresh-all"; sleep 6; shot 03a-cold-url-6s; sleep 12; shot 03b-cold-url-18s; note "T3 pid=$(alive)"; dumplogs t3

# T4: WARM openurl (app running, going to background first via home)
xcrun simctl launch "$UDID" com.apple.springboard >/dev/null 2>&1 || true
sleep 3; shot 04a-after-home
xcrun simctl openurl "$UDID" "sidestore://refresh-all"; sleep 6; shot 04b-warm-url-6s; sleep 10; shot 04c-warm-url-16s; note "T4 pid=$(alive)"; dumplogs t4

# T5: notifications permission state (best effort)
xcrun simctl privacy "$UDID" grant notifications "$BID" >> "$OUT/notes.txt" 2>&1; note "privacy notifications rc=$?"
ls -la "$OUT" | tee -a "$OUT/notes.txt"
du -sh "$OUT"
