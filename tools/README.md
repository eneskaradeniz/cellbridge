# tools

Mac-side helpers for testing the Android host without the iPhone. Both need a Python venv with `websockets`
(`python3 -m venv .venv && .venv/bin/pip install websockets`) and `adb`.

- `ws_client.py <pairing-code> [seconds]` — control-channel test client: checks the handshake and error paths, then prints
  every host event. Options through environment variables: `AUTO=answer|reject` (answer incoming calls),
  `UDP_PORT`, `HANGUP_AFTER`, `DIAL=<number>`, `SMS_ACK=1`, `SEND_SMS="<to>|<body>"`, `HOST=<ip>` (default: `adb forward tcp:8765 tcp:8765`).
- `audiod_selftest.py` — end-to-end self-test of the root audio daemon's loopback protocol (no call needed, needs `adb root`).
- `install-daemon-system.sh install|uninstall` — installs the daemon as an init service on a userdebug device
  (**permanent change to `/system`**, see `docs/setup-android.md`).
