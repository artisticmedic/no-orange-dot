#!/bin/bash
# Installs the virtual mic driver and restarts Core Audio. Needs sudo.
# Restarting Core Audio cuts all sound on the Mac for a second or two.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$ROOT/build/NoOrangeDot.driver" ] || { echo "Run scripts/build-driver.sh first."; exit 1; }
sudo rm -rf /Library/Audio/Plug-Ins/HAL/OnAir.driver /Library/Audio/Plug-Ins/HAL/NoOrangeDot.driver
sudo cp -R "$ROOT/build/NoOrangeDot.driver" /Library/Audio/Plug-Ins/HAL/
sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/NoOrangeDot.driver
sudo killall -9 coreaudiod
# The app recovers from the restart by itself; relaunching it is the belt to that pair of braces.
if pgrep -xq NoOrangeDot; then
  osascript -e 'quit app id "com.timgailey.noorangedot"' || true
  sleep 2
  open -b com.timgailey.noorangedot || true
fi
echo "Installed. 'No Orange Dot Mic' should now appear as an input device."
