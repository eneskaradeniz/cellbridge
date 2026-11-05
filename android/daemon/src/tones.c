#include "log.h"
#include "tones.h"

#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

struct follower {
    void (*emit)(const char *line, void *ctx);
    void *ctx;
};

bool tones_is_relevant(const char *line)
{
    return strstr(line, "InCallTonePlayer") != NULL || strstr(line, "RingbackPlayer") != NULL;
}

static void *follow(void *arg)
{
    struct follower *f = arg;
    for (;;) {
        /* -T 1: only lines from now on. Telecom's own tag is all that is needed. */
        FILE *p = popen("exec logcat -T 1 -v threadtime Telecom:I '*:S' 2>/dev/null", "r");
        if (!p) {
            daemon_log("tones: cannot start logcat\n");
        } else {
            char line[1024];
            while (fgets(line, sizeof(line), p)) {
                line[strcspn(line, "\r\n")] = '\0';
                if (!tones_is_relevant(line))
                    continue;
                if (strlen(line) > TONE_LINE_MAX)
                    line[TONE_LINE_MAX] = '\0';
                f->emit(line, f->ctx);
            }
            pclose(p);
        }
        sleep(2); /* logcat ended (buffer reset, killed): follow again */
    }
    return NULL;
}

void tones_start(void (*emit)(const char *line, void *ctx), void *ctx)
{
    static struct follower f;
    f.emit = emit;
    f.ctx = ctx;
    pthread_t t;
    if (pthread_create(&t, NULL, follow, &f) == 0)
        pthread_detach(t);
    else
        daemon_log("tones: cannot start the log follower\n");
}
