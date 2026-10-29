#!/usr/bin/env bash
# Puts the team's APNs key on the Android phone, where the CellBridge app uses it to wake the iPhone app (docs/push.md).
# The key is a secret: it only ever goes to the app's private storage on the phone, never into the repository
# (*.p8 is git-ignored) and never into a log. Needs adb and a rooted (userdebug) phone.
#
#   tools/install-apns-key.sh install <AuthKey_XXXXXXXXXX.p8> <key id> <team id>
#   tools/install-apns-key.sh remove
set -euo pipefail

APP=com.cellbridge
DIR=/data/data/$APP/files/apns

case "${1:-}" in
install)
  KEY="${2:?usage: $0 install <AuthKey.p8> <key id> <team id>}"; KEY_ID="${3:?key id}"; TEAM_ID="${4:?team id}"
  [ -f "$KEY" ] || { echo "no such file: $KEY"; exit 1; }
  grep -q "BEGIN PRIVATE KEY" "$KEY" || { echo "that does not look like an APNs .p8 key"; exit 1; }
  [[ "$KEY_ID" =~ ^[A-Z0-9]{10}$ && "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo "key id and team id are 10 letters/digits each"; exit 1; }
  adb root >/dev/null; adb wait-for-device
  uid=$(adb shell "stat -c %u /data/data/$APP" | tr -d '\r')
  adb push "$KEY" /data/local/tmp/apns_key.p8 >/dev/null
  adb shell "mkdir -p $DIR && cp /data/local/tmp/apns_key.p8 $DIR/AuthKey.p8 && rm -f /data/local/tmp/apns_key.p8 \
    && printf '{\"keyId\":\"$KEY_ID\",\"teamId\":\"$TEAM_ID\"}' > $DIR/config.json \
    && chown -R $uid:$uid $DIR && chmod 700 $DIR && chmod 600 $DIR/AuthKey.p8 $DIR/config.json && restorecon -R $DIR"
  echo "installed: the phone's status screen should now say it is waiting for the iPhone to register"
  ;;
remove)
  adb root >/dev/null; adb wait-for-device
  adb shell "rm -rf $DIR /data/data/$APP/files/push.json"
  echo "removed the key and the stored iPhone token"
  ;;
*)
  echo "usage: $0 install <AuthKey.p8> <key id> <team id> | remove"; exit 64
  ;;
esac
