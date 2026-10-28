/* Stand-in for the iPhone, run on the device against a local `cellbridge_audiod serve`.
 * Starts DL+UL over UDP, sends a 440 Hz tone with optional loss / jitter, counts what the daemon sends back.
 *
 * usage: udp_probe <token> <seconds> [loss_percent [jitter_ms]]
 */
#include <arpa/inet.h>
#include <errno.h>
#include <math.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

enum { TCP_PORT = 8766, DAEMON_UDP = 8767, FRAME_BYTES = 640, PACKET = 4 + FRAME_BYTES, QUEUE = 64 };

static long long now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000LL + t.tv_nsec / 1000000;
}

static int send_msg(int fd, unsigned char type, const void *payload, unsigned len)
{
    unsigned char buf[64];
    buf[0] = type;
    buf[1] = len & 0xff;
    buf[2] = len >> 8;
    memcpy(buf + 3, payload, len);
    return send(fd, buf, 3 + len, 0) == (ssize_t)(3 + len) ? 0 : -1;
}

/* Returns the reply type (0x80 OK / 0x81 ERR) or -1. */
static int read_reply(int fd)
{
    unsigned char h[3], junk[256];
    if (recv(fd, h, 3, MSG_WAITALL) != 3)
        return -1;
    unsigned len = h[1] | (h[2] << 8);
    if (len && recv(fd, junk, len < sizeof(junk) ? len : sizeof(junk), MSG_WAITALL) < 0)
        return -1;
    return h[0];
}

struct pending {
    long long due_ms;
    unsigned char packet[PACKET];
    int used;
};

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <token> <seconds> [loss_percent [jitter_ms]]\n", argv[0]);
        return 64;
    }
    const char *token = argv[1];
    int seconds = atoi(argv[2]), loss = argc > 3 ? atoi(argv[3]) : 0, jitter = argc > 4 ? atoi(argv[4]) : 0;
    srand(1);

    int tcp = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in daemon_tcp = { .sin_family = AF_INET, .sin_port = htons(TCP_PORT) };
    daemon_tcp.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(tcp, (struct sockaddr *)&daemon_tcp, sizeof(daemon_tcp)) != 0) {
        perror("connect");
        return 1;
    }
    send_msg(tcp, 0x00, token, (unsigned)strlen(token));
    if (read_reply(tcp) != 0x80) {
        fprintf(stderr, "auth failed\n");
        return 1;
    }

    int udp = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in me = { .sin_family = AF_INET };
    me.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bind(udp, (struct sockaddr *)&me, sizeof(me));
    socklen_t me_len = sizeof(me);
    getsockname(udp, (struct sockaddr *)&me, &me_len);
    struct sockaddr_in daemon_udp = { .sin_family = AF_INET, .sin_port = htons(DAEMON_UDP) };
    daemon_udp.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    unsigned char start[7] = { 3 }; /* DL + UL */
    memcpy(start + 1, &me.sin_addr.s_addr, 4);
    start[5] = ntohs(me.sin_port) & 0xff;
    start[6] = ntohs(me.sin_port) >> 8;
    send_msg(tcp, 0x01, start, sizeof(start));
    if (read_reply(tcp) != 0x80) {
        fprintf(stderr, "start refused\n");
        return 1;
    }

    struct pending queue[QUEUE] = { 0 };
    unsigned sent = 0, dropped = 0, dl_packets = 0, dl_gaps = 0;
    int have_last = 0;
    uint16_t seq = 0, last_dl = 0;
    long long t0 = now_ms(), next_frame = t0;
    while (now_ms() - t0 < seconds * 1000LL) {
        long long now = now_ms();
        if (now >= next_frame) {
            next_frame += 20;
            unsigned char packet[PACKET] = { seq & 0xff, seq >> 8, 0, 0 };
            int16_t *pcm = (int16_t *)(packet + 4);
            for (int i = 0; i < FRAME_BYTES / 2; i++)
                pcm[i] = (int16_t)(8000 * sin(2 * M_PI * 440 * ((unsigned long)seq * 320 + i) / 16000.0));
            seq++;
            if (rand() % 100 < loss) {
                dropped++;
            } else {
                for (int i = 0; i < QUEUE; i++) {
                    if (!queue[i].used) {
                        queue[i].used = 1;
                        queue[i].due_ms = now + (jitter ? rand() % (jitter + 1) : 0);
                        memcpy(queue[i].packet, packet, PACKET);
                        break;
                    }
                }
            }
        }
        for (int i = 0; i < QUEUE; i++) {
            if (queue[i].used && queue[i].due_ms <= now) {
                sendto(udp, queue[i].packet, PACKET, 0, (struct sockaddr *)&daemon_udp, sizeof(daemon_udp));
                queue[i].used = 0;
                sent++;
            }
        }
        unsigned char in[PACKET + 8];
        ssize_t n;
        while ((n = recv(udp, in, sizeof(in), MSG_DONTWAIT)) > 0) {
            if (n != PACKET)
                continue;
            uint16_t s = (uint16_t)(in[0] | (in[1] << 8));
            if (have_last && (uint16_t)(s - last_dl) != 1)
                dl_gaps++;
            last_dl = s;
            have_last = 1;
            dl_packets++;
        }
        usleep(1000);
    }

    send_msg(tcp, 0x02, NULL, 0);
    int stop = read_reply(tcp);
    printf("probe: ul sent=%u dropped_by_probe=%u | dl received=%u (expected ~%d) gaps=%u | stop=%s\n", sent, dropped,
           dl_packets, seconds * 50, dl_gaps, stop == 0x80 ? "ok" : "FAILED");
    close(tcp);
    return stop == 0x80 ? 0 : 1;
}
