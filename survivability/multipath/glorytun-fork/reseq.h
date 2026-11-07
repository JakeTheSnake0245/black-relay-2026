#pragma once

/* Black Relay receive-side resequencer.
 *
 * Packets arrive from the bonded links out of order (they were scheduled to
 * arrive nearly in order, but jitter and prediction error remain). Each data
 * packet carries a monotonic per-sender sequence number (added inside the
 * AEAD by the mud layer). This buffer releases packets to the tun device in
 * sequence order.
 *
 * A packet waiting on an earlier, missing sequence number is held until
 * either the gap fills or a deadline expires; on expiry the missing packet
 * is treated as lost and later packets flow. A bounded window caps memory
 * and hold time. Released packets are emitted via a caller callback, in
 * order, possibly several per push or tick.
 */

#include <stddef.h>
#include <inttypes.h>

struct reseq;

typedef void (*reseq_emit)(void *ctx, const void *buf, size_t len);

/* deadline_us: max time a packet may be held waiting on a gap.
 * window: max in-flight sequence span buffered (packets). 0 => defaults. */
struct reseq *reseq_new(uint64_t deadline_us, unsigned window);
void          reseq_free(struct reseq *);

/* Hand a received data packet to the buffer. Emits any now-deliverable
 * packets in order. now is a monotonic timestamp in microseconds. */
void reseq_push(struct reseq *, uint64_t seq, const void *buf, size_t len,
                uint64_t now, reseq_emit emit, void *ctx);

/* Call when idle (no packet received) to release packets whose gap has
 * passed its deadline. */
void reseq_tick(struct reseq *, uint64_t now, reseq_emit emit, void *ctx);

/* Stats snapshot for logging / `path show`. */
struct reseq_stats {
    uint64_t pushed;
    uint64_t released;
    uint64_t released_timeout;  /* released because a gap deadline expired */
    uint64_t dropped_late;      /* arrived below the delivery point */
    uint64_t dropped_overflow;  /* window overflow forced a skip */
    uint64_t dups;
    uint64_t held;              /* currently buffered */
    uint64_t max_hold_us;       /* worst observed hold time */
};
void reseq_get_stats(const struct reseq *, struct reseq_stats *);
