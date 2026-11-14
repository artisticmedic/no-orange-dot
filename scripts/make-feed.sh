#!/bin/zsh
# Writes build/latest.json, the file the app's updater reads, for the installer of the current VERSION.
#   scripts/make-feed.sh <https address the package will be downloaded from> ["release notes"]
# Upload the package to that address, then put latest.json at the app's update address.
set -euo pipefail
cd "${0:A:h}/.."
URL="${1:?Give the https address the package will be downloaded from}"
[[ "$URL" == https://* ]] || { echo "The address must start with https://"; exit 1 }
VERSION="$(cat VERSION)"
PKG="build/No Orange Dot $VERSION.pkg"
[ -f "$PKG" ] || { echo "no $PKG; run scripts/build-installer.sh --notarize"; exit 1 }
spctl -a -t install "$PKG" || { echo "$PKG is not notarized; the app would refuse it"; exit 1 }
VERSION="$VERSION" URL="$URL" NOTES="${2:-}" python3 -c '
import json, os
r = {"version": os.environ["VERSION"], "url": os.environ["URL"], "minimumSystem": "14.0"}
if os.environ["NOTES"]: r["notes"] = os.environ["NOTES"]
print(json.dumps(r, indent=2))' > build/latest.json
cat build/latest.json
