/* cellbridge_audiod — root call-audio daemon. Step 1: on-device test CLI (capture / inject). */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "audio.h"

static volatile sig_atomic_t stop_requested;

static void on_signal(int sig)
{
    (void)sig;
    stop_requested = 1;
}

static long long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000;
}

static void install_signal_handlers(void)
{
    struct sigaction sa = { .sa_handler = on_signal };
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
}

static int capture(const struct profile *p, const char *path, unsigned int seconds)
{
    FILE *out = fopen(path, "wb");
    if (!out) {
        perror(path);
        return 1;
    }
    struct audio *a = audio_open(p, true, false);
    if (!a) {
        fclose(out);
        return 1;
    }

    unsigned int bytes = audio_period_bytes(a);
    unsigned int periods = seconds * 1000 / (p->period_frames * 1000 / p->rate);
    char *buf = malloc(bytes);
    unsigned int errors = 0, done = 0;
    long long sum_sq = 0;
    for (; done < periods && !stop_requested; done++) {
        if (audio_read_dl(a, buf) != 0) {
            errors++;
            continue;
        }
        fwrite(buf, 1, bytes, out);
        const short *s = (const short *)buf;
        for (unsigned int i = 0; i < bytes / 2; i++)
            sum_sq += (long long)s[i] * s[i];
    }
    printf("capture: %u periods, %u read errors, mean power %lld\n", done, errors,
           done ? sum_sq / ((long long)done * (bytes / 2)) : 0);
    free(buf);
    audio_close(a);
    fclose(out);
    return errors ? 2 : 0;
}

static int inject(const struct profile *p, const char *path)
{
    FILE *in = fopen(path, "rb");
    if (!in) {
        perror(path);
        return 1;
    }
    struct audio *a = audio_open(p, false, true);
    if (!a) {
        fclose(in);
        return 1;
    }

    unsigned int bytes = audio_period_bytes(a);
    char *buf = malloc(bytes);
    unsigned int errors = 0, done = 0;
    long long start = now_ms(), max_write = 0;
    while (!stop_requested && fread(buf, 1, bytes, in) == bytes) {
        long long t0 = now_ms();
        if (audio_write_ul(a, buf) != 0)
            errors++;
        if (now_ms() - t0 > max_write)
            max_write = now_ms() - t0;
        done++;
    }
    printf("inject: %u periods, %u write errors, %lld ms elapsed (content %u ms), max write %lld ms\n", done,
           errors, now_ms() - start, done * p->period_frames * 1000 / p->rate, max_write);
    free(buf);
    audio_close(a);
    fclose(in);
    return errors ? 2 : 0;
}

static int usage(const char *argv0)
{
    fprintf(stderr, "usage: %s <profile> capture <out.raw> <seconds>\n"
                    "       %s <profile> inject <in.raw>   (16 kHz S16_LE mono, raw)\n", argv0, argv0);
    return 64;
}

int main(int argc, char **argv)
{
    if (argc < 4)
        return usage(argv[0]);
    struct profile p;
    if (!profile_load(argv[1], &p))
        return 1;
    install_signal_handlers();

    if (!strcmp(argv[2], "capture") && argc == 5)
        return capture(&p, argv[3], (unsigned int)atoi(argv[4]));
    if (!strcmp(argv[2], "inject") && argc == 4)
        return inject(&p, argv[3]);
    return usage(argv[0]);
}
