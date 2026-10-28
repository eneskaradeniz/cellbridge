#include "jitter.h"

#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

enum {
    SLOTS = 32,          /* power of two; also the largest sequence gap we bridge before resyncing */
    MIN_TARGET = 3,      /* 60 ms at 20 ms frames: below that a phone's Wi-Fi power saving (100 ms bursts) starves it */
    START_TARGET = 3,
    MAX_TARGET = 8,      /* 160 ms */
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
    struct jitter_stats stats;
};

struct jitter *jitter_create(unsigned frame_bytes)
{
    struct jitter *j = calloc(1, sizeof(*j));
    if (!j)
        return NULL;
    j->data = calloc(SLOTS, frame_bytes);
    if (!j->data) {
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

static void store(struct jitter *j, uint16_t seq, const void *frame)
{
    struct slot *s = &j->slots[seq % SLOTS];
    if (s->valid && s->seq == seq) {
        j->stats.duplicate++;
        return;
    }
    if (s->valid)
        j->buffered--; /* an old frame of a previous lap is overwritten */
    memcpy(j->data + (size_t)(seq % SLOTS) * j->frame_bytes, frame, j->frame_bytes);
    s->valid = true;
    s->seq = seq;
    j->buffered++;
}

void jitter_push(struct jitter *j, uint16_t seq, const void *frame)
{
    pthread_mutex_lock(&j->lock);
    if (!j->started) {
        if (j->buffered == 0 || distance(j->next, seq) < 0)
            j->next = seq; /* earliest sequence seen while priming */
        if (distance(j->next, seq) < SLOTS) {
            store(j, seq, frame);
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
        store(j, seq, frame);
    } else {
        store(j, seq, frame);
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
            s->valid = false;
            j->buffered--;
            j->stats.played++;
            if (++j->calm >= CALM_FRAMES_TO_SHRINK && j->target > MIN_TARGET) {
                j->target--;
                j->calm = 0;
            }
            result = JITTER_FRAME;
        } else {
            memset(out, 0, j->frame_bytes);
            j->stats.concealed++;
            result = JITTER_CONCEALED;
            if (j->buffered == 0) {
                /* Starved, not just a lost packet: re-prime with a deeper buffer. */
                j->started = false;
                if (j->target < MAX_TARGET)
                    j->target++;
                j->calm = 0;
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
