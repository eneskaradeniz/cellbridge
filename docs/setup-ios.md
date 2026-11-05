# Setting up the iPhone app

## 1. Build and install

You need a recent Xcode (iOS 26+ SDK), [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and a **paid Apple
Developer team** with the Push Notifications capability: the app carries the `aps-environment` entitlement (VoIP push, [push.md](push.md)), which a
free personal team cannot sign. (To try the app without push on a free Apple ID, remove the `entitlements:` block from `project.yml`; untested.)

```
cd ios/CellBridge
cp Local.xcconfig.example Local.xcconfig      # then edit it: your team id and a bundle id prefix of your own
xcodegen generate
open CellBridge.xcodeproj                     # choose your iPhone, Run
```

The team id is in Xcode → Settings → Accounts (or at developer.apple.com → Membership). `Local.xcconfig` is not committed.

If the team belongs to someone else (you cannot create profiles yourself), sign manually with the profile they made: install the
`.mobileprovision` (double click; Xcode keeps it under `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`), have their Development
certificate with its private key in your Keychain, and add to `Local.xcconfig`:

```
SIGN_STYLE = Manual
SIGN_IDENTITY = Apple Development: <the certificate's name as `security find-identity -v -p codesigning` prints it>
PROFILE_SPECIFIER = <the profile's name>
```

The profile must contain the bundle id, the iPhone's UDID and `aps-environment` (development for Debug builds). Command line instead of Xcode:

```
xcodebuild -project CellBridge.xcodeproj -scheme CellBridge -destination 'id=<device udid>' -allowProvisioningUpdates -derivedDataPath build build
xcrun devicectl device install app --device <device udid> build/Build/Products/Debug-iphoneos/CellBridge.app
```

After the first install trust the developer profile (Settings → General → VPN & Device Management). A development profile lasts a year
(a free Apple ID: 7 days). Installing over an app that another team signed is refused: delete that app first (its pairing is lost).

## 2. First start

Allow **Local Network** when asked. While nothing is paired the app opens a **setup sheet** with pairing and the **Contacts**, **Microphone**
and **Notifications** permissions, each with its reason (closing it is fine: the same rows are under *Settings → Permissions*, which also
shows a refused permission and opens iOS Settings for it). The **Camera** is asked when you scan; if it is refused the scanner says so and offers
*Enter the code by hand*; you can also scan the QR code with the iPhone's own Camera app, which should open CellBridge (not tried on a device yet). Join the same network as the
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
- A call running on the iPhone can be moved to the phone (**To Android**). While a call runs on the phone itself (moved there, or answered or
  dialed in its stock Phone app) a bar above the tab bar shows who and for how long, with **Take Over** to bring it back to the iPhone. (Implemented and
  unit-tested; not yet tried on the devices.)
- **Call with CellBridge** in Shortcuts / Spotlight / Siri, or `cellbridge://call?number=...`.
- Calls also show on the lock screen like any other call. With the app closed or swiped away a call still rings, through a VoIP push from the
  Android phone (needs the APNs key on the phone and internet on both phones, see [push.md](push.md)). Pull to refresh in Recents or Messages
  says why when the phone cannot be reached (not paired, not on its network).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Could not connect to the server" in Events | the host is unreachable: hotspot off, wrong host, or Android's `restricted_networking_mode` (see setup-android.md) |
| "Pairing code refused" | the code changed (app reinstalled on the Android phone): scan the QR code again |
| "Phone not reachable" | not on the phone's network, or its hotspot is off |
| No `audio` in the status | the daemon is not running on the Android phone |
| A closed app does not ring | the Android status screen's push line is not "Ready" (no APNs key, or the iPhone has not registered yet: open the app once on the phone's network); or no internet on one of the phones |
| You cannot hear the far end | tap the speaker button (the earpiece is quiet unless held to the ear) |
| Something odd after hours of running | pull the log: `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier <your bundle id> --source "Library/Application Support/CellBridge/events.log" --destination events.log` (numbers and texts are never logged) |

## Limits of a free Apple ID

- **Push:** a free personal team cannot enable Push Notifications, so a closed app cannot ring (see section 1).
- **Default calling app:** iOS 18.2+ lets an app be chosen under Settings → Apps → Default Apps → Calling, so numbers tapped in
  Contacts or Safari would open CellBridge. That needs the `com.apple.developer.calling-app` capability, which Xcode refuses for
  personal teams ("do not support the Default Calling App capability"). Until a paid developer account is used, start calls from
  CellBridge itself, from the **Call with CellBridge** shortcut (Shortcuts, Spotlight, Siri, Action button), or with
  `cellbridge://call?number=<number>`.
- Default messaging apps and default dialers are EU-only features and not available.
