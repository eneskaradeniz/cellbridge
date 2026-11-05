#ifndef CELLBRIDGE_MIC_STATE_H
#define CELLBRIDGE_MIC_STATE_H

#include <stdbool.h>

#include "profile.h"

#define MIC_MAX 8

/* One mixer enum as it was before the daemon silenced the phone's own microphone. */
struct mic_entry {
    char name[PROFILE_STR_MAX];
    char value[PROFILE_STR_MAX];
};

/* The state file is written (and synced) BEFORE any control is changed, so a crash or kill -9 leaves the way back. */
bool mic_state_write(const char *path, const struct mic_entry *entries, unsigned int count);
/* Number of entries read; 0 if there is no file. */
unsigned int mic_state_read(const char *path, struct mic_entry *entries, unsigned int max);
void mic_state_clear(const char *path);

#endif
