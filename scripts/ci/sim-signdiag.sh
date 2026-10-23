#!/bin/bash
# Print how the simulator build is signed / which App Group entitlements it carries, then re-sign ad-hoc with the Xcode-generated .xcent.
APP=$(find build/dd/Build/Products -maxdepth 2 -name 'SideStore.app' | head -1)
echo "== app: $APP"
echo "== codesign -d (before)"; codesign -d --entitlements - "$APP" 2>&1 | head -40
echo "== xcent files"; find build/dd -name '*.xcent' | head
XCENT=$(find build/dd -name 'SideStore.app.xcent' | head -1)
echo "== xcent content ($XCENT)"; cat "$XCENT" 2>&1 | head -30
if [ -n "$XCENT" ]; then
  codesign --force --sign - --timestamp=none --entitlements "$XCENT" "$APP" 2>&1 | tail -3
  echo "== codesign -d (after)"; codesign -d --entitlements - "$APP" 2>&1 | head -40
fi
