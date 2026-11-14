#!/bin/bash
# Removes the app, the virtual mic driver and the nod command, then restarts Core Audio. Needs sudo.
# Restarting Core Audio cuts all sound on the Mac for a second or two.
# Settings and recordings stay; pass --settings to remove the settings folder as well.
set -euo pipefail
APP="/Applications/Tim's Amazing No Orange Dot Microphone EQ.app"
pkill -f "Contents/MacOS/NoOrangeDot" || true
if [ -L /usr/local/bin/nod ] && [[ "$(readlink /usr/local/bin/nod)" == "$APP"* ]]; then sudo rm /usr/local/bin/nod; fi
sudo rm -rf "$APP" /Library/Audio/Plug-Ins/HAL/NoOrangeDot.driver
sudo pkgutil --forget com.timgailey.noorangedot.pkg >/dev/null 2>&1 || true
sudo killall -9 coreaudiod
SETTINGS="$HOME/Library/Application Support/NoOrangeDot"
if [ "${1:-}" = "--settings" ]; then
  rm -rf "$SETTINGS"
  echo "Removed, with its settings."
else
  echo "Removed. Settings remain in $SETTINGS."
fi
