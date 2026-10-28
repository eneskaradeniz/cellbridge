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
| Incoming calls: rings on the lock screen (CallKit), answer / decline / hang up from the iPhone, two-way audio | working |
| Outgoing calls from the iPhone (keypad, recents, in-call screen), refusal of emergency numbers and `*`/`#` service codes | working |
| SMS: receive (lossless: nothing is lost while the iPhone is offline), send, long texts (multipart), notifications | working |
| Call history on the iPhone; call screen on the Android phone itself | working |
| Starts by itself: server after boot, audio daemon from `init` | working (see limitations) |
| MMS, DTMF tones, conference / second call, contacts, voicemail | not supported |

## Requirements

- **Android host:** a rooted, Qualcomm-based phone whose DSP exposes the voice record / incall-music mixer controls
  (reference: **Xiaomi Mi 8 Lite "platina", LineageOS 22.2, Android 15, `userdebug`**), a SIM, Android 10+ (minSdk 29).
  Without root the app still handles calls and SMS but **call audio cannot be bridged** (the host then advertises no `audio`).
- **iPhone:** iOS 17+, Xcode, an Apple ID. With a free Apple ID the app expires after **7 days** and must be reinstalled.
- Both phones on the same Wi-Fi (the Android phone's hotspot works well).

## Quick start

1. [docs/setup-android.md](docs/setup-android.md): install the app, give it the default phone / SMS roles, start the audio daemon.
2. [docs/setup-ios.md](docs/setup-ios.md): build and install the iPhone app, enter the pairing code shown on the Android phone.

## Known limitations

- After an Android reboot the **hotspot must be switched on by hand**, and with a screen lock the phone must be **unlocked once**
  before the app's server starts (Android keeps app data encrypted until then). Removing the screen lock avoids the second one.
- The installed daemon service lives in `/system` and is **removed by a ROM update**; run the install script again afterwards.
- One call at a time. End-to-end audio latency has not been measured yet; the adaptive jitter buffers (40-140 ms) on both sides add to the network delay.
- iPhone background behaviour relies on a silent audio session to keep the connection alive; battery impact is not yet measured.

## Security notes

- Pairing uses an 8-character code from a 32-symbol alphabet shown on the Android phone (about 40 bits; wrong attempts are delayed).
  It is **not strong against a determined attacker on the same network**.
- The control channel and the audio are **not encrypted**. Use a network you control, such as your own phone's WPA2/WPA3 hotspot.
- The audio daemon listens on `127.0.0.1` only and authenticates the app with the same code, read from a file only the app and root can read.
- Emergency numbers are never dialed through the bridge, and neither are `*`/`#` service codes.
- Logs never contain phone numbers or message text.

## Repository layout

| Path | What |
|---|---|
| `android/app` | Kotlin app: default dialer / SMS role, `InCallService`, Ktor WebSocket server, SMS store, call screen |
| `android/daemon` | C daemon (tinyalsa): call-audio capture and injection, UDP streaming, jitter buffer, device profiles, init service |
| `ios/CellBridge` | Swift app: control client, CallKit, audio engine, recents, keypad, messages |
| `docs/protocol.md` | The single contract between both sides: change it first, then both implementations |
| `docs/` | Setup guides, device profiles, and the audio findings from the first spike |
| `tools/` | Mac-side test helpers |

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
