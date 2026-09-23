#!/bin/bash
# Builds Wisp.app. Pass --install to copy it into /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Wisp.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClipBoard "$APP/Contents/MacOS/ClipBoard"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Sign with a real certificate when available so macOS keeps the Accessibility
# permission across rebuilds (ad-hoc signatures change on every build).
IDENTITY=$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"' || true)
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x ClipBoard 2>/dev/null && sleep 1 || true
    rm -rf /Applications/Wisp.app /Applications/ClipBoard.app # ClipBoard.app: the app's name before it became Wisp
    cp -R "$APP" /Applications/
    open /Applications/Wisp.app
    echo "Installed to /Applications and launched"
fi
