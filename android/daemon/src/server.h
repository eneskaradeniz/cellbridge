#ifndef CELLBRIDGE_SERVER_H
#define CELLBRIDGE_SERVER_H

#include "profile.h"

/* `udp_port` is the host port for UDP audio when a START names a peer. Serve the loopback control/audio protocol (docs/protocol.md) until server_request_stop().
 * Returns 0 on a clean stop, non-zero if the listening socket cannot be set up. */
int server_run(const struct profile *p, const char *token, unsigned short port, unsigned short udp_port);

/* Async-signal-safe. */
void server_request_stop(void);

#endif
