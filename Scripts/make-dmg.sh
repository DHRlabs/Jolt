#!/bin/bash
# Package Jolt.app into a drag-to-install DMG.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Jolt.app"
DMG="build/Jolt.dmg"
VOL="Jolt"
STAGE="build/dmg-stage"

[ -d "$APP" ] || { echo "Build the app first: Scripts/build.sh"; exit 1; }

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Give the volume the app icon
cp art/Jolt.icns "$STAGE/.VolumeIcon.icns"
SetFile -c icnC "$STAGE/.VolumeIcon.icns" 2>/dev/null || true

hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -rf "$STAGE"

echo "Done → $(pwd)/$DMG"
