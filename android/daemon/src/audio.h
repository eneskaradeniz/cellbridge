#ifndef CELLBRIDGE_AUDIO_H
#define CELLBRIDGE_AUDIO_H

#include "profile.h"

struct audio;

/* Route and open the downlink capture (far end -> us) and/or uplink inject (us -> far end) PCMs.
 * Mixer routes are enabled on open and always switched back off by audio_close(). */
struct audio *audio_open(const struct profile *p, bool capture_dl, bool inject_ul);
void audio_close(struct audio *a);

/* Blocking, one period each. Return 0 on success, -1 on error (after attempting xrun recovery). */
int audio_read_dl(struct audio *a, void *buf);
int audio_write_ul(struct audio *a, const void *buf);

/* Re-silences the phone's microphone if the audio HAL switched it back on (call from the streaming loop, about once a second). */
void audio_keep_mic_off(struct audio *a);

/* Bytes in one period (profile.period_frames * channels * 2). */
unsigned int audio_period_bytes(const struct audio *a);

#endif
