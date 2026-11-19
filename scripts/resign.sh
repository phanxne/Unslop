#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Re-sign an (injected) Viber IPA with your own development certificate.
#
#   scripts/resign.sh <in.ipa> <out.ipa> <profile.mobileprovision> "<signing identity>" [bundle id]
#
# Needs a development profile that covers your device (a wildcard profile works).
# App extensions are removed: they would each need their own profile, so
# notifications, share sheet, widgets and Siri do not work in the re-signed app.
set -euo pipefail

IN=$1; OUT=$2; PROFILE=$3; IDENTITY=$4; BUNDLE_ID=${5:-dev.unslop.viber}
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

unzip -q "$IN" -d "$WORK"
APP=$(echo "$WORK"/Payload/*.app)

PLIST=$WORK/profile.plist
security cms -D -i "$PROFILE" > "$PLIST"
TEAM=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PLIST")

rm -rf "$APP/PlugIns" "$APP/Extensions" "$APP/Watch" "$APP/_CodeSignature" "$APP/SC_Info"
find "$APP" -name '*.appex' -prune -exec rm -rf {} +
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
codesign -f -s "$IDENTITY" --entitlements "$WORK/ent.plist" "$APP"

rm -f "$OUT"
(cd "$WORK" && zip -qry "$OLDPWD/$OUT" Payload)
echo "signed $OUT as $BUNDLE_ID (team $TEAM)"
