#!/bin/bash
# Builds Wisp.app.
#   ./build.sh            build build/Wisp.app for this Mac's architecture
#   ./build.sh --install  also copy it into /Applications and launch it
#   ./build.sh --dmg      build a universal (Apple silicon + Intel) app and package build/Wisp.dmg
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
APP="build/Wisp.app"

if [[ "$MODE" == "--dmg" ]]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN=".build/apple/Products/Release/ClipBoard"
else
    swift build -c release
    BIN=".build/release/ClipBoard"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClipBoard"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Sign with a real certificate when available so macOS keeps the Accessibility
# permission across rebuilds (ad-hoc signatures change on every build).
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"' || true)
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP"

if [[ "$MODE" == "--install" ]]; then
    pkill -x ClipBoard 2>/dev/null && sleep 1 || true
    rm -rf /Applications/Wisp.app /Applications/ClipBoard.app # ClipBoard.app: the app's name before it became Wisp
    cp -R "$APP" /Applications/
    open /Applications/Wisp.app
    echo "Installed to /Applications and launched"
fi

if [[ "$MODE" == "--dmg" ]]; then
    STAGE="build/dmg"
    rm -rf "$STAGE" build/Wisp.dmg
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "Wisp" -srcfolder "$STAGE" -ov -format UDZO build/Wisp.dmg
    rm -rf "$STAGE"
    echo "Built build/Wisp.dmg"
fi
