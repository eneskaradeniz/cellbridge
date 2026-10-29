#include "jitter.h"

#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

enum {
    SLOTS = 32,          /* power of two; also the largest sequence gap we bridge before resyncing */
    MIN_TARGET = 3,      /* 60 ms at 20 ms frames: below that a phone's Wi-Fi power saving (100 ms bursts) starves it */
    START_TARGET = 3,
    MAX_TARGET = 14,     /* 280 ms: Wi-Fi power saving was measured delivering audio after gaps of 260 ms */
    GROW_STEP = 2,       /* a starvation deepens the buffer by 40 ms */
    FADE_FRAMES = 3,     /* concealed frames that still repeat the last one, quieter each time */
    EXTRA_BEFORE_DROP = 10, /* frames allowed above target before the oldest are discarded: a burst after a gap must not be thrown away */
    CALM_FRAMES_TO_SHRINK = 250, /* 5 s */
};

struct slot {
    bool valid;
    uint16_t seq;
};

struct jitter {
    pthread_mutex_t lock;
    unsigned frame_bytes;
    unsigned char *data; /* SLOTS * frame_bytes */
    struct slot slots[SLOTS];

    bool started;
    uint16_t next; /* sequence number due for playout */
    unsigned buffered;
    unsigned target;
    unsigned calm;
    unsigned char *last; /* the last frame played, for concealment */
    bool have_last;
    unsigned lost_run;
    struct jitter_stats stats;
};

struct jitter *jitter_create(unsigned frame_bytes)
{
    struct jitter *j = calloc(1, sizeof(*j));
    if (!j)
        return NULL;
    j->data = calloc(SLOTS, frame_bytes);
    j->last = calloc(1, frame_bytes);
    if (!j->data || !j->last) {
        free(j->data);
        free(j->last);
        free(j);
        return NULL;
    }
    pthread_mutex_init(&j->lock, NULL);
    j->frame_bytes = frame_bytes;
    j->target = START_TARGET;
    return j;
}

void jitter_destroy(struct jitter *j)
{
    if (!j)
        return;
    pthread_mutex_destroy(&j->lock);
    free(j->data);
    free(j->last);
    free(j);
}

static void drop_all(struct jitter *j)
{
    memset(j->slots, 0, sizeof(j->slots));
    j->buffered = 0;
}

/* Signed distance from `from` to `to` on the wrapping sequence circle. */
static int distance(uint16_t from, uint16_t to)
{
    return (int16_t)(uint16_t)(to - from);
}

/* Returns false (and counts a duplicate unless `quiet`) when the frame is already held. */
static bool store(struct jitter *j, uint16_t seq, const void *frame, bool quiet)
{
    struct slot *s = &j->slots[seq % SLOTS];
    if (s->valid && s->seq == seq) {
        if (!quiet)
            j->stats.duplicate++;
        return false;
    }
    if (s->valid)
        j->buffered--; /* an old frame of a previous lap is overwritten */
    memcpy(j->data + (size_t)(seq % SLOTS) * j->frame_bytes, frame, j->frame_bytes);
    s->valid = true;
    s->seq = seq;
    j->buffered++;
    return true;
}

void jitter_push(struct jitter *j, uint16_t seq, const void *frame)
{
    pthread_mutex_lock(&j->lock);
    if (!j->started) {
        if (j->buffered == 0 || distance(j->next, seq) < 0)
            j->next = seq; /* earliest sequence seen while priming */
        if (distance(j->next, seq) < SLOTS) {
            store(j, seq, frame, false);
            if (j->buffered >= j->target)
                j->started = true;
        }
        pthread_mutex_unlock(&j->lock);
        return;
    }

    int d = distance(j->next, seq);
    if (d < 0) {
        j->stats.late++;
    } else if (d >= SLOTS) {
        /* The sender jumped far ahead (outage, restart): start over from here. */
        drop_all(j);
        j->started = false;
        j->stats.overflow++;
        j->next = seq;
        store(j, seq, frame, false);
    } else {
        store(j, seq, frame, false);
        /* Too far ahead of the playout clock: discard the oldest so latency stays bounded. */
        while (j->buffered > j->target + EXTRA_BEFORE_DROP) {
            struct slot *s = &j->slots[j->next % SLOTS];
            if (s->valid && s->seq == j->next) {
                s->valid = false;
                j->buffered--;
            }
            j->next++;
            j->stats.overflow++;
        }
    }
    pthread_mutex_unlock(&j->lock);
}

void jitter_push_redundant(struct jitter *j, uint16_t seq, const void *frame)
{
    pthread_mutex_lock(&j->lock);
    if (!j->started) {
        if (j->buffered == 0 || distance(j->next, seq) < 0)
            j->next = seq;
        if (distance(j->next, seq) < SLOTS) {
            store(j, seq, frame, true);
            if (j->buffered >= j->target)
                j->started = true;
        }
    } else {
        int d = distance(j->next, seq);
        /* Already played or concealed (d < 0), or implausibly far ahead: nothing to repair. */
        if (d >= 0 && d < SLOTS && store(j, seq, frame, true))
            j->stats.recovered++;
    }
    pthread_mutex_unlock(&j->lock);
}

/* The last played frame, quieter for each frame in a row that is missing: 3/4, 2/4, 1/4, then silence. */
static void conceal(struct jitter *j, void *out)
{
    if (!j->have_last || j->lost_run > FADE_FRAMES) {
        memset(out, 0, j->frame_bytes);
        return;
    }
    int gain = (int)(FADE_FRAMES + 1 - j->lost_run); /* out of 4 */
    for (unsigned i = 0; i + 1 < j->frame_bytes; i += 2) {
        int16_t v;
        memcpy(&v, j->last + i, sizeof(v));
        v = (int16_t)(v * gain / 4);
        memcpy((unsigned char *)out + i, &v, sizeof(v));
    }
}

enum jitter_result jitter_pop(struct jitter *j, void *out)
{
    enum jitter_result result;
    pthread_mutex_lock(&j->lock);
    if (!j->started) {
        memset(out, 0, j->frame_bytes);
        result = JITTER_PRIMING;
    } else {
        struct slot *s = &j->slots[j->next % SLOTS];
        if (s->valid && s->seq == j->next) {
            memcpy(out, j->data + (size_t)(j->next % SLOTS) * j->frame_bytes, j->frame_bytes);
            memcpy(j->last, out, j->frame_bytes);
            j->have_last = true;
            j->lost_run = 0;
            s->valid = false;
            j->buffered--;
            j->stats.played++;
            if (++j->calm >= CALM_FRAMES_TO_SHRINK && j->target > MIN_TARGET) {
                j->target--;
                j->calm = 0;
            }
            result = JITTER_FRAME;
        } else {
            j->lost_run++;
            conceal(j, out);
            j->stats.concealed++;
            result = JITTER_CONCEALED;
            if (j->buffered == 0) {
                /* Starved, not just a lost packet: re-prime with a deeper buffer. */
                j->started = false;
                j->target = j->target + GROW_STEP > MAX_TARGET ? MAX_TARGET : j->target + GROW_STEP;
                j->calm = 0;
                j->have_last = false; /* what follows the wait is not a continuation of that sound */
            }
        }
        j->next++;
    }
    pthread_mutex_unlock(&j->lock);
    return result;
}

void jitter_get_stats(struct jitter *j, struct jitter_stats *out)
{
    pthread_mutex_lock(&j->lock);
    *out = j->stats;
    out->target = j->target;
    pthread_mutex_unlock(&j->lock);
}
