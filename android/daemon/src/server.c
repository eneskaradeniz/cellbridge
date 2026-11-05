#include "log.h"
#include "server.h"
#include "mic.h"

#include <arpa/inet.h>
#include <errno.h>
#include <pthread.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "audio.h"
#include "stream.h"

enum {
    MSG_AUTH = 0x00,
    MSG_START = 0x01,
    MSG_STOP = 0x02,
    MSG_DL_FRAME = 0x10,
    MSG_UL_FRAME = 0x11,
    MSG_OK = 0x80,
    MSG_ERR = 0x81,
};

enum { START_DL = 1 << 0, START_UL = 1 << 1 };
enum { HEADER_BYTES = 3, MAX_PAYLOAD = 4096 };

static volatile sig_atomic_t stop_requested;

struct session {
    int fd;
    pthread_mutex_t send_lock;
    struct audio *audio;
    struct stream *stream; /* set when audio flows over UDP instead of TCP frames */
    unsigned int flags;
    pthread_t dl_thread;
    bool dl_thread_running;
    atomic_bool dl_stop;
};

void server_request_stop(void)
{
    stop_requested = 1;
}

static int read_full(int fd, void *buf, size_t n)
{
    char *p = buf;
    while (n) {
        ssize_t r = recv(fd, p, n, 0);
        if (r == 0)
            return -1;
        if (r < 0) {
            if (errno == EINTR && !stop_requested)
                continue;
            return -1;
        }
        p += r;
        n -= (size_t)r;
    }
    return 0;
}

static int send_frame(struct session *s, unsigned char type, const void *payload, unsigned int len)
{
    unsigned char frame[HEADER_BYTES + MAX_PAYLOAD];
    frame[0] = type;
    frame[1] = len & 0xff;
    frame[2] = len >> 8;
    if (len)
        memcpy(frame + HEADER_BYTES, payload, len);

    int rc = 0;
    pthread_mutex_lock(&s->send_lock);
    size_t total = HEADER_BYTES + len, sent = 0;
    while (sent < total) {
        ssize_t w = send(s->fd, frame + sent, total - sent, MSG_NOSIGNAL);
        if (w < 0 && errno == EINTR)
            continue;
        if (w <= 0) {
            rc = -1;
            break;
        }
        sent += (size_t)w;
    }
    pthread_mutex_unlock(&s->send_lock);
    return rc;
}

static int send_err(struct session *s, const char *reason)
{
    return send_frame(s, MSG_ERR, reason, (unsigned int)strlen(reason));
}

static void *dl_loop(void *arg)
{
    struct session *s = arg;
    unsigned int bytes = audio_period_bytes(s->audio);
    unsigned char buf[MAX_PAYLOAD];
    while (!atomic_load(&s->dl_stop)) {
        if (audio_read_dl(s->audio, buf) != 0)
            continue;
        if (send_frame(s, MSG_DL_FRAME, buf, bytes) != 0) {
            shutdown(s->fd, SHUT_RDWR); /* wakes the command loop so it can clean up */
            break;
        }
    }
    return NULL;
}

static void stop_audio(struct session *s)
{
    stream_stop(s->stream);
    s->stream = NULL;
    if (s->dl_thread_running) {
        atomic_store(&s->dl_stop, true);
        pthread_join(s->dl_thread, NULL);
        s->dl_thread_running = false;
    }
    audio_close(s->audio);
    s->audio = NULL;
    s->flags = 0;
}

/* `peer` is non-NULL when the START named a UDP peer. */
static void start_audio(struct session *s, const struct profile *p, unsigned int flags,
                        const struct sockaddr_in *peer, unsigned short udp_port)
{
    if (s->audio) {
        send_err(s, "already started");
        return;
    }
    if (!(flags & (START_DL | START_UL)) || p->period_frames * p->channels * 2 > MAX_PAYLOAD) {
        send_err(s, "bad start flags");
        return;
    }
    s->audio = audio_open(p, flags & START_DL, flags & START_UL);
    if (!s->audio) {
        send_err(s, "audio open failed");
        return;
    }
    s->flags = flags;
    if (peer) {
        s->stream = stream_start(s->audio, p, flags & START_DL, flags & START_UL, peer, udp_port);
        if (!s->stream) {
            stop_audio(s);
            send_err(s, "udp stream start failed");
            return;
        }
        send_frame(s, MSG_OK, NULL, 0);
        return;
    }
    atomic_store(&s->dl_stop, false);
    if ((flags & START_DL) && pthread_create(&s->dl_thread, NULL, dl_loop, s) != 0) {
        stop_audio(s);
        send_err(s, "thread start failed");
        return;
    }
    s->dl_thread_running = flags & START_DL;
    send_frame(s, MSG_OK, NULL, 0);
}

static bool token_matches(const unsigned char *got, unsigned int len, const char *token)
{
    size_t want = strlen(token);
    unsigned char diff = (unsigned char)(len != want);
    for (size_t i = 0; i < want; i++)
        diff |= (i < len ? got[i] : 0) ^ (unsigned char)token[i];
    return diff == 0;
}

/* `spec` is the token itself, or "@/path" to read it from a file on every check, so an init-started daemon follows
 * the app's token (which may not exist yet, or change). An empty or missing file never matches. */
static bool token_ok(const unsigned char *got, unsigned int len, const char *spec)
{
    if (spec[0] != '@')
        return token_matches(got, len, spec);
    char buf[128];
    FILE *f = fopen(spec + 1, "r");
    if (!f)
        return false;
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r' || buf[n - 1] == ' '))
        n--;
    if (n == 0)
        return false;
    buf[n] = '\0';
    return token_matches(got, len, buf);
}

/* Reads one frame; returns 0 on success, -1 on EOF/error/oversize. */
static int read_frame(int fd, unsigned char *type, unsigned char *payload, unsigned int *len)
{
    unsigned char h[HEADER_BYTES];
    if (read_full(fd, h, sizeof(h)) != 0)
        return -1;
    *type = h[0];
    *len = h[1] | (h[2] << 8);
    if (*len > MAX_PAYLOAD)
        return -1;
    return *len ? read_full(fd, payload, *len) : 0;
}

static void serve_client(int fd, const struct profile *p, const char *token, unsigned short udp_port)
{
    struct session s = { .fd = fd, .send_lock = PTHREAD_MUTEX_INITIALIZER };
    atomic_init(&s.dl_stop, false);
    unsigned char type, payload[MAX_PAYLOAD];
    unsigned int len;

    if (read_frame(fd, &type, payload, &len) != 0 || type != MSG_AUTH || !token_ok(payload, len, token)) {
        send_err(&s, "auth failed");
        return;
    }
    send_frame(&s, MSG_OK, NULL, 0);

    while (!stop_requested && read_frame(fd, &type, payload, &len) == 0) {
        switch (type) {
        case MSG_START:
            if (len == 1) {
                start_audio(&s, p, payload[0], NULL, udp_port);
            } else if (len == 7) { /* flags, ipv4[4], port (LE) */
                struct sockaddr_in peer = { .sin_family = AF_INET, .sin_port = htons((unsigned short)(payload[5] | (payload[6] << 8))) };
                memcpy(&peer.sin_addr.s_addr, payload + 1, 4);
                start_audio(&s, p, payload[0], &peer, udp_port);
            } else {
                send_err(&s, "bad start");
            }
            break;
        case MSG_STOP:
            stop_audio(&s);
            send_frame(&s, MSG_OK, NULL, 0);
            break;
        case MSG_UL_FRAME:
            if (!s.audio || !(s.flags & START_UL) || s.stream)
                send_err(&s, "uplink not started");
            else if (len != audio_period_bytes(s.audio))
                send_err(&s, "bad uplink frame size");
            else
                audio_write_ul(s.audio, payload);
            break;
        default:
            send_err(&s, "unknown message");
        }
    }
    stop_audio(&s);
}

int server_run(const struct profile *p, const char *token, unsigned short port, unsigned short udp_port)
{
    signal(SIGPIPE, SIG_IGN);
    mic_recover(p); /* a crash or kill -9 mid-call may have left the phone microphone silenced */
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) {
        perror("socket");
        return 1;
    }
    int one = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = { .sin_family = AF_INET, .sin_port = htons(port) };
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listener, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(listener, 1) != 0) {
        perror("bind/listen");
        close(listener);
        return 1;
    }
    daemon_log("listening on 127.0.0.1:%u\n", port);

    while (!stop_requested) {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0)
            continue; /* EINTR from a signal re-checks stop_requested */
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        serve_client(fd, p, token, udp_port);
        close(fd);
    }
    close(listener);
    return 0;
}
