# CellBridge

Turn a **rooted Android phone with a SIM card** into a wireless GSM modem for an **iPhone** on the same Wi-Fi.
The iPhone rings for incoming calls, places outgoing calls and sends and receives SMS; the Android phone only provides the SIM
and the radio. No internet and no cloud: everything stays on the local network (typically the Android phone's own hotspot).

```
                     Wi-Fi hotspot (local network only)
  iPhone (client)  ◀──── WebSocket (JSON): calls, SMS ─────▶  Android app (host)
  CallKit, SwiftUI ◀──── UDP, 16 kHz PCM, 20 ms frames ─────▶  + root audio daemon (C, tinyalsa)
                                                               ↕ modem DSP (call audio, SIM)
```

> Personal project, published as is. It works on the reference device below; other devices need a profile (see
> [docs/device-profiles.md](docs/device-profiles.md)). Not an App Store or Play Store product.

## What works

| | Status |
|---|---|
| Incoming calls: rings on the iPhone's lock screen (CallKit), answer / decline / hang up, two-way audio; the phone's own ringer goes quiet (Do Not Disturb access) | working |
| Outgoing calls from the iPhone (keypad, contacts, recents, in-call screen), keypad tones (DTMF) during a call | working |
| Moving a running call from the iPhone to the phone, and back: the iPhone shows the calls running on the phone (also ones started in its stock Phone app) with a **Take Over** button | implemented and unit-tested; not yet tried on the devices |
| SMS: receive (lossless while the iPhone is offline), send (safe to repeat after a dropped connection), long texts, delivery reports ("Delivered"), notifications that open the conversation, security codes offered by the keyboard | working |
| History: calls and texts the phone saw while the iPhone was away (missed calls, older conversations) are fetched after reconnecting; pull to refresh | working |
| Pairing: the iPhone finds the phone by itself (Bonjour), pairs once by scanning a QR code (the iPhone's own Camera app should work too, not tried yet); the code is hidden behind Face ID. A first-run sheet and Settings handle the permissions and explain refused ones | working |
| The phone keeps its stock Phone app; CellBridge's own Android app is a status and pairing screen (calls are watched by a screenless `InCallService`) | working |
| The phone's hotspot comes on by itself when it leaves its home Wi-Fi and goes off when it returns (root daemon; a switch on the Status screen) | working |
| The phone's battery and signal on the iPhone, with a warning before it runs out | working |
| English and Turkish, iOS 26 Liquid Glass design | working |
| Waking a closed iPhone app for a call (VoIP push through Apple) | working; needs a paid developer account and an APNs key: [docs/push.md](docs/push.md) |
| MMS, conference / second call, voicemail, numbers tapped in Contacts or Safari opening CellBridge | not supported (see limitations) |

## Requirements

- **Android host:** a rooted, Qualcomm-based phone whose DSP exposes the voice record / incall-music mixer controls
  (reference: **Xiaomi Mi 8 Lite "platina", LineageOS 22.2, Android 15, `userdebug`**), a SIM, Android 10+ (minSdk 29).
  Without root the app still handles calls and SMS but **call audio cannot be bridged** (the host then advertises no `audio`).
- **iPhone:** iOS 26.1+, Xcode and a **paid Apple Developer team** (the app uses VoIP push, which a free Apple ID cannot sign; a free Apple ID
  could only run a build without push, which expires after 7 days).
- Both phones on the same Wi-Fi (the Android phone's hotspot works well).

## Quick start

1. [docs/setup-android.md](docs/setup-android.md): install the app, give it the SMS permissions and the few `adb` grants, start the audio daemon.
2. [docs/setup-ios.md](docs/setup-ios.md): build and install the iPhone app, scan the QR code shown on the Android phone.

## Known limitations

- **A closed iPhone app rings only through a push** from Apple's service ([docs/push.md](docs/push.md)): both phones need internet at that
  moment, and the Android phone needs the APNs key. The audio still travels over the local network.
- **Both phones must be on the same network** (the Android phone's hotspot, or one Wi-Fi). Audio travels by local UDP, so away from the
  network the iPhone would ring but could not talk.
- Call audio quality is good on a home Wi-Fi (about 0.1% of the frames concealed each way in a real call). The hotspot is 2.4 GHz only on the reference
  phone (5 GHz failed there), which is worse in crowded places; measure before relying on it.
- iOS does not let a third-party app take over `tel:` links without the paid *Default Calling App* capability: start calls from CellBridge,
  the **Call with CellBridge** shortcut, or `cellbridge://call?number=...`. Default messaging apps are EU-only.
- Security codes arrive as CellBridge notifications; the iOS keyboard offers them for one-time-code fields (iOS 26). They are not in Apple's Messages.
- After an Android reboot the app switches the hotspot on by itself once it runs, if the phone is away from its home Wi-Fi; with a screen lock the phone must be **unlocked once**
  before the app's server starts (Android keeps app data encrypted until then). Removing the screen lock avoids the second one.
- The installed daemon service lives in `/system` and is **removed by a ROM update**; run the install script again afterwards.
- One call at a time. The Android phone is quietened (Do Not Disturb, "alarms only") only after the iPhone confirms it is ringing, so it rings for a
  second or two first, and keeps ringing if the iPhone never answers (a call is never lost). Without the Do Not Disturb access both ring.
- Apple signing: a development profile lasts a year; a team made by someone else needs a manual profile (see [docs/setup-ios.md](docs/setup-ios.md)).
- iPhone background behaviour relies on a silent audio session; its battery cost is not measured yet.

## Security notes

- Pairing uses an 8-character code from a 32-symbol alphabet shown on the Android phone (about 40 bits; wrong attempts are delayed),
  as a QR code for ten seconds on request. It is **not strong against a determined attacker on the same network**. The iPhone keeps it
  in the Keychain and shows it only after Face ID.
- The control channel and the audio are **not encrypted**. Use a network you control, such as your own phone's WPA2/WPA3 hotspot.
- The audio daemon listens on `127.0.0.1` only and authenticates the app with the same code, read from a file only the app and root can read.
- Emergency numbers are never dialed through the bridge, and neither are `*`/`#` service codes. Dial them on the Android phone itself, in its Phone app.
- Waking the iPhone goes through Apple's push service. What the push carries (the call and number) is sealed with a key only the two phones know;
  Apple sees that a push was sent, not who called.
- The Bonjour announcement carries a random installation id, nothing derived from the pairing code.
- Logs never contain phone numbers or message text.

## Repository layout

| Path | What |
|---|---|
| `android/app` | Kotlin app: SMS read/send, screenless `InCallService` next to the stock Phone app, Ktor WebSocket server, SMS and call history, push to APNs, ringer silencing, a status and pairing screen |
| `android/daemon` | C daemon (tinyalsa): call-audio capture and injection, UDP streaming, jitter buffer, device profiles, init service |
| `ios/CellBridge` | Swift app: control client, Bonjour, QR pairing, permissions and setup, CallKit, VoIP push, audio engine, recents, keypad, contacts, messages |
| `docs/protocol.md` | The single contract between both sides: change it first, then both implementations |
| `docs/` | Setup guides, push setup, device profiles, and the audio findings from the first spike (`spike-a-android-audio.md`, dated) |
| `tools/` | Mac-side helpers: control-channel test client, daemon self-test, daemon and APNs key installers |

## Building and testing

```
git submodule update --init                       # tinyalsa
cd android && ./gradlew :app:testDebugUnitTest    # Android unit tests
android/daemon/build.sh && android/daemon/tests/run.sh   # daemon (NDK) and its host-side tests
cd ios/CellBridge && xcodegen generate && xcodebuild test -project CellBridge.xcodeproj -scheme CellBridge \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

## License

Apache License 2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE). tinyalsa is BSD 3-Clause.
