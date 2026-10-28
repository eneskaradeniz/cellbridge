#ifndef CELLBRIDGE_STREAM_H
#define CELLBRIDGE_STREAM_H

#include <netinet/in.h>
#include <stdbool.h>

#include "audio.h"
#include "profile.h"

/* UDP packet = u16 seq, u16 reserved (little endian) + one PCM period (docs/protocol.md). */
enum { STREAM_HEADER_BYTES = 4 };

struct stream;

/* Starts the downlink sender (if `dl`) and the uplink receiver + paced playout (if `ul`) on `a`, talking to `peer`
 * from UDP port `local_port`. Returns NULL (reason on stderr) if the socket or threads cannot be set up. */
struct stream *stream_start(struct audio *a, const struct profile *p, bool dl, bool ul,
                            const struct sockaddr_in *peer, unsigned short local_port);

/* Stops and joins all threads, logs statistics to stderr. Does not close `a`. */
void stream_stop(struct stream *s);

#endif
