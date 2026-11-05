#ifndef CELLBRIDGE_PROFILE_H
#define CELLBRIDGE_PROFILE_H

#include <stdbool.h>

#define PROFILE_STR_MAX 96

/* Device-specific audio routing, loaded from a key=value file (see profiles/). */
struct profile {
    unsigned int card;
    unsigned int rate;
    unsigned int channels;
    unsigned int period_frames;
    char dl_mixer[PROFILE_STR_MAX];
    unsigned int dl_pcm_device;
    unsigned int dl_period_count;
    char ul_mixer[PROFILE_STR_MAX];
    unsigned int ul_pcm_device;
    unsigned int ul_period_count;
    /* Optional: comma-separated enum controls that carry the phone's own microphone, and the value that silences them. */
    char mic_off_ctls[PROFILE_STR_MAX];
    char mic_off_value[PROFILE_STR_MAX];
};

/* Returns false and prints the reason to stderr if the file is unreadable or incomplete. */
bool profile_load(const char *path, struct profile *out);

#endif
