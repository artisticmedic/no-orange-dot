#!/bin/bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_ROOT"
mkdir -p .build/icon-module-cache
xcrun swiftc -module-cache-path .build/icon-module-cache \
    assets/GenerateAppIcon.swift Sources/NoOrangeDot/AppMark.swift \
    -o .build/generate-app-icon
.build/generate-app-icon "$APP_ROOT"
iconutil -c icns .build/AppIcon.iconset -o assets/AppIcon.icns
echo "Generated assets/AppIcon.icns and assets/AppIcon.png"
