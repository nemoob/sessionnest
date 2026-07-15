#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/SessionNest.app"
ICON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sessionnest-icon.XXXXXX")"
ICONSET="$ICON_WORK/AppIcon.iconset"
trap 'rm -rf "$ICON_WORK"' EXIT

if [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

cd "$ROOT"
xcrun swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$ICONSET"
while read -r size filename; do
  sips -z "$size" "$size" Resources/AppIcon.png --out "$ICONSET/$filename" >/dev/null
done <<'EOF'
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
EOF
iconutil -c icns "$ICONSET" -o "$ICON_WORK/AppIcon.icns"
install -m 755 .build/release/SessionNest "$APP/Contents/MacOS/SessionNest"
install -m 644 "$ICON_WORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
install -m 644 Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
