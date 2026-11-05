# Spike A — Android call audio (Mi 8 Lite, 2026-10-27)

Device: Mi 8 Lite (platina), LineageOS 22.2 / Android 15, `userdebug`, SDM660, SELinux enforcing, `adb root` works.
Call type during test: CS voice (HSPA). PCM 2 (`VoiceMMode1`) is the live voice stream.

## Result: PASS (both directions)

| Direction | Mechanism | Verified |
|---|---|---|
| Far end -> us (downlink) | `MultiMedia1 Mixer VOC_REC_DL`=1, then `tinycap /path.wav -D 0 -d 0 -c 1 -r 16000 -b 16 -t N` | Speech bursts in capture (RMS ~700-1100 vs noise floor ~25). `VOC_REC_UL` (own mic) also exists. |
| Us -> far end (inject) | `Incall_Music Audio Mixer MultiMedia2`=1, then `tinyplay file.wav -D 0 -d 1` | Caller heard the 440 Hz tone. |

Reset both controls to 0 after use.

## Findings
- `audio_policy_configuration.xml` has only `voice_tx` / `voice_rx` mixPorts, no `incall_music_uplink` output -> no AudioTrack route. Plan: root native daemon using tinyalsa.
- No tinyalsa tools on the device. Built tinyalsa **v2.0.0** with NDK 28 (`aarch64-linux-android30-clang`, `-Iinclude -Isrc utils/<tool>.c src/*.c -ldl`), pushed to `/data/local/tmp/ts/`.
- `tinyplay` reported "2 ch, 48000 hz" for a 1 ch / 16 kHz wav, yet the tone was heard. Capture/inject PCM params (rate, channels, period size) still need to be pinned down in the daemon.
- First DL capture was all zeros; later ones had speech. Cause not isolated (far end silent vs. route timing). Re-verify in the daemon with continuous far-end audio.
- `VOC_REC_DL` and `VOC_REC_UL` toggled on one `MultiMedia1` front end; the values read back as `On, Off` (first value is the one set).

## M1 findings (daemon, live CS call, 2026-10-27)
- **Use `PCM_MMAP` for both directions.** The plain read/write ioctl path of the `msm-pcm-q6-v2` driver breaks after ~36-39 calls regardless of
  period size (DL: `msm_pcm_capture_copy: Invalid dsp buf offset`, EFAULT; UL: writes fill the buffer, then DSP stops consuming,
  `msm_pcm_playback_copy: wait_event_timeout failed`, process stuck in `D` state until the mixer route is set to 0).
  With mmap: DL 20 s / 1000 periods and UL 400 periods, zero errors. Reproduces without a call too, so it is not a voice-session issue.
- **Working config:** 16 kHz, mono, S16_LE, period 320 frames (20 ms). DL 4 periods, UL 8 periods (UL 1024x4 was audibly choppy; 2048x4 and 320x8 were fine).
- **The CPU must not suspend during a call.** Without a wakelock the DSP feed stalls 300-450 ms (writes block, speech has 80-160 ms holes:
  7/114 loud frames missing in the `VOC_REC_UL` capture). With a wakelock: max write 21-43 ms, 0 holes. The Android app must hold
  a `PARTIAL_WAKE_LOCK` while a call is active (not the daemon: a sysfs wakelock leaks if the daemon is killed).
- **Test signals:** a steady sine is gated by the voice codec / noise suppression ("dit dit dit"); judge quality with speech
  (`say -v Yelda ... ; afconvert -d LEI16@16000 -c 1`), not tones.
- **Loopback check without the far end:** `VOC_REC_UL` (same front end as `VOC_REC_DL`) records the uplink including injected audio,
  so injection can be inspected locally by comparing 20 ms RMS envelopes.
- The `adb shell` user is already root (`adb root`); the device has no `su`, so an app cannot start the daemon itself.

## Network prerequisites (found while verifying the control server, 2026-10-28)
- **`settings get global restricted_networking_mode` must be `0`.** With `1` every app UID is blocked (`dumpsys netpolicy` shows
  `blocked=RESTRICTED_MODE`), loopback included: a plain `ServerSocket` never accepted a connection and the app could not connect out either.
  Symptom: the server logs "Responding" and listens, but requests hang. Fix: `adb shell settings put global restricted_networking_mode 0`.
- **The app must be a foreground process.** With the screen off (`Dozing`) the app is `blocked=APP_BACKGROUND` and incoming TCP is dropped.
  Reachable with the app in the foreground (`curl http://<phone>:8765/` answers 400, the expected reply to a non-WebSocket request).
  The control server therefore has to live in a foreground service (step 3b).

## Open questions
- VoLTE / VoWiFi calls may use other voice front ends (`VoLTE`, `VoWLAN` in `PRI_RX_Voice Mixer`); only CS voice tested.
- Mute own mic (`setMicrophoneMute` / `Voice Tx Mute`) while injecting, to avoid mixing room sound into the call.
- SELinux: tests ran as root via adb; the daemon must run from a Magisk/init context that may open `/dev/snd`.

## Findings 2026-11-05: phone microphone, earpiece, Telecom mute (VoLTE call, platina)
- **Telecom's `setMuted` (Voice Tx Mute) mutes the injected uplink too**: with the phone muted nothing of the iPhone's voice reaches the far end. Not usable while relaying.
- **`Voice Tx Device Mute` / `Voice Rx Device Mute` have no effect** on a VoLTE call (tried with the CS, VOICE2, VoLTE and VoWLAN session ids, `[1, 0, vsid]`). `tinymix` cannot write them at all (range `0..-1` is rejected); `mixer_ctl_set_array` (`android/daemon/tools/mixer_set.c`) can, but their value reads back as `-1`.
- **What works for the microphone:** the capture decimators. During a call `DEC1 MUX=ADC1`, `DEC2 MUX=ADC2` (the others `ZERO`, and all `ZERO` when idle; the audio HAL rewrites them on every call and route change). Setting them to `ZERO` silences the phone's own microphone while the injected iPhone voice still reaches the far end. The daemon does this on `audio_open` (profile `mic_off_ctls`), re-asserts it about once a second, and restores on close.
- **Crash safety of that:** the previous values are written (and synced) to `/data/local/tmp/cellbridge_mic.state` BEFORE any control is changed; the daemon undoes a leftover state file at start (`mic: undid a leftover mute`). Even without that, the HAL sets the controls again at the next call.
- **Earpiece:** the relay taps the call before the volume stage (`VOC_REC_DL`), so the call volume can be turned down without the iPhone noticing. The lowest level is `1` (range `[1..15]`, `0` is ignored): a faint sound stays. The app saves the level, lowers it while the relay runs and restores it on every way out (`VoiceVolumeLock`), including the next start of the app after a crash.
- **Daemon dying mid-call:** init restarts it; `AudioDaemonClient` notices the dropped socket and starts the relay again for the same peer for up to 10 s, then gives up and lets go of the volume and the Wi-Fi lock.

## Findings 2026-11-05: ringback and other call tones (VoLTE, platina)
- **The ringback tone is made by the phone, not by the network.** Telecom log: `EVENT_RINGBACK_TONE, playTone = true` -> `RingbackPlayer: Playing the ringback tone` -> `InCallTonePlayer: playToneGeneratorTone` (stopped by `playTone = false`). A `ToneGenerator` plays it on the phone's own output, so `VOC_REC_DL` is digital silence for the whole ringing time (measured: rms 0 for ~19 s, then the operator's "busy" announcement, which IS in-band, at rms ~3000).
- During the ringback the running playback streams are `pcm13p` (MultiMedia5: the tone), `pcm1p` (MultiMedia2: our uplink injection) and `pcm2p` (VoiceMMode1).
- **Capturing that stream with the AFE proxy does not work here.** `AFE_PCM_RX Audio Mixer MultiMedia5` plus a capture on `AFE-PROXY TX` (pcm 7, 48 kHz stereo) opens and reads but returns zeros while `tinyplay` plays a tone into pcm 13; the `afe-proxy` path in `/vendor/etc/mixer_paths.xml` is empty, so the ROM has no recipe for it. Capturing on a MultiMedia FE with `MultiMediaN Mixer AFE_PCM_TX` fails (`Error capturing sample`).
- Not tried: REMOTE_SUBMIX (voice-call strategy is not duplicated to the submix on stock policy, and it needs privileged routing).
