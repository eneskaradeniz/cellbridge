# Mi 8 Lite (platina), LineageOS 22.2, CS voice. See docs/spike-a-android-audio.md.
card=0
rate=16000
channels=1
period_frames=320
dl_mixer=MultiMedia1 Mixer VOC_REC_DL
dl_pcm_device=0
dl_period_count=4
ul_mixer=Incall_Music Audio Mixer MultiMedia2
ul_pcm_device=1
# UL needs 8 periods: 1024x4 was audibly choppy on the far end (docs/spike-a-android-audio.md).
ul_period_count=8
# The phone's own microphone (capture decimators) is silenced while the iPhone speaks: Telecom's mute would also mute the
# injected uplink, and the voice Tx/Rx device mutes have no effect on VoLTE (measured, docs/spike-a-android-audio.md).
mic_off_ctls=DEC1 MUX,DEC2 MUX,DEC3 MUX,DEC4 MUX,DEC5 MUX
mic_off_value=ZERO
