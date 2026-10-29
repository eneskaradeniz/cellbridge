#ifndef CELLBRIDGE_JITTER_H
#define CELLBRIDGE_JITTER_H

#include <stdint.h>

/* Adaptive playout buffer for fixed-size audio frames numbered by a wrapping u16 sequence.
 * push() may run on a network thread while pop() runs on the playout thread. */
struct jitter;

enum jitter_result {
    JITTER_FRAME,     /* a real frame was copied out */
    JITTER_CONCEALED, /* the frame is missing: a faded repeat of the last one (or silence) was written */
    JITTER_PRIMING,   /* still filling up: silence was written */
};

struct jitter_stats {
    unsigned played, concealed, late, duplicate, overflow;
    unsigned recovered; /* frames that arrived only as the redundant copy in the next packet */
    unsigned target; /* current target depth in frames */
};

struct jitter *jitter_create(unsigned frame_bytes);
void jitter_destroy(struct jitter *j);

void jitter_push(struct jitter *j, uint16_t seq, const void *frame);

/* The previous frame carried along with a packet (docs/protocol.md): used only if that frame has not arrived, and never
 * counted as late or duplicate. */
void jitter_push_redundant(struct jitter *j, uint16_t seq, const void *frame);

/* Writes exactly frame_bytes to out. Call once per frame period. A missing frame repeats the last played one, fading out over
 * three frames and then silence, which sounds far less broken than a hole. frame_bytes must be even (16-bit samples). */
enum jitter_result jitter_pop(struct jitter *j, void *out);

void jitter_get_stats(struct jitter *j, struct jitter_stats *out);

#endif
