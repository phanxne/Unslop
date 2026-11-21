#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Re-sign an (injected) Viber IPA with your own development certificate.
#
#   [GROUP_TAG=<11 chars>] scripts/resign.sh <in.ipa> <out.ipa> <profile.mobileprovision> "<signing identity>" [bundle id]
#
# Viber keeps its data in the app group "group.viber.share.container" (and a
# matching keychain group). Those belong to Viber's team, so a re-signed app
# cannot use them and shows "Something Went Wrong". Set GROUP_TAG to an
# 11-character id (replaces "viber.share", e.g. "unslop.vbr1") and use a profile
# that contains the group "group.<GROUP_TAG>.container".
#
# Needs a development profile that covers your device (a wildcard profile works).
# If the bundle id differs from the original, app extensions are removed (their
# ids would no longer match). If it is the original id (e.g. com.viber) they are
# kept and signed with minimal entitlements. Either way, push notifications,
# app groups and other special entitlements cannot come from a development
# profile, so those features do not work in the re-signed app.
set -euo pipefail

IN=$1; OUT=$2; PROFILE=$3; IDENTITY=$4; BUNDLE_ID=${5:-dev.unslop.viber}
GROUP_TAG=${GROUP_TAG:-}
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
# A development profile has no com.apple.developer.siri entitlement. Viber's
# Siri Shortcuts activity types (NSUserActivityTypes) make iOS offer "Add to
# Siri" on long-press anywhere in the app, which then crashes
# (NSInternalInconsistencyException: INPreferences requires the Siri
# entitlement) before any other long-press gesture, including Unslop's
# settings gesture, can run.
/usr/libexec/PlistBuddy -c "Delete :NSUserActivityTypes" "$APP/Info.plist" 2>/dev/null || true
# So this build is never confused with stock Viber on the Home Screen / App
# Library: rename it and switch to one of Viber's own bundled alternate icons
# (grayscale "AppIcon9") instead of the default purple one.
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Unslop" "$APP/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Unslop" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName AppIcon9" "$APP/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:0 AppIcon9" "$APP/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconName AppIcon9" "$APP/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles:0 AppIcon9" "$APP/Info.plist" 2>/dev/null || true
cp "$PROFILE" "$APP/embedded.mobileprovision"

/usr/libexec/PlistBuddy -c "Set :AppIdentifierPrefix $TEAM." "$APP/Info.plist" 2>/dev/null || true
# No app group in a development profile: keep the keychain group Viber expects
# (covered by the profile's TEAM.* keychain entry); the Unslop dylib redirects the
# shared container into the app's own sandbox.
GROUP_ENT="<key>keychain-access-groups</key><array><string>$TEAM.group.viber.share.keychain</string><string>$TEAM.$BUNDLE_ID</string></array>"
if [ -n "$GROUP_TAG" ]; then
  [ ${#GROUP_TAG} -eq 11 ] || { echo "GROUP_TAG must be exactly 11 characters" >&2; exit 1; }
  python3 - "$APP" "$GROUP_TAG" <<'PY'
import os, sys
app, tag = sys.argv[1], sys.argv[2].encode()
old = b"viber.share"
n = 0
for root, _, files in os.walk(os.path.join(app, "Frameworks")):
    for f in files:
        p = os.path.join(root, f)
        if os.path.islink(p) or not os.path.isfile(p): continue
        d = open(p, "rb").read()
        if old in d:
            open(p, "wb").write(d.replace(old, tag)); n += 1
print("patched app group string in", n, "file(s)")
PY
  GROUP_ENT="<key>com.apple.security.application-groups</key><array><string>group.$GROUP_TAG.container</string></array>
  <key>keychain-access-groups</key><array><string>$TEAM.group.$GROUP_TAG.keychain</string></array>"
fi

cat > "$WORK/ent.plist" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>$TEAM.$BUNDLE_ID</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM</string>
  <key>get-task-allow</key><true/>
  $GROUP_ENT
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
