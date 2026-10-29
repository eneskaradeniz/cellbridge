# Setting up the iPhone app

## 1. Build and install

You need a recent Xcode (iOS 26+ SDK), [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and an Apple ID
added to Xcode.

```
cd ios/CellBridge
cp Local.xcconfig.example Local.xcconfig      # then edit it: your team id and a bundle id prefix of your own
xcodegen generate
open CellBridge.xcodeproj                     # choose your iPhone, Run
```

The team id is in Xcode → Settings → Accounts (or at developer.apple.com → Membership). `Local.xcconfig` is not committed.
Command line instead of Xcode:

```
xcodebuild -project CellBridge.xcodeproj -scheme CellBridge -destination 'id=<device udid>' -allowProvisioningUpdates -derivedDataPath build build
xcrun devicectl device install app --device <device udid> build/Build/Products/Debug-iphoneos/CellBridge.app
```

After the first install trust the developer profile (Settings → General → VPN & Device Management). With a **free Apple ID the app
expires after 7 days**; build and install again.

## 2. First start

Allow **Local Network**, **Camera** (to scan the QR code), **Microphone**, **Notifications** and **Contacts**. Join the same network as the
Android phone (its hotspot, or one Wi-Fi). In the **Settings** tab:

1. On the Android phone open CellBridge, tap **Show** under *Pairing code*: a QR code appears for ten seconds.
2. On the iPhone tap **Scan the QR code** and hold it to the QR code. The iPhone stores the code (in the Keychain) and connects.

From then on the iPhone finds the phone by itself (Bonjour) and reconnects after a network change, when reopened or brought to the front.
**Phone Details** shows the pairing code and an address override behind Face ID (or the passcode); type an address only on a network
where Bonjour does not work. **Forget this phone** starts over.

## 3. Using it

- **Keypad / Recents / Contacts**: dial, call back, see missed calls (also those that came while the iPhone was away; pull a list to refresh).
  During a call: mute, keypad tones, speaker / audio route, and **To Android** to move the call to the phone.
- **Messages**: conversations, sending, delivery status, notifications that open the conversation. Pull to refresh; the line under the title shows when the phone last synced.
- A call running on the Android phone can be moved to the iPhone from the phone's call screen. With the app in the background, tap **Accept** on the lock screen.
- **Call with CellBridge** in Shortcuts / Spotlight / Siri, or `cellbridge://call?number=...`.
- Calls also show on the lock screen like any other call. Keep the app running (do not swipe it away): see [push.md](push.md).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Could not connect to the server" in Events | the host is unreachable: hotspot off, wrong host, or Android's `restricted_networking_mode` (see setup-android.md) |
| "Pairing code refused" | the code changed (app reinstalled on the Android phone): scan the QR code again |
| "Phone not reachable" | not on the phone's network, or its hotspot is off |
| No `audio` in the status | the daemon is not running on the Android phone |
| You cannot hear the far end | tap the speaker button (the earpiece is quiet unless held to the ear) |
| Something odd after hours of running | pull the log: `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier <your bundle id> --source "Library/Application Support/CellBridge/events.log" --destination events.log` (numbers and texts are never logged) |

## Limits of a free Apple ID

- **Default calling app:** iOS 18.2+ lets an app be chosen under Settings → Apps → Default Apps → Calling, so numbers tapped in
  Contacts or Safari would open CellBridge. That needs the `com.apple.developer.calling-app` capability, which Xcode refuses for
  personal teams ("do not support the Default Calling App capability"). Until a paid developer account is used, start calls from
  CellBridge itself, from the **Call with CellBridge** shortcut (Shortcuts, Spotlight, Siri, Action button), or with
  `cellbridge://call?number=<number>`.
- Default messaging apps and default dialers are EU-only features and not available.
