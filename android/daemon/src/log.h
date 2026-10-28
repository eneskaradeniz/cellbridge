#ifndef CELLBRIDGE_LOG_H
#define CELLBRIDGE_LOG_H

/* printf-style; goes to stderr and to logcat (tag "cellbridge_audiod"), because a daemon started by init has no
 * terminal and its stderr would be lost. Never log numbers or audio content. */
void daemon_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

#endif
