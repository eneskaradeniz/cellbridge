#include "log.h"
#include "profile.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static bool set_uint(const char *value, unsigned int *dst)
{
    char *end;
    unsigned long v = strtoul(value, &end, 10);
    if (end == value || *end != '\0')
        return false;
    *dst = (unsigned int)v;
    return true;
}

static bool set_str(const char *value, char *dst)
{
    if (strlen(value) >= PROFILE_STR_MAX)
        return false;
    strcpy(dst, value);
    return true;
}

static bool apply(struct profile *p, const char *key, const char *value)
{
    if (!strcmp(key, "card")) return set_uint(value, &p->card);
    if (!strcmp(key, "rate")) return set_uint(value, &p->rate);
    if (!strcmp(key, "channels")) return set_uint(value, &p->channels);
    if (!strcmp(key, "period_frames")) return set_uint(value, &p->period_frames);
    if (!strcmp(key, "dl_mixer")) return set_str(value, p->dl_mixer);
    if (!strcmp(key, "dl_pcm_device")) return set_uint(value, &p->dl_pcm_device);
    if (!strcmp(key, "dl_period_count")) return set_uint(value, &p->dl_period_count);
    if (!strcmp(key, "ul_mixer")) return set_str(value, p->ul_mixer);
    if (!strcmp(key, "ul_pcm_device")) return set_uint(value, &p->ul_pcm_device);
    if (!strcmp(key, "ul_period_count")) return set_uint(value, &p->ul_period_count);
    if (!strcmp(key, "mic_off_ctls")) return set_str(value, p->mic_off_ctls);
    if (!strcmp(key, "mic_off_value")) return set_str(value, p->mic_off_value);
    return false;
}

bool profile_load(const char *path, struct profile *out)
{
    FILE *f = fopen(path, "r");
    if (!f) {
        perror(path);
        return false;
    }

    memset(out, 0, sizeof(*out));
    char line[256];
    int lineno = 0;
    bool ok = true;
    while (ok && fgets(line, sizeof(line), f)) {
        lineno++;
        line[strcspn(line, "\r\n")] = '\0';
        if (line[0] == '\0' || line[0] == '#')
            continue;
        char *eq = strchr(line, '=');
        if (!eq) {
            daemon_log("%s:%d: expected key=value\n", path, lineno);
            ok = false;
            break;
        }
        *eq = '\0';
        if (!apply(out, line, eq + 1)) {
            daemon_log("%s:%d: bad key or value '%s'\n", path, lineno, line);
            ok = false;
        }
    }
    fclose(f);

    if (ok && (!out->rate || !out->channels || !out->period_frames || !out->dl_period_count || !out->ul_period_count ||
               !out->dl_mixer[0] || !out->ul_mixer[0])) {
        daemon_log("%s: missing required keys\n", path);
        ok = false;
    }
    return ok;
}
