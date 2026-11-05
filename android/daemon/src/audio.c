#include "log.h"
#include "audio.h"
#include "mic.h"

#include <stdio.h>
#include <stdlib.h>

#include <tinyalsa/asoundlib.h>

struct audio {
    struct profile p;
    struct mixer *mixer;
    struct mixer_ctl *dl_ctl;
    struct mixer_ctl *ul_ctl;
    struct pcm *dl;
    struct pcm *ul;
    struct mic_guard *mic;
};

static struct mixer_ctl *route_on(struct mixer *m, const char *name)
{
    struct mixer_ctl *ctl = mixer_get_ctl_by_name(m, name);
    if (!ctl) {
        daemon_log("mixer control not found: %s\n", name);
        return NULL;
    }
    if (mixer_ctl_set_value(ctl, 0, 1) != 0) {
        daemon_log("cannot enable mixer control: %s\n", name);
        return NULL;
    }
    return ctl;
}

static struct pcm *open_pcm(const struct profile *p, unsigned int device, unsigned int period_count,
                            unsigned int flags)
{
    struct pcm_config cfg = {
        .channels = p->channels,
        .rate = p->rate,
        .period_size = p->period_frames,
        .period_count = period_count,
        .format = PCM_FORMAT_S16_LE,
    };
    struct pcm *pcm = pcm_open(p->card, device, flags, &cfg);
    if (!pcm || !pcm_is_ready(pcm)) {
        daemon_log("pcm %u/%u open failed: %s\n", p->card, device, pcm ? pcm_get_error(pcm) : "alloc");
        if (pcm)
            pcm_close(pcm);
        return NULL;
    }
    return pcm;
}

struct audio *audio_open(const struct profile *p, bool capture_dl, bool inject_ul)
{
    struct audio *a = calloc(1, sizeof(*a));
    if (!a)
        return NULL;
    a->p = *p;

    a->mixer = mixer_open(p->card);
    if (!a->mixer) {
        daemon_log("mixer_open(%u) failed\n", p->card);
        goto fail;
    }
    if (capture_dl) {
        a->dl_ctl = route_on(a->mixer, p->dl_mixer);
        a->dl = a->dl_ctl ? open_pcm(p, p->dl_pcm_device, p->dl_period_count, PCM_IN | PCM_MMAP) : NULL;
        if (!a->dl)
            goto fail;
    }
    if (inject_ul) {
        a->ul_ctl = route_on(a->mixer, p->ul_mixer);
        a->ul = a->ul_ctl ? open_pcm(p, p->ul_pcm_device, p->ul_period_count, PCM_OUT | PCM_MMAP) : NULL;
        if (!a->ul)
            goto fail;
        /* The iPhone speaks now: the phone's own microphone must not add the room to the call. */
        a->mic = mic_mute(a->mixer, p);
    }
    return a;

fail:
    audio_close(a);
    return NULL;
}

void audio_close(struct audio *a)
{
    if (!a)
        return;
    mic_restore(a->mic); /* first: the microphone comes back even if closing the PCMs stalls */
    if (a->dl)
        pcm_close(a->dl);
    if (a->ul)
        pcm_close(a->ul);
    /* Leave the routes off no matter how we got here (CLAUDE.md: reset mixers after use). */
    if (a->dl_ctl)
        mixer_ctl_set_value(a->dl_ctl, 0, 0);
    if (a->ul_ctl)
        mixer_ctl_set_value(a->ul_ctl, 0, 0);
    if (a->mixer)
        mixer_close(a->mixer);
    free(a);
}

unsigned int audio_period_bytes(const struct audio *a)
{
    return a->p.period_frames * a->p.channels * 2;
}

int audio_read_dl(struct audio *a, void *buf)
{
    if (pcm_readi(a->dl, buf, a->p.period_frames) >= 0)
        return 0;
    static bool reported;
    if (!reported) {
        daemon_log("dl read failed: %s\n", pcm_get_error(a->dl));
        reported = true;
    }
    /* Overrun: re-arm the stream so the next call can succeed. */
    if (pcm_prepare(a->dl) == 0)
        pcm_start(a->dl);
    return -1;
}

int audio_write_ul(struct audio *a, const void *buf)
{
    if (pcm_writei(a->ul, buf, a->p.period_frames) >= 0)
        return 0;
    /* Underrun: re-arm so the next write restarts the stream. */
    pcm_prepare(a->ul);
    return -1;
}

void audio_keep_mic_off(struct audio *a)
{
    mic_keep(a->mic);
}
