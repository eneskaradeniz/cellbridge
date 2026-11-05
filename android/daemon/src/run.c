#include "run.h"

#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static long long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000;
}

/* Runs argv[0] (no shell: the arguments are never interpreted) and collects what it prints. False on a timeout. */
bool run_command(char *const argv[], char *out, size_t cap, int timeout_ms)
{
    int fds[2];
    if (pipe(fds) != 0)
        return false;
    pid_t pid = fork();
    if (pid < 0) {
        close(fds[0]);
        close(fds[1]);
        return false;
    }
    if (pid == 0) {
        dup2(fds[1], 1);
        dup2(fds[1], 2);
        close(fds[0]);
        close(fds[1]);
        execvp(argv[0], argv);
        _exit(127);
    }
    close(fds[1]);
    size_t n = 0;
    bool ok = true;
    long long deadline = now_ms() + timeout_ms;
    for (;;) {
        long long left = deadline - now_ms();
        struct pollfd p = { .fd = fds[0], .events = POLLIN };
        if (left <= 0 || poll(&p, 1, (int)left) <= 0) {
            ok = false;
            break;
        }
        ssize_t r = read(fds[0], out + n, cap - 1 - n);
        if (r <= 0)
            break; /* the command closed its output: it is done */
        n += (size_t)r;
        if (n >= cap - 1)
            break;
    }
    out[n] = '\0';
    close(fds[0]);
    if (!ok)
        kill(pid, SIGKILL);
    waitpid(pid, NULL, 0);
    return ok;
}

