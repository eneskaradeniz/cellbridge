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
    assert(pop(j, &b) == JITTER_CONCEALED && b == 0);    /* 12 */
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
    for (int round = 0; round < 7; round++) {
        jitter_get_stats(j, &s);
        int depth = (int)s.target; /* priming needs `target` frames */
        fill(j, (uint16_t)(1000 + round * 10), depth);
        for (int i = 0; i < depth; i++)
            assert(pop(j, &b) == JITTER_FRAME);
        assert(pop(j, &b) == JITTER_CONCEALED); /* nothing left: starved */
    }
    jitter_get_stats(j, &s);
    assert(s.target == 7); /* 3 -> 4 -> ... -> 7, capped */
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
    assert(s.target == 2);
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
    assert(b == (unsigned char)(14 | 1)); /* only target + 6 = 9 frames stay: 14..22, the oldest were dropped */
    jitter_destroy(j);
}

int main(void)
{
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
