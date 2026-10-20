#!/bin/bash
# Builds Joe.dmg for people to download and install (build/Joe.dmg).
#
#   ./scripts/release.sh             unsigned test build: friends open it with right-click → Open
#   JOE_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/release.sh
#                                    signed with Developer ID and the hardened runtime, notarised by
#                                    Apple and stapled: opens with no warnings on any Mac
#
# One-time setup for the signed build (needs an Apple Developer account, $99 a year):
#   1. Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application.
#   2. Save notarisation credentials (an app-specific password from appleid.apple.com):
#      xcrun notarytool store-credentials joe-notary --apple-id <you@example.com> --team-id <TEAMID>
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh --release >/dev/null
rm -f build/Joe.zip # the .dmg replaces the old zip
APP="build/Joe.app"
DMG="build/Joe.dmg"
IDENTITY="${JOE_IDENTITY:-}"

if [ -n "$IDENTITY" ]; then
  # Inside out: the framework first, then the app, with a secure timestamp and the hardened runtime.
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Frameworks/llama.framework"
  codesign --force --timestamp --options runtime --entitlements Resources/Joe.entitlements --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
fi

# The disk image: Joe and a shortcut to Applications to drag it onto.
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Joe" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "$IDENTITY" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile joe-notary --wait
  xcrun stapler staple "$DMG"
  echo "Signed, notarised and stapled: $DMG"
else
  echo "Unsigned test build: $DMG (friends: right-click Joe → Open the first time)."
fi
