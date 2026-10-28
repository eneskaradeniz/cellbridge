#include "stream.h"

#include <arpa/inet.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <math.h>
#include <netinet/ip.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "jitter.h"

enum { MAX_PERIOD_BYTES = 2048, RECV_TIMEOUT_MS = 100 };

struct stream {
    struct audio *audio;
    struct sockaddr_in peer;
    unsigned int period_bytes;
    unsigned int period_ns;
    int fd;
    atomic_bool stop;
    struct jitter *jitter;
    pthread_t dl_thread, rx_thread, play_thread;
    bool dl_running, rx_running, play_running;
    unsigned int dl_sent;
    /* Diagnostics, written by one thread each and read after the joins. */
    double dl_sum_sq, ul_sum_sq;
    unsigned long long dl_samples, ul_samples;
    unsigned int play_ticks, play_resyncs, play_max_write_ms;
    unsigned int dl_long_gaps, dl_back_to_back, dl_max_gap_ms; /* spacing between downlink sends */
    double play_write_ms_total;
};

static double sum_squares(const short *s, unsigned int n)
{
    double sum = 0;
    for (unsigned int i = 0; i < n; i++)
        sum += (double)s[i] * s[i];
    return sum;
}

static double now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}

static void put_header(unsigned char *p, uint16_t seq)
{
    p[0] = seq & 0xff;
    p[1] = seq >> 8;
    p[2] = p[3] = 0;
}

static void *dl_loop(void *arg)
{
    struct stream *s = arg;
    unsigned char packet[STREAM_HEADER_BYTES + MAX_PERIOD_BYTES];
    uint16_t seq = 0;
    double last_send = 0;
    while (!atomic_load(&s->stop)) {
        if (audio_read_dl(s->audio, packet + STREAM_HEADER_BYTES) != 0)
            continue;
        s->dl_sum_sq += sum_squares((const short *)(packet + STREAM_HEADER_BYTES), s->period_bytes / 2);
        s->dl_samples += s->period_bytes / 2;
        double sent_at = now_ms();
        if (last_send > 0) {
            double gap = sent_at - last_send;
            if (gap > 60)
                s->dl_long_gaps++;
            if (gap < 5)
                s->dl_back_to_back++;
            if (gap > s->dl_max_gap_ms)
                s->dl_max_gap_ms = (unsigned int)gap;
        }
        last_send = sent_at;
        put_header(packet, seq++);
        /* UDP: a full socket buffer or an unreachable peer just loses this frame. */
        if (sendto(s->fd, packet, STREAM_HEADER_BYTES + s->period_bytes, 0, (struct sockaddr *)&s->peer,
                   sizeof(s->peer)) > 0)
            s->dl_sent++;
    }
    return NULL;
}

static void *rx_loop(void *arg)
{
    struct stream *s = arg;
    unsigned char packet[STREAM_HEADER_BYTES + MAX_PERIOD_BYTES + 1];
    while (!atomic_load(&s->stop)) {
        struct sockaddr_in from;
        socklen_t from_len = sizeof(from);
        ssize_t n = recvfrom(s->fd, packet, sizeof(packet), 0, (struct sockaddr *)&from, &from_len);
        if (n < 0)
            continue; /* timeout or EINTR: re-check the stop flag */
        /* Only the announced peer may feed the call, and only whole frames. */
        if (from.sin_addr.s_addr != s->peer.sin_addr.s_addr || from.sin_port != s->peer.sin_port)
            continue;
        if ((size_t)n != STREAM_HEADER_BYTES + s->period_bytes)
            continue;
        jitter_push(s->jitter, (uint16_t)(packet[0] | (packet[1] << 8)), packet + STREAM_HEADER_BYTES);
    }
    return NULL;
}

static void add_ns(struct timespec *t, unsigned int ns)
{
    t->tv_nsec += ns;
    while (t->tv_nsec >= 1000000000L) {
        t->tv_nsec -= 1000000000L;
        t->tv_sec++;
    }
}

/* One frame per period on the monotonic clock, so the jitter buffer is drained at the call's pace
 * rather than whenever the PCM has room. */
static void *play_loop(void *arg)
{
    struct stream *s = arg;
    unsigned char frame[MAX_PERIOD_BYTES];
    struct timespec next;
    clock_gettime(CLOCK_MONOTONIC, &next);
    while (!atomic_load(&s->stop)) {
        add_ns(&next, s->period_ns);
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
        enum jitter_result r = jitter_pop(s->jitter, frame);
        if (r == JITTER_FRAME) {
            s->ul_sum_sq += sum_squares((const short *)frame, s->period_bytes / 2);
            s->ul_samples += s->period_bytes / 2;
        }
        double write_start = now_ms();
        audio_write_ul(s->audio, frame);
        double write_ms = now_ms() - write_start;
        s->play_ticks++;
        s->play_write_ms_total += write_ms;
        if (write_ms > s->play_max_write_ms)
            s->play_max_write_ms = (unsigned int)write_ms;

        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        long behind_ns = (now.tv_sec - next.tv_sec) * 1000000000L + (now.tv_nsec - next.tv_nsec);
        if (behind_ns > 5L * s->period_ns) { /* we were stalled: do not burst to catch up */
            next = now;
            s->play_resyncs++;
        }
    }
    return NULL;
}

struct stream *stream_start(struct audio *a, const struct profile *p, bool dl, bool ul,
                            const struct sockaddr_in *peer, unsigned short local_port)
{
    unsigned int bytes = audio_period_bytes(a);
    if (bytes > MAX_PERIOD_BYTES) {
        fprintf(stderr, "stream: period too large\n");
        return NULL;
    }
    struct stream *s = calloc(1, sizeof(*s));
    if (!s)
        return NULL;
    s->audio = a;
    s->peer = *peer;
    s->period_bytes = bytes;
    s->period_ns = (unsigned int)(1000000000ULL * p->period_frames / p->rate);
    atomic_init(&s->stop, false);

    s->fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in local = { .sin_family = AF_INET, .sin_port = htons(local_port) };
    struct timeval timeout = { .tv_usec = RECV_TIMEOUT_MS * 1000 };
    if (s->fd < 0 || setsockopt(s->fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0 ||
        bind(s->fd, (struct sockaddr *)&local, sizeof(local)) != 0) {
        fprintf(stderr, "stream: udp port %u: %s\n", local_port, strerror(errno));
        goto fail;
    }
    int tos = 0xb8; /* DSCP EF: lets the hotspot send these frames in its voice queue */
    setsockopt(s->fd, IPPROTO_IP, IP_TOS, &tos, sizeof(tos));
    if (ul && !(s->jitter = jitter_create(bytes)))
        goto fail;

    if (dl && pthread_create(&s->dl_thread, NULL, dl_loop, s) != 0)
        goto fail;
    s->dl_running = dl;
    if (ul) {
        if (pthread_create(&s->rx_thread, NULL, rx_loop, s) != 0)
            goto fail;
        s->rx_running = true;
        if (pthread_create(&s->play_thread, NULL, play_loop, s) != 0)
            goto fail;
        s->play_running = true;
    }
    return s;

fail:
    stream_stop(s);
    return NULL;
}

void stream_stop(struct stream *s)
{
    if (!s)
        return;
    atomic_store(&s->stop, true);
    if (s->dl_running)
        pthread_join(s->dl_thread, NULL);
    if (s->rx_running)
        pthread_join(s->rx_thread, NULL);
    if (s->play_running)
        pthread_join(s->play_thread, NULL);
    if (s->jitter) {
        struct jitter_stats j;
        jitter_get_stats(s->jitter, &j);
        fprintf(stderr, "stream: dl_sent=%u ul played=%u concealed=%u late=%u duplicate=%u overflow=%u target=%u\n",
                s->dl_sent, j.played, j.concealed, j.late, j.duplicate, j.overflow, j.target);
        fprintf(stderr,
                "stream: dl_rms=%.0f ul_rms=%.0f | playout ticks=%u resyncs=%u avg_write_ms=%.1f max_write_ms=%u\n",
                s->dl_samples ? sqrt(s->dl_sum_sq / s->dl_samples) : 0.0,
                s->ul_samples ? sqrt(s->ul_sum_sq / s->ul_samples) : 0.0, s->play_ticks, s->play_resyncs,
                s->play_ticks ? s->play_write_ms_total / s->play_ticks : 0.0, s->play_max_write_ms);
        fprintf(stderr, "stream: dl send gaps: max=%u ms, over 60 ms=%u, under 5 ms=%u\n", s->dl_max_gap_ms,
                s->dl_long_gaps, s->dl_back_to_back);
    } else {
        fprintf(stderr, "stream: dl_sent=%u\n", s->dl_sent);
    }
    jitter_destroy(s->jitter);
    if (s->fd >= 0)
        close(s->fd);
    free(s);
}
