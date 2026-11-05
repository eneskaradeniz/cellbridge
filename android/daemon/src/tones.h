#ifndef CELLBRIDGE_TONES_H
#define CELLBRIDGE_TONES_H

#include <stdbool.h>

#define TONE_LINE_MAX 400

/* True for a Telecom log line about a call tone (the ringback player and the tone player). */
bool tones_is_relevant(const char *line);

/* Follows the Telecom log in a background thread and calls `emit` for every relevant line (trimmed to TONE_LINE_MAX
 * bytes, no newline). The phone makes ringback, busy and end-of-call sounds itself, so they never reach the voice path
 * the daemon relays; the app turns these lines into tone messages for the iPhone. Restarts logcat if it ends. */
void tones_start(void (*emit)(const char *line, void *ctx), void *ctx);

#endif
