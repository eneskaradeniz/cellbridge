#include "log.h"

#include <android/log.h>
#include <stdarg.h>
#include <stdio.h>

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
}
