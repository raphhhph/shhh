#!/bin/bash
# Builds Joe.app into ./build.
#   ./scripts/build.sh            build only
#   ./scripts/build.sh --install  build, copy to /Applications and (re)launch
#   ./scripts/build.sh --release  build signed ad-hoc and zip it to build/Shhh.zip (for GitHub releases)
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
APP="build/Joe.app"
SIGN_ID="Shhh Local Signing"

swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/Shhh" "$APP/Contents/MacOS/Joe"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/slides.py "$APP/Contents/Resources/slides.py"
cp Resources/mathdoc.js "$APP/Contents/Resources/mathdoc.js"
cp -R "$BIN/llama.framework" "$APP/Contents/Frameworks/"
for bundle in "$BIN"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Joe" 2>/dev/null || true

# Local builds are signed with the local certificate if it exists, so macOS keeps the
# Accessibility and Microphone permissions across rebuilds (create it once with
# ./scripts/make-signing-cert.sh). Release downloads are signed ad-hoc.
if [ "$MODE" != "--release" ] && security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  IDENTITY="$SIGN_ID"
else
  IDENTITY="-"
  [ "$MODE" != "--release" ] && echo "Note: signing ad-hoc. Run ./scripts/make-signing-cert.sh so permissions survive rebuilds."
fi
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/llama.framework"
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP"

case "$MODE" in
  --install)
    { pkill -x Joe; pkill -x Shhh; } 2>/dev/null && sleep 1 || true
    rm -rf /Applications/Joe.app /Applications/Shhh.app # Shhh.app: the app's old name
    cp -R "$APP" /Applications/Joe.app
    open /Applications/Joe.app
    echo "Installed to /Applications and launched."
    ;;
  --release)
    rm -f build/Joe.zip
    ditto -c -k --keepParent "$APP" build/Joe.zip
    echo "Zipped to build/Joe.zip"
    ;;
esac
