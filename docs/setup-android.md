# Setting up the Android host

The reference device is a Xiaomi Mi 8 Lite ("platina") on LineageOS 22.2 (`userdebug`, unlocked bootloader). Other devices work
only with a profile for their audio hardware ([device-profiles.md](device-profiles.md)).

## 1. Build and install the app

Needs a JDK (17 or newer), the Android SDK with platform 37 (`android/local.properties` holds `sdk.dir=…`) and `adb`.

```
cd android
./gradlew :app:installDebug
```

The app is a single **Status** screen (is the iPhone connected, the address it can use, whether the call-audio daemon answers, whether the
iPhone can be woken by a push, the phone's battery, the SMS role). It has no keypad, call log or call screen: calls stay in the phone's stock Phone app.
The pairing code is hidden until you tap **Show**, which also shows a QR code for the iPhone to scan.

## 2. Roles and permissions

CellBridge does **not** take the dialer role: the stock Phone app keeps it and keeps showing calls. CellBridge watches them with an
`InCallService` that has no screen of its own. Four things are set once with `adb` (the first three are runtime permissions that the dialer role
used to bring along, so on a fresh install they must be given by hand):

```
adb shell appops set com.cellbridge MANAGE_ONGOING_CALLS allow          # without it Telecom never binds the screenless InCallService
adb shell pm grant com.cellbridge android.permission.CALL_PHONE          # place the iPhone's outgoing calls
adb shell pm grant com.cellbridge android.permission.READ_PHONE_STATE    # signal strength for the iPhone's status
adb shell cmd notification allow_dnd com.cellbridge                      # lets the app quieten the ringer while the iPhone rings
```

(`READ_CALL_LOG` is asked when the app opens.) The appop survives reinstalling the app; whether it survives a reboot is not verified. On the
reference phone `CALL_PHONE` and `READ_PHONE_STATE` were granted back when CellBridge held the dialer role; the commands above on a fresh
install are the documented way, not yet re-tried from scratch.

**Text messages** still go through CellBridge: tap **Request** next to "Default SMS app" and confirm (or
`adb shell cmd role add-role-holder --user 0 android.app.role.SMS com.cellbridge`). The phone then has no SMS screen of its own; texts are read on
the iPhone. Only the default SMS app may write the system SMS database. (Moving texts to the stock Messages app is planned.) To undo, hand the
role back (`… add-role-holder … com.android.messaging`; package names differ between ROMs).

**The ringer.** `TelecomManager.silenceRinger()` is reserved for the default dialer, so while a call also rings on the iPhone the app sets Do
Not Disturb to "alarms only" and puts the previous setting back when nothing rings. Without the `allow_dnd` access both phones ring (a call is
never lost). The phone rings for a second or two until the iPhone confirms. If the phone is ever left silent:
`adb shell cmd notification set_dnd off`.

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

The iPhone's Settings tab should say `Connected` with Calls · Texts · Voice, and the Android Status screen shows the iPhone as connected. Call the SIM from another
phone: the iPhone rings and the phone's own ringer goes quiet after a moment (it rings until the iPhone confirms).

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
| The iPhone never sees a call | the `MANAGE_ONGOING_CALLS` appop is missing (section 2) |
| Both phones keep ringing | no Do Not Disturb access (`allow_dnd`, section 2) |
| The phone stays silent after a call | `adb shell cmd notification set_dnd off` |
| Status says "No APNs key" / "waiting for the iPhone to register" | install the key (`tools/install-apns-key.sh`, [push.md](push.md)); open the iPhone app once so it registers |
| Far end hears choppy audio | see the statistics line the iPhone logs at the end of each call (Events, or `events.log`) |
