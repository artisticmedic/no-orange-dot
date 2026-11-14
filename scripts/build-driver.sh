#!/bin/bash
# Builds the virtual mic driver from vendored BlackHole (GPL-3.0) into build/NoOrangeDot.driver.
# Device 1 "No Orange Dot Mic": visible, input only. This is the mic apps select.
# Device 2 "No Orange Dot Feed": hidden, output only. The menu bar app writes processed audio here.
# Set SIGN_ID to a Developer ID Application identity for a distributable build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/vendor/BlackHole"
# Our one change to BlackHole: the visible device can be renamed at runtime. Apply it once.
if git apply --check "$ROOT/patches/renameable-device.patch" 2>/dev/null; then git apply "$ROOT/patches/renameable-device.patch"; fi
xcodebuild -project BlackHole.xcodeproj -configuration Release -target BlackHole \
  CONFIGURATION_BUILD_DIR="$ROOT/build" \
  PRODUCT_BUNDLE_IDENTIFIER=com.timgailey.noorangedot.driver \
  PRODUCT_NAME=NoOrangeDot \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  GCC_PREPROCESSOR_DEFINITIONS='$GCC_PREPROCESSOR_DEFINITIONS
  kDriver_Name=\"NoOrangeDot\"
  kPlugIn_BundleID=\"com.timgailey.noorangedot.driver\"
  kHas_Driver_Name_Format=false
  kDevice_Name=\"No\ Orange\ Dot\ Mic\"
  kDevice2_Name=\"No\ Orange\ Dot\ Feed\"
  kDevice_HasOutput=false
  kDevice2_HasInput=false
  kDevice2_IsHidden=true
  kNumber_Of_Channels=2
  kManufacturer_Name=\"Tim\ Gailey\"
  kSampleRates=44100,48000,88200,96000' 2>&1 | grep -E "error|BUILD" || true
if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$ROOT/build/NoOrangeDot.driver"
else
  codesign --force --deep --sign - "$ROOT/build/NoOrangeDot.driver"
fi
codesign -dv "$ROOT/build/NoOrangeDot.driver" 2>&1 | grep -E "^Identifier|^Signature|^TeamIdentifier"
