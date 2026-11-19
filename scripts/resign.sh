#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Re-sign an (injected) Viber IPA with your own development certificate.
#
#   scripts/resign.sh <in.ipa> <out.ipa> <profile.mobileprovision> "<signing identity>" [bundle id]
#
# Needs a development profile that covers your device (a wildcard profile works).
# If the bundle id differs from the original, app extensions are removed (their
# ids would no longer match). If it is the original id (e.g. com.viber) they are
# kept and signed with minimal entitlements. Either way, push notifications,
# app groups and other special entitlements cannot come from a development
# profile, so those features do not work in the re-signed app.
set -euo pipefail

IN=$1; OUT=$2; PROFILE=$3; IDENTITY=$4; BUNDLE_ID=${5:-com.viber}
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

unzip -q "$IN" -d "$WORK"
APP=$(echo "$WORK"/Payload/*.app)

PLIST=$WORK/profile.plist
security cms -D -i "$PROFILE" > "$PLIST"
TEAM=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PLIST")

ORIG_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
rm -rf "$APP/Watch" "$APP/_CodeSignature" "$APP/SC_Info"
if [ "$ORIG_ID" != "$BUNDLE_ID" ]; then
  rm -rf "$APP/PlugIns" "$APP/Extensions"
  find "$APP" -name '*.appex' -prune -exec rm -rf {} +
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :UIApplicationShortcutItems" "$APP/Info.plist" 2>/dev/null || true
cp "$PROFILE" "$APP/embedded.mobileprovision"

cat > "$WORK/ent.plist" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>$TEAM.$BUNDLE_ID</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM</string>
  <key>get-task-allow</key><true/>
</dict></plist>
ENT

# Sign inside-out: dylibs, frameworks, then the app.
find "$APP/Frameworks" -maxdepth 1 \( -name '*.dylib' -o -name '*.framework' \) -print0 2>/dev/null |
  while IFS= read -r -d '' f; do codesign -f -s "$IDENTITY" "$f"; done
find "$APP" -name '*.appex' -prune -print0 |
  while IFS= read -r -d '' x; do
    EID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$x/Info.plist")
    sed "s|$TEAM.$BUNDLE_ID|$TEAM.$EID|" "$WORK/ent.plist" > "$WORK/ent-ext.plist"
    cp "$PROFILE" "$x/embedded.mobileprovision"
    rm -rf "$x/_CodeSignature"
    codesign -f -s "$IDENTITY" --entitlements "$WORK/ent-ext.plist" "$x"
  done
codesign -f -s "$IDENTITY" --entitlements "$WORK/ent.plist" "$APP"

rm -f "$OUT"
(cd "$WORK" && zip -qry "$OLDPWD/$OUT" Payload)
echo "signed $OUT as $BUNDLE_ID (team $TEAM)"
