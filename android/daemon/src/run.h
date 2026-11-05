#ifndef CELLBRIDGE_RUN_H
#define CELLBRIDGE_RUN_H

#include <stdbool.h>
#include <stddef.h>

/* Runs argv[0] (found on PATH; no shell, so arguments are never interpreted) and collects its output. False on a timeout. */
bool run_command(char *const argv[], char *out, size_t cap, int timeout_ms);

#endif
