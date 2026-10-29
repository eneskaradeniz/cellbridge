#include "log.h"
#include "stream.h"

#include <arpa/inet.h>
#include <errno.h>
#include <stdbool.h>
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

enum { MAX_PERIOD_BYTES = 2048, RECV_TIMEOUT_MS = 100, ECHO_SLOTS = 16 };

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
    unsigned int rx_long_gaps, rx_back_to_back, rx_max_gap_ms; /* spacing between arriving uplink packets */
    double play_write_ms_total;
    /* Test mode (CELLBRIDGE_ECHO): the downlink is the uplink played back, so the whole audio chain can be tried
     * without a call. The PCMs stay unused. */
    bool echo;
    FILE *dump_ul; /* CELLBRIDGE_DUMP_UL=<path>: the uplink exactly as injected (concealed frames as silence) */
    FILE *dump; /* CELLBRIDGE_DUMP_DL=<path>: the captured downlink as raw 16 kHz S16 mono, to listen to or analyse */
    bool tone; /* test mode (CELLBRIDGE_TONE): the downlink is a steady 440 Hz tone, no capture, no microphone loop */
    pthread_mutex_t echo_lock;
    unsigned char echo_frames[ECHO_SLOTS][MAX_PERIOD_BYTES];
    unsigned int echo_head, echo_count;
};

static void echo_push(struct stream *s, const unsigned char *frame)
{
    pthread_mutex_lock(&s->echo_lock);
    if (s->echo_count == ECHO_SLOTS) { /* a stalled sender: drop the oldest, keep the delay bounded */
        s->echo_head = (s->echo_head + 1) % ECHO_SLOTS;
        s->echo_count--;
    }
    memcpy(s->echo_frames[(s->echo_head + s->echo_count) % ECHO_SLOTS], frame, s->period_bytes);
    s->echo_count++;
    pthread_mutex_unlock(&s->echo_lock);
}

/* Silence when nothing is queued, so the stream stays continuous. */
static void echo_pop(struct stream *s, unsigned char *out)
{
    pthread_mutex_lock(&s->echo_lock);
    if (s->echo_count) {
        memcpy(out, s->echo_frames[s->echo_head], s->period_bytes);
        s->echo_head = (s->echo_head + 1) % ECHO_SLOTS;
        s->echo_count--;
    } else {
        memset(out, 0, s->period_bytes);
    }
    pthread_mutex_unlock(&s->echo_lock);
}

static void add_ns(struct timespec *t, unsigned int ns);

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

enum { FLAG_PREVIOUS_FRAME = 1 }; /* the packet carries frame seq-1 after frame seq (docs/protocol.md) */

static void put_header(unsigned char *p, uint16_t seq, unsigned char flags)
{
    p[0] = seq & 0xff;
    p[1] = seq >> 8;
    p[2] = flags;
    p[3] = 0;
}

static void *dl_loop(void *arg)
{
    struct stream *s = arg;
    unsigned char packet[STREAM_HEADER_BYTES + 2 * MAX_PERIOD_BYTES];
    unsigned char previous[MAX_PERIOD_BYTES];
    bool have_previous = false;
    uint16_t seq = 0;
    double last_send = 0;
    struct timespec next;
    clock_gettime(CLOCK_MONOTONIC, &next);
    unsigned long long tone_pos = 0;
    while (!atomic_load(&s->stop)) {
        if (s->tone) {
            add_ns(&next, s->period_ns);
            clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
            short *pcm = (short *)(packet + STREAM_HEADER_BYTES);
            for (unsigned int i = 0; i < s->period_bytes / 2; i++, tone_pos++)
                pcm[i] = (short)(8000 * sin(2 * M_PI * 440 * (double)tone_pos / 16000.0));
        } else if (s->echo) {
            add_ns(&next, s->period_ns);
            clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
            echo_pop(s, packet + STREAM_HEADER_BYTES);
        } else if (audio_read_dl(s->audio, packet + STREAM_HEADER_BYTES) != 0) {
            continue;
        }
        if (s->dump)
            fwrite(packet + STREAM_HEADER_BYTES, 1, s->period_bytes, s->dump);
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
        /* Each packet repeats the frame before it, so one lost packet costs nothing. */
        size_t length = STREAM_HEADER_BYTES + s->period_bytes;
        if (have_previous) {
            memcpy(packet + length, previous, s->period_bytes);
            length += s->period_bytes;
        }
        memcpy(previous, packet + STREAM_HEADER_BYTES, s->period_bytes);
        put_header(packet, seq++, have_previous ? FLAG_PREVIOUS_FRAME : 0);
        have_previous = true;
        /* UDP: a full socket buffer or an unreachable peer just loses this frame. */
        if (sendto(s->fd, packet, length, 0, (struct sockaddr *)&s->peer, sizeof(s->peer)) > 0)
            s->dl_sent++;
    }
    return NULL;
}

static void *rx_loop(void *arg)
{
    struct stream *s = arg;
    unsigned char packet[STREAM_HEADER_BYTES + 2 * MAX_PERIOD_BYTES + 1];
    double last_rx = 0;
    while (!atomic_load(&s->stop)) {
        struct sockaddr_in from;
        socklen_t from_len = sizeof(from);
        ssize_t n = recvfrom(s->fd, packet, sizeof(packet), 0, (struct sockaddr *)&from, &from_len);
        if (n < 0)
            continue; /* timeout or EINTR: re-check the stop flag */
        /* Only the announced peer may feed the call, and only whole frames. */
        if (from.sin_addr.s_addr != s->peer.sin_addr.s_addr || from.sin_port != s->peer.sin_port)
            continue;
        bool with_previous = (size_t)n == STREAM_HEADER_BYTES + 2 * (size_t)s->period_bytes && (packet[2] & FLAG_PREVIOUS_FRAME);
        if ((size_t)n != STREAM_HEADER_BYTES + s->period_bytes && !with_previous)
            continue;
        double arrived = now_ms();
        if (last_rx > 0) {
            double gap = arrived - last_rx;
            if (gap > 60)
                s->rx_long_gaps++;
            if (gap < 5)
                s->rx_back_to_back++;
            if (gap > s->rx_max_gap_ms)
                s->rx_max_gap_ms = (unsigned int)gap;
        }
        last_rx = arrived;
        uint16_t seq = (uint16_t)(packet[0] | (packet[1] << 8));
        jitter_push(s->jitter, seq, packet + STREAM_HEADER_BYTES);
        if (with_previous)
            jitter_push_redundant(s->jitter, (uint16_t)(seq - 1), packet + STREAM_HEADER_BYTES + s->period_bytes);
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
        if (s->dump_ul && r != JITTER_PRIMING)
            fwrite(frame, 1, s->period_bytes, s->dump_ul);
        if (r == JITTER_FRAME) {
            s->ul_sum_sq += sum_squares((const short *)frame, s->period_bytes / 2);
            s->ul_samples += s->period_bytes / 2;
        }
        double write_start = now_ms();
        if (s->echo)
            echo_push(s, frame);
        else if (!s->tone)
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
        daemon_log("stream: period too large\n");
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
    pthread_mutex_init(&s->echo_lock, NULL);
    s->echo = getenv("CELLBRIDGE_ECHO") != NULL;
    s->tone = getenv("CELLBRIDGE_TONE") != NULL;
    const char *dump_ul_path = getenv("CELLBRIDGE_DUMP_UL");
    if (dump_ul_path && !(s->dump_ul = fopen(dump_ul_path, "wb")))
        daemon_log("stream: cannot write %s: %s\n", dump_ul_path, strerror(errno));
    const char *dump_path = getenv("CELLBRIDGE_DUMP_DL");
    if (dump_path && !(s->dump = fopen(dump_path, "wb")))
        daemon_log("stream: cannot write %s: %s\n", dump_path, strerror(errno));
    if (s->tone)
        daemon_log("stream: TONE TEST MODE, the downlink is a steady 440 Hz tone, no call audio\n");
    if (s->echo)
        daemon_log("stream: ECHO TEST MODE, the downlink is the uplink played back, no call audio\n");

    s->fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in local = { .sin_family = AF_INET, .sin_port = htons(local_port) };
    struct timeval timeout = { .tv_usec = RECV_TIMEOUT_MS * 1000 };
    if (s->fd < 0 || setsockopt(s->fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0 ||
        bind(s->fd, (struct sockaddr *)&local, sizeof(local)) != 0) {
        daemon_log("stream: udp port %u: %s\n", local_port, strerror(errno));
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
        daemon_log("stream: dl_sent=%u ul played=%u concealed=%u recovered=%u late=%u duplicate=%u overflow=%u target=%u\n",
                s->dl_sent, j.played, j.concealed, j.recovered, j.late, j.duplicate, j.overflow, j.target);
        daemon_log(
                "stream: dl_rms=%.0f ul_rms=%.0f | playout ticks=%u resyncs=%u avg_write_ms=%.1f max_write_ms=%u\n",
                s->dl_samples ? sqrt(s->dl_sum_sq / s->dl_samples) : 0.0,
                s->ul_samples ? sqrt(s->ul_sum_sq / s->ul_samples) : 0.0, s->play_ticks, s->play_resyncs,
                s->play_ticks ? s->play_write_ms_total / s->play_ticks : 0.0, s->play_max_write_ms);
        daemon_log("stream: dl send gaps: max=%u ms, over 60 ms=%u, under 5 ms=%u | ul arrival gaps: max=%u ms, over 60 ms=%u, under 5 ms=%u\n",
                s->dl_max_gap_ms, s->dl_long_gaps, s->dl_back_to_back, s->rx_max_gap_ms, s->rx_long_gaps, s->rx_back_to_back);
    } else {
        daemon_log("stream: dl_sent=%u\n", s->dl_sent);
    }
    if (s->dump)
        fclose(s->dump);
    if (s->dump_ul)
        fclose(s->dump_ul);
    jitter_destroy(s->jitter);
    if (s->fd >= 0)
        close(s->fd);
    free(s);
}
