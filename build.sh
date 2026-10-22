#!/bin/bash
# Builds TokenMeter.app (ad-hoc signed) next to this script.
#   ./build.sh               native build for this Mac
#   UNIVERSAL=1 ./build.sh   universal (arm64 + x86_64) build, used for releases
set -euo pipefail
cd "$(dirname "$0")"
ARCHFLAGS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then ARCHFLAGS=(--arch arm64 --arch x86_64); fi
swift build -c release ${ARCHFLAGS[@]+"${ARCHFLAGS[@]}"}
BIN="$(swift build -c release ${ARCHFLAGS[@]+"${ARCHFLAGS[@]}"} --show-bin-path)/TokenMeter"
APP="$PWD/build/TokenMeter.app"
rm -rf "$APP"
# Source commit this build came from (read by the in-app update check).
COMMIT=unknown; DIRTY=false
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then DIRTY=true; fi
fi
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/TokenMeter"
mkdir -p "$APP/Contents/Resources"
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$BIN" --make-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/gauge.svg "$APP/Contents/Resources/gauge.svg"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.local.tokenmeter</string>
  <key>CFBundleName</key><string>TokenMeter</string>
  <key>CFBundleDisplayName</key><string>TokenMeter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>TokenMeter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>TokenMeterCommit</key><string>$COMMIT</string>
  <key>TokenMeterDirty</key><string>$DIRTY</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP"
echo "$APP"
