#include "log.h"

#include <android/log.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/stat.h>
#include <time.h>

/* The logcat ring buffer is small and another app's noise can push the daemon's lines out before anyone reads them, so the lines are kept
 * in a file too (never numbers or audio, see log.h). It is rotated once it passes half a megabyte. */
static const char *const LOG_FILE = "/data/local/tmp/cellbridge_audiod.log";

static void mirror(const char *line)
{
    struct stat st;
    if (stat(LOG_FILE, &st) == 0 && st.st_size > 512 * 1024)
        rename(LOG_FILE, "/data/local/tmp/cellbridge_audiod.log.1");
    FILE *f = fopen(LOG_FILE, "a");
    if (!f)
        return;
    time_t now = time(NULL);
    struct tm local;
    char stamp[32] = "";
    if (localtime_r(&now, &local))
        strftime(stamp, sizeof(stamp), "%m-%d %H:%M:%S", &local);
    fprintf(f, "%s %s\n", stamp, line);
    fclose(f);
}

void daemon_log(const char *fmt, ...)
{
    char line[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(line, sizeof(line), fmt, args);
    va_end(args);
    fputs(line, stderr);
    /* logcat adds its own line ending */
    size_t n = 0;
    while (line[n])
        n++;
    if (n && line[n - 1] == '\n')
        line[n - 1] = '\0';
    __android_log_write(ANDROID_LOG_INFO, "cellbridge_audiod", line);
    mirror(line);
}
