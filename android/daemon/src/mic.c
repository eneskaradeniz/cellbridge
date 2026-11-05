#include "log.h"
#include "mic.h"
#include "mic_state.h"

#include <stdlib.h>
#include <string.h>

struct mic_guard {
    struct mixer *mixer;
    char off_value[PROFILE_STR_MAX];
    unsigned int count;
    struct mixer_ctl *ctl[MIC_MAX];
    struct mic_entry saved[MIC_MAX];
};

static const char *state_path(void)
{
    const char *p = getenv("CELLBRIDGE_MIC_STATE");
    return p && *p ? p : "/data/local/tmp/cellbridge_mic.state";
}

static const char *current(struct mixer_ctl *c)
{
    int idx = mixer_ctl_get_value(c, 0);
    return idx < 0 ? NULL : mixer_ctl_get_enum_string(c, (unsigned int)idx);
}

struct mic_guard *mic_mute(struct mixer *m, const struct profile *p)
{
    if (!p->mic_off_ctls[0])
        return NULL;
    const char *off = p->mic_off_value[0] ? p->mic_off_value : "ZERO";
    struct mic_guard *g = calloc(1, sizeof(*g));
    if (!g)
        return NULL;
    g->mixer = m;
    strcpy(g->off_value, off);

    char list[PROFILE_STR_MAX];
    strcpy(list, p->mic_off_ctls);
    for (char *name = strtok(list, ","); name && g->count < MIC_MAX; name = strtok(NULL, ",")) {
        struct mixer_ctl *c = mixer_get_ctl_by_name(m, name);
        const char *now = c && mixer_ctl_get_type(c) == MIXER_CTL_TYPE_ENUM ? current(c) : NULL;
        if (!now) {
            daemon_log("mic: control '%s' missing or not an enum, skipped\n", name);
            continue;
        }
        if (!strcmp(now, off))
            continue; /* already off: nothing to save or restore */
        g->ctl[g->count] = c;
        snprintf(g->saved[g->count].name, PROFILE_STR_MAX, "%s", name);
        snprintf(g->saved[g->count].value, PROFILE_STR_MAX, "%s", now);
        g->count++;
    }
    if (!g->count) {
        free(g);
        return NULL;
    }
    /* Write-ahead: if this fails we do not touch the microphone at all. */
    if (!mic_state_write(state_path(), g->saved, g->count)) {
        daemon_log("mic: cannot save the previous state, the phone microphone stays on\n");
        free(g);
        return NULL;
    }
    for (unsigned int i = 0; i < g->count; i++)
        if (mixer_ctl_set_enum_by_string(g->ctl[i], off) != 0)
            daemon_log("mic: cannot set '%s' to %s\n", g->saved[i].name, off);
    daemon_log("mic: silenced %u control(s)\n", g->count);
    return g;
}

void mic_keep(struct mic_guard *g)
{
    if (!g)
        return;
    for (unsigned int i = 0; i < g->count; i++) {
        const char *now = current(g->ctl[i]);
        if (now && strcmp(now, g->off_value) != 0) {
            daemon_log("mic: '%s' was switched back to %s, silenced again\n", g->saved[i].name, now);
            mixer_ctl_set_enum_by_string(g->ctl[i], g->off_value);
        }
    }
}

void mic_restore(struct mic_guard *g)
{
    if (!g)
        return;
    for (unsigned int i = 0; i < g->count; i++)
        if (mixer_ctl_set_enum_by_string(g->ctl[i], g->saved[i].value) != 0)
            daemon_log("mic: cannot restore '%s' to %s\n", g->saved[i].name, g->saved[i].value);
    mic_state_clear(state_path());
    daemon_log("mic: restored %u control(s)\n", g->count);
    free(g);
}

void mic_recover(const struct profile *p)
{
    struct mic_entry e[MIC_MAX];
    unsigned int n = mic_state_read(state_path(), e, MIC_MAX);
    if (!n)
        return;
    struct mixer *m = mixer_open(p->card);
    if (!m) {
        daemon_log("mic: cannot open the mixer to undo a leftover mute\n");
        return; /* the state file stays for the next start */
    }
    for (unsigned int i = 0; i < n; i++) {
        struct mixer_ctl *c = mixer_get_ctl_by_name(m, e[i].name);
        if (c)
            mixer_ctl_set_enum_by_string(c, e[i].value);
    }
    mixer_close(m);
    mic_state_clear(state_path());
    daemon_log("mic: undid a leftover mute of %u control(s)\n", n);
}
