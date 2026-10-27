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

## Open questions
- VoLTE / VoWiFi calls may use other voice front ends (`VoLTE`, `VoWLAN` in `PRI_RX_Voice Mixer`); only CS voice tested.
- Mute own mic (`setMicrophoneMute` / `Voice Tx Mute`) while injecting, to avoid mixing room sound into the call.
- SELinux: tests ran as root via adb; the daemon must run from a Magisk/init context that may open `/dev/snd`.
