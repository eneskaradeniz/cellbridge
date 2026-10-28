#!/usr/bin/env bash
# Installs (or removes) the call-audio daemon as an init service on a userdebug build with an unlocked bootloader,
# so it starts at every boot. This is a PERMANENT change to the device:
#   install   disables dm-verity where the ROM allows it, remounts /system writable (overlay) and adds three files:
#               /system/bin/cellbridge_audiod, /system/etc/init/cellbridge_audiod.rc, /system/etc/cellbridge/<profile>
#   uninstall removes those files and re-enables dm-verity.
# A LineageOS update replaces /system and removes the service; run install again afterwards.
# Needs: adb, a built daemon (android/daemon/build.sh). The device reboots during the run.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${PROFILE:-platina}"
BIN=android/daemon/build/cellbridge_audiod
RC=android/daemon/init/cellbridge_audiod.rc
PROFILE_FILE="android/daemon/profiles/$PROFILE.profile"

wait_for_boot() {
  adb wait-for-device
  until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 3; done
  sleep 5
}

reboot() { adb reboot; sleep 20; wait_for_boot; }

case "${1:-}" in
install)
  [ -f "$BIN" ] && [ -f "$RC" ] && [ -f "$PROFILE_FILE" ] || { echo "build the daemon first: android/daemon/build.sh"; exit 1; }
  [ "$(adb shell getprop ro.build.type | tr -d '\r')" = "userdebug" ] || { echo "needs a userdebug build"; exit 1; }
  adb root >/dev/null; wait_for_boot
  echo "== disabling dm-verity"
  # Some ROMs (this one included) ship no AVB header in vbmeta: nothing to disable, and nothing in the way.
  adb disable-verity || echo "(verity state could not be changed; continuing, remount decides)"
  echo "== reboot"; reboot
  adb root >/dev/null; wait_for_boot
  echo "== remounting /system"; adb remount
  adb push "$BIN" /system/bin/cellbridge_audiod
  adb shell 'mkdir -p /system/etc/cellbridge'
  adb push "$PROFILE_FILE" "/system/etc/cellbridge/$PROFILE.profile"
  adb push "$RC" /system/etc/init/cellbridge_audiod.rc
  adb shell 'chmod 755 /system/bin/cellbridge_audiod; chmod 644 /system/etc/init/cellbridge_audiod.rc /system/etc/cellbridge/*.profile; restorecon -R /system/bin/cellbridge_audiod /system/etc/init/cellbridge_audiod.rc /system/etc/cellbridge'
  echo "== reboot to start the service"; reboot
  echo "installed; check with: adb shell 'pidof cellbridge_audiod'"
  ;;
uninstall)
  adb root >/dev/null; wait_for_boot
  adb remount || true
  adb shell 'rm -f /system/bin/cellbridge_audiod /system/etc/init/cellbridge_audiod.rc; rm -rf /system/etc/cellbridge'
  echo "== re-enabling dm-verity"; adb enable-verity || true
  reboot
  echo "uninstalled"
  ;;
*)
  echo "usage: $0 install|uninstall"; exit 64
  ;;
esac
