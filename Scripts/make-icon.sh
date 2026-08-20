#!/bin/bash
# Build every required icon size from Jolt's selected source artwork.
set -euo pipefail
cd "$(dirname "$0")/.."

MASTER="art/icon-master.png"
ICONSET="art/Jolt.iconset"

if [ ! -f "$MASTER" ]; then
  echo "Missing $MASTER" >&2
  exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

render() { sips -z "$1" "$1" "$MASTER" --out "$ICONSET/$2" >/dev/null; }

render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o art/Jolt.icns
echo "Built art/Jolt.icns"
