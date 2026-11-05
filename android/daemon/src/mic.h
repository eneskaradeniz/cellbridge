#ifndef CELLBRIDGE_MIC_H
#define CELLBRIDGE_MIC_H

#include <tinyalsa/mixer.h>

#include "profile.h"

struct mic_guard;

/* Silences the phone's own microphone for the call (profile mic_off_ctls) so that only the injected uplink reaches
 * the far end. Telecom's mute cannot be used: it mutes the injected audio too. Returns NULL when the profile names no
 * controls or none could be changed. The previous values are saved to disk first. */
struct mic_guard *mic_mute(struct mixer *m, const struct profile *p);
/* The audio HAL rewrites these controls when the route changes (speaker, headset); this puts them back. Cheap. */
void mic_keep(struct mic_guard *g);
/* Puts the controls back as they were and removes the state file. Accepts NULL. */
void mic_restore(struct mic_guard *g);
/* At daemon start: undoes a mute left behind by a crash or kill. */
void mic_recover(const struct profile *p);

#endif
