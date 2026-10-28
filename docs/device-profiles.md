# Device profiles

A profile (`android/daemon/profiles/<name>.profile`) tells the audio daemon how to reach the call audio of one device:
`key=value` lines.

| Key | Meaning (reference value) |
|---|---|
| `card` | ALSA card (`0`) |
| `rate`, `channels` | PCM format of the stream the DSP exposes (`16000`, `1`; S16_LE) |
| `period_frames` | frames per period, which is also one network frame (`320` = 20 ms) |
| `dl_mixer` | mixer control that routes the **far end** (downlink) to a capture PCM (`MultiMedia1 Mixer VOC_REC_DL`) |
| `dl_pcm_device`, `dl_period_count` | the capture PCM device and its period count (`0`, `4`) |
| `ul_mixer` | mixer control that mixes a playback PCM into the **uplink** (`Incall_Music Audio Mixer MultiMedia2`) |
| `ul_pcm_device`, `ul_period_count` | the playback PCM device and its period count (`1`, `8`) |

## Finding the values on another phone

You need a rooted shell, [tinyalsa](https://github.com/tinyalsa/tinyalsa) tools (`tinymix`, `tinycap`, `tinyplay`, built with the NDK;
see the first spike notes in [spike-a-android-audio.md](spike-a-android-audio.md)) and **a live call**: the voice session only
exists then.

1. `cat /proc/asound/pcm` lists PCM devices; `tinymix contents` lists mixer controls. On Qualcomm devices look for controls containing
   `VOC_REC_DL` / `VOC_REC_UL` (record the call) and `Incall_Music` (inject into the call).
2. Far end: `tinymix set "<dl_mixer>" 1`, then `tinycap /data/local/tmp/dl.wav -D <card> -d <device> -c 1 -r 16000 -b 16 -t 10`
   during a call; the file should contain the other person's speech.
3. Uplink: `tinymix set "<ul_mixer>" 1`, then `tinyplay speech.wav -D <card> -d <device>`; the other person should hear it.
   Use **speech**, not a steady tone: the voice codec gates steady tones, which sounds like "dit dit dit".
4. **Set every mixer control back to `0`** afterwards.
5. Write the profile and check it with the daemon's own commands: `cellbridge_audiod <profile> capture out.raw 10` and
   `cellbridge_audiod <profile> inject in.raw` (raw 16 kHz S16_LE mono).

## Things that bit us

- The plain read/write path of the `msm-pcm-q6-v2` driver stopped working after ~36-39 calls regardless of period size; the daemon
  therefore uses `PCM_MMAP` for both directions. A different driver may need no such workaround.
- The CPU must not suspend during a call (the app holds a partial wake lock), otherwise the DSP feed stalls for 300-450 ms.
- 8 periods of 320 frames on the uplink were fine; 4 periods of 1024 frames were audibly choppy.

Tested devices: Xiaomi Mi 8 Lite ("platina") with LineageOS 22.2, circuit-switched voice. VoLTE / VoWiFi front ends are untested
(`VoLTE`, `VoWLAN` in the voice mixers). Send a profile together with the device name and ROM version if you get another phone working.
