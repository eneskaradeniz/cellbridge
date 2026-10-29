# Setting up the Android host

The reference device is a Xiaomi Mi 8 Lite ("platina") on LineageOS 22.2 (`userdebug`, unlocked bootloader). Other devices work
only with a profile for their audio hardware ([device-profiles.md](device-profiles.md)).

## 1. Build and install the app

Needs a JDK (17 or newer), the Android SDK with platform 37 (`android/local.properties` holds `sdk.dir=…`) and `adb`.

```
cd android
./gradlew :app:installDebug
```

The app opens on a **Status** tab (is the iPhone connected, the address it can use, whether the call-audio daemon answers, the phone's battery, the
roles) with two more tabs: **Keypad** and **Recents**. The pairing code is hidden until you tap **Show**, which also shows a QR code for the iPhone to scan.

## 2. Give the app the default phone and SMS roles

Tap **Request** next to "Default phone app" and "Default SMS app" and confirm each system dialog (or use
`adb shell cmd role add-role-holder --user 0 android.app.role.DIALER com.cellbridge`, same with `…SMS`).

Consequences: the phone's own dialer and messaging apps are no longer the defaults. CellBridge has a keypad, a call log and a call screen
(answer, decline, end, mute, speaker, keypad tones, move to the iPhone) but **no SMS screen**; texts are read on the iPhone. Only the default
SMS app may write the system SMS database, which is why the SMS role is needed. To undo, hand the roles back
(`… add-role-holder … com.android.dialer` / `com.android.messaging`; package names differ between ROMs).

## 3. Network prerequisites

- `adb shell settings get global restricted_networking_mode` must print `0`. With `1` (a "restricted networking mode" some
  builds switch on) **every app is cut off from the network, loopback included**: the server logs `Responding at …` and
  listens, yet no request is ever answered. Fix: `adb shell settings put global restricted_networking_mode 0`.
- The server runs in a foreground service (a notification says so). A background app loses its network when the screen turns off.
- Switch the **hotspot on** and connect the iPhone to it. After an Android reboot the hotspot has to be switched on again by hand.

## 4. The root audio daemon (call audio)

Skip this to run in calls-and-SMS-only mode; the iPhone then shows `Connected (calls, sms)` and calls have no audio.

Build (Android NDK 28 required, tinyalsa is a git submodule):

```
git submodule update --init
ANDROID_NDK_HOME=<path to ndk 28.2.13676358> android/daemon/build.sh      # build/cellbridge_audiod
```

**Run it by hand** (needs `adb root`, i.e. a `userdebug` build or a root shell):

```
adb root
adb push android/daemon/build/cellbridge_audiod android/daemon/profiles/platina.profile /data/local/tmp/
adb shell "cd /data/local/tmp && chmod +x cellbridge_audiod && ./cellbridge_audiod platina.profile serve @/data/data/com.cellbridge/files/daemon.token &"
```

The daemon reads the pairing code from that file (written by the app) on every connection, so it needs no secret on its command line.

**Start it at every boot** (a **permanent change to `/system`**, userdebug with unlocked bootloader only):

```
tools/install-daemon-system.sh install      # reboots the phone twice
tools/install-daemon-system.sh uninstall    # removes the three files again
```

It adds `/system/bin/cellbridge_audiod`, `/system/etc/init/cellbridge_audiod.rc` and `/system/etc/cellbridge/<profile>.profile`
through an overlay remount. It tries `adb disable-verity` first; on ROMs without an AVB header in `vbmeta` (this one) that fails
harmlessly. A ROM update replaces `/system` and drops the service: run the script again. On a Magisk device, run the same command
from a `service.sh` module instead (not tested).

## 5. Check

The iPhone's Settings tab should say `Connected` with Calls · Texts · Voice, and the Android Status tab shows the iPhone as connected. Call the SIM from another
phone: the iPhone rings and the phone stays silent.

## Limits worth knowing

- After a reboot with a **screen lock**, nothing of the app starts until the phone is unlocked once (Android keeps app data
  encrypted until then). The daemon itself starts earlier; it simply refuses everyone until the token file is readable.
- The app holds a partial wake lock during calls (without it the CPU suspends and the audio stalls for 300-450 ms).

## Testing without a second phone (debug builds only)

Debug builds contain a fake telephony account. It makes calls and texts appear without the network:

```
adb shell am broadcast -n com.cellbridge/.debug.FakeCallReceiver -a com.cellbridge.debug.REGISTER_ACCOUNT
adb shell telecom set-phone-account-enabled com.cellbridge/com.cellbridge.debug.FakeCallService fake 0
adb shell am broadcast -n com.cellbridge/.debug.FakeCallReceiver -a com.cellbridge.debug.INCOMING_CALL     # rings
adb shell am broadcast -n com.cellbridge/.debug.FakeCallReceiver -a com.cellbridge.debug.REMOTE_HANGUP     # caller hangs up
adb shell am broadcast -n com.cellbridge/.debug.FakeSmsReceiver -a com.cellbridge.debug.INCOMING_SMS --es from +905550000000 --es body hello
```

For fake **outgoing** calls make the fake account the default outgoing one, and **put the SIM back afterwards**: read the current
value with `adb shell dumpsys telecom | grep defaultOutgoing`, then
`adb shell telecom set-user-selected-outgoing-phone-account com.cellbridge/com.cellbridge.debug.FakeCallService fake 0`
and, when done, the same command with the original component, id and user (on the reference phone:
`com.android.phone/com.android.services.telephony.TelephonyConnectionService 1 0`). Remove the account with
`telecom unregister-phone-account … fake 0`.

**Careful:** answering a fake text from the iPhone sends a **real** SMS to that (fake) number.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Server listens but nothing answers; iPhone says "Could not connect" or times out | `restricted_networking_mode` is `1` (above), or the hotspot is off |
| Works with the screen on, silent with the screen off | the app is not running its foreground service (start the app once; check the notification) |
| iPhone shows `Connected (calls)` without `audio` | daemon not running or token file unreadable; check `adb shell pidof cellbridge_audiod` |
| iPhone shows no `sms` | the app is not the default SMS app |
| Far end hears choppy audio | see the statistics line the iPhone logs at the end of each call (Events, or `events.log`) |
