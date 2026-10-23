#!/bin/bash
# Xcode produced an EMPTY .xcent for the simulator build (CODE_SIGN_ENTITLEMENTS self-reference), so the app had no App Group.
# Re-sign ad-hoc with an explicit entitlements file that carries the App Group of the Debug bundle id.
APP=$(find build/dd/Build/Products -maxdepth 2 -name 'SideStore.app' | head -1)
BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
echo "== app: $APP  bundle id: $BID"
ENT=$(mktemp -d)/sim.entitlements
cat > "$ENT" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.application-groups</key><array><string>group.$BID</string></array>
</dict></plist>
PL
cat "$ENT"
codesign --force --sign - --timestamp=none --entitlements "$ENT" "$APP" 2>&1 | tail -3
echo "== codesign -d --entitlements (after)"; codesign -d --entitlements :- "$APP" 2>&1 | head -30
