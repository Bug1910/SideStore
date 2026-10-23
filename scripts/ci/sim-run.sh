#!/bin/bash
# Simulator walkthrough for sidestore://refresh-all and auto refresh. Output -> sim-out/ (small files only).
# Live view: changed screens (5 s ticks, downscaled) are pushed to orphan branch sim-live (needs GH_TOKEN, failures ignored).
# No Apple ID / password / secrets are used anywhere here.
set -u
OUT=sim-out; mkdir -p "$OUT"
RUN_ID=${GITHUB_RUN_ID:-local}
Q=$PWD/live-queue; LIVE=$PWD/live-repo; TMPD=$(mktemp -d); mkdir -p "$Q"
APP=$(find build/dd/Build/Products -maxdepth 2 -name 'SideStore.app' | head -1)
echo "app: $APP" | tee "$OUT/notes.txt"
BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
echo "bundle id: $BID" | tee -a "$OUT/notes.txt"

# ---- live view setup (best effort) ----
LIVE_OK=0
if [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  mkdir -p "$LIVE" && ( cd "$LIVE" && git init -q && git config user.name sim-bot && git config user.email sim-bot@users.noreply.github.com \
    && git remote add origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" \
    && { if git fetch -q --depth=1 origin sim-live 2>/dev/null; then git checkout -q -B sim-live FETCH_HEAD; else git checkout -q --orphan sim-live; fi; } ) >/dev/null 2>&1 && LIVE_OK=1
fi
echo "live view: $LIVE_OK" | tee -a "$OUT/notes.txt"
push_live() {
  [ "$LIVE_OK" = 1 ] || return 0
  ls "$Q"/*.jpg "$Q"/*.txt >/dev/null 2>&1 || return 0
  mkdir -p "$LIVE/$RUN_ID"
  names=$(cd "$Q" && ls | head -20 | tr '\n' ' ')
  for f in $(cd "$Q" && ls | head -20); do mv "$Q/$f" "$LIVE/$RUN_ID/$f" 2>/dev/null; done
  ( cd "$LIVE" && git add -A >/dev/null 2>&1 && git commit -q -m "$names" >/dev/null 2>&1 \
    && { git push -q origin sim-live >/dev/null 2>&1 || { git pull -q --rebase origin sim-live >/dev/null 2>&1; git push -q origin sim-live >/dev/null 2>&1; }; } ) || true
}

# ---- device ----
UDID=$(xcrun simctl list devices available -j | python3 scripts/ci/pick_device.py)
echo "udid: $UDID" | tee -a "$OUT/notes.txt"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
sleep 5
xcrun simctl status_bar "$UDID" override --time 9:41 >/dev/null 2>&1 || true
(brew install facebook/fb/idb-companion >/dev/null 2>&1 && pip3 install --break-system-packages fb-idb >/dev/null 2>&1) ; echo "idb: $(command -v idb || echo missing)" | tee -a "$OUT/notes.txt"
idb_companion --udid "$UDID" >/dev/null 2>&1 &
sleep 5; idb connect "$UDID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
echo "install rc=$?" | tee -a "$OUT/notes.txt"

hms() { date +%H%M%S; }
applog() { C=$(xcrun simctl get_app_container "$UDID" "$BID" data 2>/dev/null); ls -t "$C"/Documents/ConsoleLogs/* 2>/dev/null | head -1; }
step() { echo "$1" > "$OUT/.step"; date +%s > "$OUT/.stepstart"; echo "[$(date +%T)] STEP $1" >> "$OUT/notes.txt"; }
shot() { # step screenshot: artifact + live
  xcrun simctl io "$UDID" screenshot --type=jpeg "$OUT/$1.jpg" >/dev/null 2>&1; sips -Z 800 "$OUT/$1.jpg" >/dev/null 2>&1
  cp "$OUT/$1.jpg" "$Q/.t.jpg" 2>/dev/null && mv "$Q/.t.jpg" "$Q/$(hms)-$1.jpg"
}
alive() {
  p=$(xcrun simctl spawn "$UDID" launchctl list | grep "$BID" | grep -v 'UIKitApplication:.*\.\(AltWidget\|SideBackup\)' | awk '{print $1}' | head -1)
  echo "${p:-NONE}"
}
tapl() { python3 scripts/ci/idb_tap.py "$UDID" "$1" | tee -a "$OUT/notes.txt"; }
dumpui() { idb ui describe-all --udid "$UDID" --json 2>&1 | python3 scripts/ci/idb_dump.py > "$OUT/ui-$1.txt" 2>&1; }
FAILS=0
CRASH_SEEN=""
collect_crash() { # copies new .ips crash reports + exception lines from simulator log (artifact + live)
  { grep -a -i -E -B1 -A8 "exception|reason:|terminating" "$(applog)" 2>/dev/null | cut -c1-400 | head -80; } > "$OUT/crash-applog.txt"; cp "$OUT/crash-applog.txt" "$Q/$(hms)-CRASH-applog.txt"
  ts=$(hms)
  for r in "$HOME"/Library/Logs/DiagnosticReports/*SideStore*.ips; do [ -f "$r" ] || continue; b=$(basename "$r"); case "$CRASH_SEEN" in *"$b"*) continue;; esac; CRASH_SEEN="$CRASH_SEEN $b"; cp "$r" "$OUT/crash-$b"; cp "$r" "$Q/$ts-CRASH-$b.txt"; done
  { echo "== log show (SideStore, last 3m): exception lines"; xcrun simctl spawn "$UDID" log show --last 3m --style compact --predicate "process == \"SideStore\"" 2>&1 | grep -a -i "Terminating app|uncaught exception|reason:|Last Exception|SIGABRT|CoreData" | cut -c1-600 | head -40; } > "$OUT/crash-log-$ts.txt"; cp "$OUT/crash-log-$ts.txt" "$Q/$ts-CRASH-log.txt"
}
fail() { echo "FAIL: $*" | tee -a "$OUT/notes.txt"; FAILS=$((FAILS+1)); }
tap_open() { for n in 1 2 3; do tapl Open; sleep 2; if ! idb ui describe-all --udid "$UDID" --json 2>/dev/null | grep -q "Open in"; then return 0; fi; done; fail "open-url dialog still present after 3 taps"; }
chk() { p=$(alive); echo "[$(date +%T)] $1 pid=$p" | tee -a "$OUT/notes.txt"; if [ "$p" = NONE ]; then fail "$1 app not running (pid=NONE)"; collect_crash; fi; true; }
note() { echo "[$(date +%T)] $*" | tee -a "$OUT/notes.txt"; }
dumplogs() { # $1 = label
  C=$(xcrun simctl get_app_container "$UDID" "$BID" data 2>/dev/null)
  for f in "$C"/Documents/ConsoleLogs/*; do [ -f "$f" ] && { echo "== $1 $(basename "$f")"; grep -a -i "AutoRefresh\|LaunchViewController\|MyApps\|crash\|fatal" "$f" | grep -v "^objc" | tail -40; } ; done >> "$OUT/app-log-$1.txt" 2>&1
  echo "AutoRefresh lines in latest log: $(grep -a -c 'AutoRefresh' "$(applog)" 2>/dev/null)" | tee -a "$OUT/notes.txt"
  ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -i sidestore >> "$OUT/crash-$1.txt"
  true
}

# ---- background ticker: 5 s screenshots, md5 of downscaled frame, push only changes, STALL marker after 10 s unchanged ----
touch "$OUT/.run"; echo idle > "$OUT/.step"; date +%s > "$OUT/.stepstart"
T0=$(date +%s)
ticker() {
  i=0; last=""; lastchange=$(date +%s); stepseen=""; flagged=0
  while [ -f "$OUT/.run" ]; do
    f="$TMPD/tick.jpg"
    if xcrun simctl io "$UDID" screenshot --type=jpeg "$f" >/dev/null 2>&1; then
      sips -Z 800 "$f" >/dev/null 2>&1
      now=$(date +%s); h=$(md5 -q "$f"); step=$(cat "$OUT/.step" 2>/dev/null)
      if [ "$step" != "$stepseen" ]; then stepseen=$step; flagged=0; lastchange=$now; fi
      if [ "$h" != "$last" ]; then
        last=$h; lastchange=$now; cp "$f" "$Q/.t1.jpg" && mv "$Q/.t1.jpg" "$Q/$(hms)-tick.jpg"
      elif [ $((now-lastchange)) -gt 10 ] && [ "$flagged" = 0 ] && [ "$step" != idle ]; then
        flagged=1; ts=$(hms); collect_crash
        cp "$f" "$Q/.t2.jpg" && mv "$Q/.t2.jpg" "$Q/$ts-STALL-$step.jpg"
        { echo "STALL: screen unchanged >10 s during step '$step'"; echo "pid: $(alive)"; grep -a -i -E -B1 -A8 "exception|reason:|terminating" "$(applog)" 2>/dev/null | cut -c1-400 | head -80; echo "---- tail"; tail -n 40 "$(applog)" 2>/dev/null | cut -c1-300; } > "$Q/.t3.txt"; mv "$Q/.t3.txt" "$Q/$ts-STALL-$step.txt"
      fi
      if [ $((i%6)) = 0 ]; then cp "$f" "$OUT/tick-$(printf %04d $((now-T0))).jpg"; fi
    fi
    push_live; i=$((i+1)); sleep 5
  done
}
ticker &
TICKER=$!

# T0: first launch, NOT onboarded (default state)
step t0-first-launch
xcrun simctl launch "$UDID" "$BID" | tee -a "$OUT/notes.txt"; sleep 12; shot 00-first-launch; tapl Allow; sleep 2; shot 00b-after-allow; chk "T0"; dumplogs t0
xcrun simctl terminate "$UDID" "$BID"; sleep 2

# T1: cold openurl while NOT onboarded (should not crash)
step t1-cold-url-not-onboarded
xcrun simctl openurl "$UDID" "sidestore://refresh-all"; sleep 4; shot 01a-dialog; tap_open; sleep 10; shot 01-cold-url-not-onboarded; chk "T1"; dumpui t1; dumplogs t1
xcrun simctl terminate "$UDID" "$BID"; sleep 2

# mark onboarding complete (same key the app uses)
xcrun simctl spawn "$UDID" defaults write "$BID" hasCompletedOnboarding -bool YES
xcrun simctl spawn "$UDID" defaults read "$BID" hasCompletedOnboarding | tee -a "$OUT/notes.txt"

# T2: launch onboarded -> main UI + sceneDidBecomeActive auto-check
step t2-launch-onboarded
xcrun simctl launch "$UDID" "$BID" | tee -a "$OUT/notes.txt"; sleep 15; shot 02-launch-onboarded; chk "T2"; dumpui t2; dumplogs t2
xcrun simctl terminate "$UDID" "$BID"; sleep 2

# T3: COLD openurl (app not running)
step t3-cold-url
xcrun simctl openurl "$UDID" "sidestore://refresh-all"; sleep 4; tap_open; sleep 4; shot 03a-cold-url-8s; sleep 12; shot 03b-cold-url-20s; dumpui t3; chk "T3"; dumplogs t3

# T4: WARM openurl (app running, then sent to background via home)
step t4-warm-url
idb ui button --udid "$UDID" HOME >/dev/null 2>&1 || xcrun simctl launch "$UDID" com.apple.springboard >/dev/null 2>&1 || true
sleep 3; shot 04a-after-home; note "T4 before-url pid=$(alive)"
xcrun simctl openurl "$UDID" "sidestore://refresh-all"; sleep 4; tap_open; sleep 4; shot 04b-warm-url-8s; sleep 10; shot 04c-warm-url-16s; chk "T4"; dumpui t4; dumplogs t4

# T5: settings page
step t5-settings
xcrun simctl launch "$UDID" "$BID" >/dev/null; sleep 8
tapl Settings; sleep 3; shot 05a-settings; dumpui settings
tapl Advanced; sleep 2; shot 05b-advanced; dumpui advanced
tapl "User Customizations" || tapl Customization; sleep 2; shot 05c-customizations; dumpui custom
for i in 1 2 3 4 5 6; do idb ui swipe --udid "$UDID" 200 700 200 250 >/dev/null 2>&1; sleep 1; done; shot 05d-scrolled; dumpui scrolled
chk "T5"; dumplogs t5

step idle; collect_crash
rm -f "$OUT/.run"; wait "$TICKER" 2>/dev/null
push_live
note "notification permission: tapped Allow in onboarding (simctl privacy has no notifications service)"
rm -f "$OUT/.step" "$OUT/.stepstart"
ls -la "$OUT" | tee -a "$OUT/notes.txt"
du -sh "$OUT"

# hard verdict: never green when the URL never reached the app
TOTAL_AR=$(cat "$OUT"/app-log-t*.txt 2>/dev/null | grep -a -c '\[AutoRefresh\]')
echo "total [AutoRefresh] log lines: $TOTAL_AR" | tee -a "$OUT/notes.txt"
[ "$TOTAL_AR" -gt 0 ] || fail "no [AutoRefresh] line in any app log"
echo "FAILS=$FAILS" | tee -a "$OUT/notes.txt"
[ "$FAILS" = 0 ] || exit 1
