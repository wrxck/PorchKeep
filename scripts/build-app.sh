#!/usr/bin/env bash
# build-app.sh — builds PorchKeep.app from the Swift Package and assembles the
# .app bundle structure manually (since we are not using Xcode).
#
# Output: build/PorchKeep.app  (drag to /Applications)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/PorchKeep.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

if [[ ! -d "$ROOT/Resources/bridge/node_modules/eufy-security-ws" ]]; then
    echo "==> Bridge not installed; running install-bridge.sh"
    bash "$ROOT/scripts/install-bridge.sh"
fi

echo "==> swift build -c release"
(cd "$ROOT" && swift build -c release)

EXEC="$(cd "$ROOT" && swift build -c release --show-bin-path)/PorchKeep"
if [[ ! -x "$EXEC" ]]; then
    echo "ERROR: executable not found at $EXEC" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp "$EXEC" "$MACOS/PorchKeep"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
# Copy bundled resources.
if [[ -f "$ROOT/Resources/ffmpeg" ]]; then
    cp "$ROOT/Resources/ffmpeg" "$RESOURCES/ffmpeg"
    chmod +x "$RESOURCES/ffmpeg"
fi
mkdir -p "$RESOURCES/bridge"
cp -R "$ROOT/Resources/bridge/node" "$RESOURCES/bridge/node"
cp -R "$ROOT/Resources/bridge/node_modules" "$RESOURCES/bridge/node_modules"
cp "$ROOT/Resources/bridge/package.json" "$RESOURCES/bridge/package.json"

# Ad-hoc sign every Mach-O we shipped, then the bundle.
echo "==> codesign (ad-hoc)"
codesign --force --sign - --timestamp=none "$RESOURCES/bridge/node/bin/node" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$RESOURCES/ffmpeg" 2>/dev/null || true
codesign --force --deep --sign - "$APP"

echo
echo "Built: $APP"
echo "Open it via:"
echo "  open '$APP'"
echo
echo "First launch: macOS Gatekeeper may complain — right-click → Open, or visit"
echo "System Settings → Privacy & Security and approve PorchKeep."
