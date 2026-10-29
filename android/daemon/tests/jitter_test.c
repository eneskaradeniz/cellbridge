/* Host-side unit tests for the jitter buffer: tests/run.sh */
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "jitter.h"

#define FRAME 8

static void push(struct jitter *j, uint16_t seq)
{
    unsigned char f[FRAME];
    memset(f, (int)(seq & 0xff) | 1, FRAME); /* non-zero, distinguishable from concealment */
    jitter_push(j, seq, f);
}

static enum jitter_result pop(struct jitter *j, unsigned char *first)
{
    unsigned char f[FRAME];
    enum jitter_result r = jitter_pop(j, f);
    *first = f[0];
    return r;
}

static void fill(struct jitter *j, uint16_t from, int count)
{
    for (int i = 0; i < count; i++)
        push(j, (uint16_t)(from + i));
}

static void test_primes_then_plays_in_order(void)
{
    struct jitter *j = jitter_create(FRAME);
    unsigned char b;
    fill(j, 100, 2);
    assert(pop(j, &b) == JITTER_PRIMING && b == 0); /* 2 < start target 3 */
    push(j, 102);
    for (int i = 0; i < 3; i++) {
        assert(pop(j, &b) == JITTER_FRAME);
        assert(b == (unsigned char)((100 + i) | 1));
    }
    jitter_destroy(j);
}

static void test_lost_packet_is_concealed_and_skipped(void)
{
    struct jitter *j = jitter_create(FRAME);
    unsigned char b;
    push(j, 10); push(j, 11); push(j, 13); push(j, 14); /* 12 is lost */
    assert(pop(j, &b) == JITTER_FRAME);                  /* 10 */
    assert(pop(j, &b) == JITTER_FRAME);                  /* 11 */
    assert(pop(j, &b) == JITTER_CONCEALED && b != 0);    /* 12: a faded repeat of 11, not a hole */
    assert(pop(j, &b) == JITTER_FRAME);                  /* 13 */
    struct jitter_stats s;
    jitter_get_stats(j, &s);
    assert(s.concealed == 1 && s.played == 3 && s.target == 3); /* a hole is not starvation */
    jitter_destroy(j);
}

static void test_reordering_within_window_is_repaired(void)
{
    struct jitter *j = jitter_create(FRAME);
    unsigned char b;
    push(j, 1); push(j, 3); push(j, 2); /* arrives out of order while priming */
    for (int i = 1; i <= 3; i++) {
        assert(pop(j, &b) == JITTER_FRAME);
        assert(b == (unsigned char)(i | 1));
    }
    jitter_destroy(j);
}

static void test_late_and_duplicate_packets_are_counted(void)
{
    struct jitter *j = jitter_create(FRAME);
    unsigned char b;
    fill(j, 50, 4);
    pop(j, &b); pop(j, &b); /* 50, 51 played */
    push(j, 50);            /* late */
    push(j, 53);            /* duplicate */
    struct jitter_stats s;
    jitter_get_stats(j, &s);
    assert(s.late == 1 && s.duplicate == 1);
    jitter_destroy(j);
}

static void test_sequence_wraparound(void)
{
    struct jitter *j = jitter_create(FRAME);
    unsigned char b;
    for (uint16_t seq = 65534; seq != 3; seq++) {
        push(j, seq);
        if (seq >= 65535 || seq == 65534)
            continue;
    }
    push(j, 3);
    /* 65534, 65535, 0, 1, 2, 3: all should play in order across the wrap */
    uint16_t expect = 65534;
    for (int i = 0; i < 6; i++, expect++) {
        assert(pop(j, &b) == JITTER_FRAME);
        assert(b == (unsigned char)(expect | 1));
    }
    jitter_destroy(j);
}

static void test_starvation_deepens_buffer_up_to_max(void)
{
    struct jitter *j = jitter_create(FRAME);
    unsigned char b;
    struct jitter_stats s;
    for (int round = 0; round < 8; round++) {
        jitter_get_stats(j, &s);
        int depth = (int)s.target; /* priming needs `target` frames */
        fill(j, (uint16_t)(1000 + round * 10), depth);
        for (int i = 0; i < depth; i++)
            assert(pop(j, &b) == JITTER_FRAME);
        assert(pop(j, &b) == JITTER_CONCEALED); /* nothing left: starved */
    }
    jitter_get_stats(j, &s);
    assert(s.target == 14); /* 3 -> 5 -> ... grows by 2 per starvation, capped at 14 (280 ms) */
    jitter_destroy(j);
}

static void test_calm_period_shrinks_buffer(void)
{
    struct jitter *j = jitter_create(FRAME);
    unsigned char b;
    uint16_t seq = 0;
    fill(j, seq, 3); seq += 3;
    for (int i = 0; i < 300; i++) { /* steady 1-in 1-out stream */
        push(j, seq++);
        assert(pop(j, &b) == JITTER_FRAME);
    }
    struct jitter_stats s;
    jitter_get_stats(j, &s);
    assert(s.target == 3); /* the floor is 3 now: nothing to shrink to below the start target */
    jitter_destroy(j);
}

static void test_far_jump_resyncs(void)
{
    struct jitter *j = jitter_create(FRAME);
    unsigned char b;
    fill(j, 0, 3);
    assert(pop(j, &b) == JITTER_FRAME);
    fill(j, 5000, 3); /* sender restarted far away */
    struct jitter_stats s;
    jitter_get_stats(j, &s);
    assert(s.overflow == 1);
    for (int i = 0; i < 3; i++) {
        assert(pop(j, &b) == JITTER_FRAME);
        assert(b == (unsigned char)((5000 + i) | 1));
    }
    jitter_destroy(j);
}

static void test_burst_keeps_latency_bounded(void)
{
    struct jitter *j = jitter_create(FRAME);
    unsigned char b;
    fill(j, 0, 3);
    pop(j, &b);
    fill(j, 3, 20); /* 20 frames at once, far more than target + 4 */
    struct jitter_stats s;
    jitter_get_stats(j, &s);
    assert(s.overflow > 0);
    assert(pop(j, &b) == JITTER_FRAME);
    assert(b == (unsigned char)(10 | 1)); /* only target + 10 = 13 frames stay: 10..22, the oldest were dropped */
    jitter_destroy(j);
}

static int first_sample(const unsigned char *f)
{
    int16_t v;
    memcpy(&v, f, sizeof(v));
    return v;
}

static void push_sample(struct jitter *j, uint16_t seq, int16_t value, int redundant)
{
    int16_t f[FRAME / 2];
    for (int i = 0; i < FRAME / 2; i++)
        f[i] = value;
    if (redundant)
        jitter_push_redundant(j, seq, f);
    else
        jitter_push(j, seq, f);
}

static void test_concealment_fades_out_over_three_frames(void)
{
    struct jitter *j = jitter_create(FRAME);
    unsigned char f[FRAME];
    push_sample(j, 0, 1000, 0); push_sample(j, 1, 1000, 0); push_sample(j, 2, 1000, 0);
    push_sample(j, 8, 1000, 0); /* 3..7 are missing but something is buffered behind them */
    for (int i = 0; i < 3; i++)
        assert(jitter_pop(j, f) == JITTER_FRAME);
    int expect[] = { 750, 500, 250, 0, 0 };
    for (int i = 0; i < 5; i++) {
        assert(jitter_pop(j, f) == JITTER_CONCEALED);
        assert(first_sample(f) == expect[i]);
    }
    jitter_destroy(j);
}

static void test_redundant_copy_repairs_a_lost_frame(void)
{
    struct jitter *j = jitter_create(FRAME);
    unsigned char f[FRAME];
    push_sample(j, 0, 100, 0); push_sample(j, 1, 100, 0); push_sample(j, 2, 100, 0);
    assert(jitter_pop(j, f) == JITTER_FRAME);
    /* 3 is lost; the packet for 4 carries it again */
    push_sample(j, 4, 400, 0);
    push_sample(j, 3, 300, 1);
    assert(jitter_pop(j, f) == JITTER_FRAME);
    assert(jitter_pop(j, f) == JITTER_FRAME);
    assert(jitter_pop(j, f) == JITTER_FRAME && first_sample(f) == 300);
    assert(jitter_pop(j, f) == JITTER_FRAME && first_sample(f) == 400);
    struct jitter_stats s;
    jitter_get_stats(j, &s);
    assert(s.recovered == 1 && s.concealed == 0 && s.late == 0 && s.duplicate == 0);
    jitter_destroy(j);
}

static void test_redundant_copy_is_ignored_when_not_needed(void)
{
    struct jitter *j = jitter_create(FRAME);
    unsigned char f[FRAME];
    push_sample(j, 0, 100, 0); push_sample(j, 1, 100, 0); push_sample(j, 2, 100, 0);
    push_sample(j, 2, 100, 1); /* already held */
    assert(jitter_pop(j, f) == JITTER_FRAME);
    assert(jitter_pop(j, f) == JITTER_FRAME);
    assert(jitter_pop(j, f) == JITTER_FRAME);
    push_sample(j, 1, 100, 1); /* already played: never late, never counted */
    struct jitter_stats s;
    jitter_get_stats(j, &s);
    assert(s.recovered == 0 && s.late == 0 && s.duplicate == 0);
    jitter_destroy(j);
}

int main(void)
{
    test_concealment_fades_out_over_three_frames();
    test_redundant_copy_repairs_a_lost_frame();
    test_redundant_copy_is_ignored_when_not_needed();
    test_primes_then_plays_in_order();
    test_lost_packet_is_concealed_and_skipped();
    test_reordering_within_window_is_repaired();
    test_late_and_duplicate_packets_are_counted();
    test_sequence_wraparound();
    test_starvation_deepens_buffer_up_to_max();
    test_calm_period_shrinks_buffer();
    test_far_jump_resyncs();
    test_burst_keeps_latency_bounded();
    puts("jitter: all tests passed");
    return 0;
}
