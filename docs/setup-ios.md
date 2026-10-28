# Setting up the iPhone app

## 1. Build and install

You need a recent Xcode (iOS 17+ SDK), [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and an Apple ID
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

Allow **Local Network**, **Microphone** and **Notifications**. Join the Android phone's hotspot. In the **Settings** tab:

- *Host*: leave empty. The app uses the Wi-Fi gateway (on the hotspot that is the Android phone). Type an address only if that is wrong.
- *Pairing code*: the 8 characters shown on the Android phone's CellBridge screen.
- **Connect**. The status becomes `Connected (calls, sms, audio)`.

From then on the app reconnects by itself (after a network change, when reopened or brought to the front).

## 3. Using it

- **Keypad / Recents**: dial, call back, see missed calls. During a call: mute, speaker (voice-chat audio uses the earpiece by default), end.
- **Messages**: conversations, sending, notifications for new texts.
- Calls also show on the lock screen like any other call.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Could not connect to the server" in Events | the host is unreachable: hotspot off, wrong host, or Android's `restricted_networking_mode` (see setup-android.md) |
| "Host refused: unauthorized" | wrong pairing code |
| No `audio` in the status | the daemon is not running on the Android phone |
| You cannot hear the far end | tap the speaker button (the earpiece is quiet unless held to the ear) |
| Something odd after hours of running | pull the log: `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier <your bundle id> --source "Library/Application Support/CellBridge/events.log" --destination events.log` (numbers and texts are never logged) |
