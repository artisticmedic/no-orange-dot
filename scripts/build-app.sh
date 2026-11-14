#!/bin/bash
# Builds the menu bar app into build/. Signs with a Developer ID Application identity when one is
# installed (hardened runtime, ready to notarize); otherwise falls back to ad-hoc signing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
NAME="Tim's Amazing No Orange Dot Microphone EQ"
VERSION="$(cat VERSION)"
# Universal: Apple silicon and Intel.
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/NoOrangeDot"
APP="$ROOT/build/$NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/NoOrangeDot"
mkdir -p "$APP/Contents/Resources"
# The paint icon is the one Finder shows. Both travel in the app so the Dock icon can be switched while it runs.
MASTER="$ROOT/assets/icons/paint.png"
[ -f "$MASTER" ] || { MASTER="$ROOT/build/icon-1024.png"; "$BIN" --icon "$MASTER"; }
SET="$ROOT/build/AppIcon.iconset"; rm -rf "$SET"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$MASTER" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$MASTER" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
for i in paint carbon; do [ -f "$ROOT/assets/icons/$i.png" ] && sips -z 512 512 "$ROOT/assets/icons/$i.png" --out "$APP/Contents/Resources/icon-$i.png" >/dev/null; done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.timgailey.noorangedot</string>
  <key>CFBundleName</key><string>No Orange Dot</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>NoOrangeDot</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Your microphone is opened only while an app is using No Orange Dot Mic, or while you record.</string>
</dict></plist>
PLIST
ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')}"
if [ -n "$ID" ]; then
  codesign --force --options runtime --timestamp --entitlements "$ROOT/NoOrangeDot.entitlements" --sign "$ID" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "built $APP"
