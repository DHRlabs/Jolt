#!/bin/bash
# Build Jolt.app — a native menu-bar toggle for macOS `caffeinate`.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Jolt.app"
BIN="Jolt"
BUNDLE_ID="com.dhrlabs.jolt"
VERSION="${1:-1.0.0}"

# Icon: build it if missing
if [ ! -f art/Jolt.icns ]; then
    echo "Icon missing — generating…"
    bash Scripts/make-icon.sh
fi

echo "Compiling…"
mkdir -p build
swiftc -O Sources/main.swift -o "build/$BIN"

echo "Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "build/$BIN" "$APP/Contents/MacOS/$BIN"
cp art/Jolt.icns "$APP/Contents/Resources/Jolt.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                <string>Jolt</string>
    <key>CFBundleDisplayName</key>         <string>Jolt</string>
    <key>CFBundleExecutable</key>          <string>$BIN</string>
    <key>CFBundleIdentifier</key>          <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>            <string>Jolt</string>
    <key>CFBundleVersion</key>             <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>  <string>$VERSION</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>LSMinimumSystemVersion</key>      <string>13.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSPrincipalClass</key>            <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Ad-hoc signing…"
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Done → $(pwd)/$APP"
