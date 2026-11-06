# Waking the iPhone app for a call (push)

**Status:** working. The Android host and the iPhone side (PushKit registration in `PushRegistry`, the call in `CallCoordinator.reportPushed`, the
`push_token` message) are unit-tested (the iPhone opens a box sealed by the host's test vector) and were tried end to end on the reference
devices: with the iPhone app closed, a call to the SIM rang on the iPhone.
The iPhone build needs a team with Push Notifications: the `aps-environment` entitlement (`APS_ENVIRONMENT` in `Config.xcconfig`, development for
Debug, production for Release) must match the provisioning profile; a free personal team cannot build it.

## Why

iOS starts an app that was closed (or killed by the system) only for a **VoIP push** delivered by Apple's push service (APNs). Without
it the iPhone does not ring when the CellBridge app is not running. The Android phone sends the push when a call starts ringing, over
the internet (its mobile data or the Wi-Fi), so **both phones need an internet connection at that moment**. The audio itself still
travels over the local network, so the iPhone must be on the Android phone's network to talk.

## What you need

1. A paid **Apple Developer Program** membership (free Apple IDs cannot enable Push Notifications; the same account also lifts the 7-day
   expiry and may allow the *Default Calling App* capability, see setup-ios.md).
2. An **App ID** for the app's bundle id with the *Push Notifications* capability, and a development provisioning profile that includes it.
3. An **APNs authentication key** (`AuthKey_XXXXXXXXXX.p8`, Certificates, Identifiers & Profiles → Keys). Restrict it to this app and to the
   environment you use if the portal offers it. **The key is a secret**: it lets whoever has it send pushes to your apps.
4. Your **Team ID** and the key's **Key ID** (10 characters each).

## Setup

```
tools/install-apns-key.sh install ~/Downloads/AuthKey_XXXXXXXXXX.p8 <key id> <team id>
```

The key goes into the CellBridge app's private storage on the Android phone (`files/apns/`, mode 600) and nowhere else. The phone's status screen then
says *Key installed, waiting for the iPhone to register*. `tools/install-apns-key.sh remove` deletes it again.

## How it works (docs/protocol.md has the exact messages)

- The iPhone registers for VoIP pushes (PushKit) and sends the Android phone its token, whether it is a development build (sandbox APNs) or not,
  the push topic (`<bundle id>.voip`) and a random 32-byte key kept in its Keychain.
- When an incoming call rings: with no iPhone connected the Android phone posts to APNs at once; with one connected it waits 3 seconds and posts only
  if the call is still ringing (the connection might be dead).
- The push body is sealed (AES-256-GCM) with the shared key, so Apple does not see the number. The iPhone must report a call to CallKit for every
  push it receives (iOS ends apps that do not); it uses a call id derived from the host's call id so a push for a call it already knows is harmless, then connects and
  ends the call again if the host does not list it as ringing.

## Texts while the app is closed

See docs/protocol.md ("Waking the client for a text"). The host sends an ordinary alert push, sealed like the call push; the
`CellBridgeNotify` notification service extension opens it with the key in the shared Keychain group and shows sender and text.
Both phones need an internet connection at that moment. The iPhone has no SIM, so it must be on some Wi-Fi.

## Still to do

- Missed calls as visible notifications while the app is closed.
