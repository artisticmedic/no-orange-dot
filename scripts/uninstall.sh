#!/bin/bash
# Removes the app and the virtual mic driver, then restarts Core Audio. Needs sudo.
# Restarting Core Audio cuts all sound on the Mac for a second or two.
set -euo pipefail
pkill -f "Contents/MacOS/NoOrangeDot" || true
sudo rm -rf "/Applications/Tim's Amazing No Orange Dot Microphone EQ.app" /Library/Audio/Plug-Ins/HAL/NoOrangeDot.driver
sudo killall -9 coreaudiod
echo "Removed. Settings remain in ~/Library/Preferences/com.timgailey.noorangedot.plist."
