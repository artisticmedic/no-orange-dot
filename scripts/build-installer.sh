#!/bin/bash
# Builds a signed installer package holding the app and the driver:
#   build/No Orange Dot <version>.pkg
# Needs "Developer ID Application" and "Developer ID Installer" identities in the keychain.
# Pass --notarize to send it to Apple and staple the ticket (needs a notarytool keychain profile,
# named by NOTARY_PROFILE, default "onair").
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
NAME="Tim's Amazing No Orange Dot Microphone EQ"
VERSION="$(cat VERSION)"
PKG="$ROOT/build/No Orange Dot $VERSION.pkg"

SIGN_ID="Developer ID Application" ./scripts/build-driver.sh
./scripts/build-app.sh

STAGE="$ROOT/build/pkgroot"
rm -rf "$STAGE"
mkdir -p "$STAGE/Applications" "$STAGE/Library/Audio/Plug-Ins/HAL"
cp -R "$ROOT/build/$NAME.app" "$STAGE/Applications/"
cp -R "$ROOT/build/NoOrangeDot.driver" "$STAGE/Library/Audio/Plug-Ins/HAL/"
xattr -cr "$STAGE"   # no Finder metadata in the package

# Keep the app where it is put: without this the installer may "upgrade" a copy somewhere else on the disk.
PLIST="$ROOT/build/component.plist"
pkgbuild --analyze --root "$STAGE" "$PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :1:BundleIsRelocatable false" "$PLIST" 2>/dev/null || true

# Build unsigned, then sign as a separate step. The first time, macOS asks whether productsign may use
# the installer key: choose Always Allow. Pass --unsigned to skip signing (the package then only
# installs on this Mac, after a right-click and Open).
UNSIGNED="$ROOT/build/unsigned.pkg"
rm -f "$PKG" "$UNSIGNED"
pkgbuild --root "$STAGE" --component-plist "$PLIST" --scripts "$ROOT/installer/scripts" \
  --identifier com.timgailey.noorangedot.pkg --version "$VERSION" --install-location / "$UNSIGNED"
if [ "${1:-}" = "--unsigned" ]; then
  mv "$UNSIGNED" "$PKG"; echo "built $PKG (unsigned)"; exit 0
fi
productsign --sign "Developer ID Installer" --timestamp "$UNSIGNED" "$PKG"
rm -f "$UNSIGNED"
pkgutil --check-signature "$PKG" | sed -n 1,4p

if [ "${1:-}" = "--notarize" ]; then
  xcrun notarytool submit "$PKG" --keychain-profile "${NOTARY_PROFILE:-onair}" --wait
  xcrun stapler staple "$PKG"
  spctl -a -vv -t install "$PKG"
fi
echo "built $PKG"
