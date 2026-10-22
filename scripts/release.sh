#!/bin/bash
# Builds Joe.dmg for people to download and install (build/Joe.dmg).
#
#   ./scripts/release.sh             unsigned test build: friends follow the "First open guide" in the DMG
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
elif security find-certificate -c "Shhh Local Signing" >/dev/null 2>&1; then
  # No Developer ID: the local certificate instead of ad-hoc, so the Accessibility switch a friend
  # turns on still counts after they install a newer test build (ad-hoc changes with every build).
  codesign --force --sign "Shhh Local Signing" "$APP/Contents/Frameworks/llama.framework"
  codesign --force --sign "Shhh Local Signing" "$APP"
  codesign --verify --deep --strict "$APP"
fi

# The disk image: a window with Joe, an arrow onto Applications and a first-open guide.
# Background: Resources/DMG/background*.png (redraw with scripts/make-dmg-background.py).
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "Resources/DMG/First open guide.html" "$STAGE/"
mkdir "$STAGE/.background"
tiffutil -cathidpicheck Resources/DMG/background.png Resources/DMG/background@2x.png \
  -out "$STAGE/.background/background.tiff" >/dev/null
rm -f "$DMG" build/Joe-rw.dmg
hdiutil create -volname "Joe" -srcfolder "$STAGE" -ov -format UDRW build/Joe-rw.dmg >/dev/null
rm -rf "$STAGE"

# Lay out the Finder window (Terminal needs permission to control Finder the first time).
hdiutil detach "/Volumes/Joe" -quiet 2>/dev/null || true
MOUNT=$(hdiutil attach build/Joe-rw.dmg -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF}')
osascript <<APPLESCRIPT || echo "Note: couldn't style the window (allow Terminal to control Finder); the DMG still works."
tell application "Finder"
  tell disk "Joe"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    # bounds include the ~28 pt title bar: 480 pt of content to match the background
    set bounds of container window to {200, 120, 860, 628}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Joe.app" of container window to {170, 190}
    set position of item "Applications" of container window to {490, 190}
    set position of item "First open guide.html" of container window to {330, 400}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
cp Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns" && { SetFile -a C "$MOUNT" 2>/dev/null || true; }
sync
hdiutil detach "$MOUNT" -quiet
hdiutil convert build/Joe-rw.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f build/Joe-rw.dmg

if [ -n "$IDENTITY" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile joe-notary --wait
  xcrun stapler staple "$DMG"
  echo "Signed, notarised and stapled: $DMG"
else
  echo "Unsigned test build: $DMG (first open: Privacy & Security → Open Anyway, see the guide in the DMG)."
fi
