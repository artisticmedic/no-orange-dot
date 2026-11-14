#!/bin/zsh
# Clean-machine check of the installer in a throwaway macOS guest (needs the `vm` tool):
# install, Gatekeeper, the device appears, rename, Core Audio restart, uninstall.
# The guest has no microphone, so this does not prove that audio passes.
set -uo pipefail
cd "${0:A:h}/.."
PKG="build/No Orange Dot $(cat VERSION).pkg"
APP="/Applications/Tim's Amazing No Orange Dot Microphone EQ.app"
BIN="$APP/Contents/MacOS/NoOrangeDot"
[ -f "$PKG" ] || { echo "no $PKG; run scripts/build-installer.sh --notarize"; exit 2 }

LEASE=$(vm get --for no-orange-dot --reason "installer clean-install check" --wait) || { echo "no guest; nothing was checked"; exit 2 }
trap 'vm give "$LEASE" >/dev/null' EXIT
fails=0
check() { # name, command run in the guest
  if vm run "$LEASE" "$2" >/tmp/nod-vm-check.out 2>&1; then echo "ok    $1"
  else echo "FAIL  $1"; sed 's/^/        /' /tmp/nod-vm-check.out | tail -6; fails=$((fails + 1)); fi
}
devices="system_profiler SPAudioDataType"

vm push "$LEASE" "$PKG" /tmp/nod.pkg
vm push "$LEASE" scripts/uninstall.sh /tmp/uninstall.sh
check "package passes Gatekeeper"        "spctl -a -t install /tmp/nod.pkg"
check "no device before install"         "! $devices | grep -q 'No Orange Dot'"
check "installer runs"                   "sudo installer -pkg /tmp/nod.pkg -target /"
check "app passes Gatekeeper"            "spctl -a -t exec \"$APP\""
check "driver is in place"               "test -d /Library/Audio/Plug-Ins/HAL/NoOrangeDot.driver"
check "device appears"                   "sleep 4; $devices | grep -q 'No Orange Dot Mic'"
check "app starts and reports the driver" "open -g \"$APP\" --args --quiet; sleep 6; \"$BIN\" status | grep -q '\"driverInstalled\" *: *true'"
check "rename reaches Core Audio"        "\"$BIN\" name Check Mic >/dev/null; sleep 3; $devices | grep -q 'Check Mic'"
check "rename survives a restart"        "sudo killall -9 coreaudiod; sleep 6; $devices | grep -q 'Check Mic'"
check "app recovers after the restart"   "\"$BIN\" status | grep -q '\"driverInstalled\" *: *true'"
check "name resets"                      "\"$BIN\" name reset >/dev/null; sleep 3; $devices | grep -q 'No Orange Dot Mic'"
check "settings verbs work"              "\"$BIN\" mute on | grep -q '\"muted\" *: *true' && \"$BIN\" mute off >/dev/null"
check "uninstall runs"                   "bash /tmp/uninstall.sh"
check "app and driver are gone"          "sleep 4; ! test -e \"$APP\" && ! test -e /Library/Audio/Plug-Ins/HAL/NoOrangeDot.driver"
check "device is gone"                   "! $devices | grep -q 'No Orange Dot'"

[ $fails -eq 0 ] && echo "all checks passed" || echo "$fails failed"
exit $fails
