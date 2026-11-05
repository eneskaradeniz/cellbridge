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
iPhone can be woken by a push, the phone's battery, the SMS permissions). It has no keypad, call log or call screen: calls stay in the phone's stock Phone app.
The pairing code is hidden until you tap **Show**, which also shows a QR code for the iPhone to scan.

## 2. Roles and permissions

CellBridge does **not** take the dialer role: the stock Phone app keeps it and keeps showing calls. CellBridge watches them with an
`InCallService` that has no screen of its own. Four things are set once with `adb` (the first three are runtime permissions that the dialer role
used to bring along; the app asks for them itself, the commands skip the dialog):

```
adb shell appops set com.cellbridge MANAGE_ONGOING_CALLS allow          # without it Telecom never binds the screenless InCallService
adb shell pm grant com.cellbridge android.permission.CALL_PHONE          # place the iPhone's outgoing calls
adb shell pm grant com.cellbridge android.permission.READ_PHONE_STATE    # signal strength for the iPhone's status
adb shell cmd notification allow_dnd com.cellbridge                      # lets the app quieten the ringer while the iPhone rings
```

(The app asks for all three, and for the call log, when it opens, so the `pm grant` lines are only needed for a headless setup.) The appop survives reinstalling the app and a reboot. On the
reference phone `CALL_PHONE` and `READ_PHONE_STATE` were granted back when CellBridge held the dialer role; the commands above on a fresh
install are the documented way, not yet re-tried from scratch.

**Text messages** stay in the phone's stock Messages app, which keeps the default SMS role (the role is **not** given to CellBridge). CellBridge
reads the SMS database and sends as a plain app: tap **Request** next to "Text messages" on the Status screen (or
`adb shell pm grant com.cellbridge android.permission.READ_SMS`, `…SEND_SMS`, `…RECEIVE_SMS`; sideloaded builds installed with `adb install` are not
restricted). Received texts are stored by Messages and announced by watching the inbox. Only the default SMS app may write the database, so a text
the iPhone sends is filed in the sent box by the root daemon (`SAVE_SENT`, section 4) and then shows in the Messages thread on the phone as well.
Without the daemon the iPhone's texts still go out but the phone's Messages app does not show them. If CellBridge held the SMS role before
(an older version), hand it back: `adb shell cmd role add-role-holder --user 0 android.app.role.SMS com.android.messaging` (package names differ between ROMs).

**The ringer.** `TelecomManager.silenceRinger()` is reserved for the default dialer, so while a call also rings on the iPhone the app sets Do
Not Disturb to "alarms only" and puts the previous setting back when nothing rings. Without the `allow_dnd` access both phones ring (a call is
never lost). The phone rings for a second or two until the iPhone confirms. If the phone is ever left silent:
`adb shell cmd notification set_dnd off`.

**The hotspot.** Away from the home Wi-Fi the iPhone has nothing to join, so the app asks the root daemon (section 4) to switch the phone's
hotspot on 30 seconds after the Wi-Fi is lost, and off again when a home network is joined. **Home Wi-Fi is any network saved on the phone**: forget
the ones that are not home (Settings → Wi-Fi). The hotspot uses the name and password already set in Android's hotspot settings (WPA2 only).
A hotspot you switched on by hand is never switched off by the app; the **Hotspot** switch on the Status screen turns the feature off.
Needs the daemon from this version (the hotspot messages are in docs/protocol.md).

## 3. Network prerequisites

- `adb shell settings get global restricted_networking_mode` must print `0`. With `1` (a "restricted networking mode" some
  builds switch on) **every app is cut off from the network, loopback included**: the server logs `Responding at …` and
  listens, yet no request is ever answered. Fix: `adb shell settings put global restricted_networking_mode 0`.
- The server runs in a foreground service (a notification says so). A background app loses its network when the screen turns off.
- Away from home the hotspot comes on by itself (section 2); connect the iPhone to it once and it joins by itself afterwards. If the daemon is not running, switch the hotspot on by hand.

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
adb root && adb shell content insert --uri content://sms/inbox --bind address:s:+905550000000 --bind body:s:hello --bind date:l:"$(date +%s)000" --bind read:i:0 --bind type:i:1
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
| iPhone shows no `sms` | the app lacks the SMS permissions (Status screen → Request) |
| A text sent from the iPhone is missing in the phone's Messages app | the daemon is not the current build (`SAVE_SENT`, section 4) |
| The iPhone never sees a call | the `MANAGE_ONGOING_CALLS` appop is missing (section 2) |
| Both phones keep ringing | no Do Not Disturb access (`allow_dnd`, section 2) |
| The hotspot does not come on when I leave home | the daemon is not the current build (section 4), the phone is still joined to a saved network, or the **Hotspot** switch is off |
| The phone stays silent after a call | `adb shell cmd notification set_dnd off` |
| Status says "No APNs key" / "waiting for the iPhone to register" | install the key (`tools/install-apns-key.sh`, [push.md](push.md)); open the iPhone app once so it registers |
| Far end hears choppy audio | see the statistics line the iPhone logs at the end of each call (Events, or `events.log`) |
