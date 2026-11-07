#include "reseq.h"

#include <stdlib.h>
#include <string.h>

#define RESEQ_WIN_DEFAULT   1024U
#define RESEQ_WIN_MAX      65536U
#define RESEQ_DEADLINE_DEF (50U * 1000U)  /* 50 ms in us */
#define RESEQ_PKT_MAX       2048U

struct reseq_slot {
    int used;
    uint64_t seq;
    uint64_t rx_time;
    size_t len;
    unsigned char buf[RESEQ_PKT_MAX];
};

struct reseq {
    uint64_t next;        /* next seq to deliver */
    int started;
    uint64_t deadline;    /* us */
    unsigned win;
    unsigned held;
    struct reseq_slot *slot;
    struct reseq_stats st;
};

struct reseq *
reseq_new(uint64_t deadline_us, unsigned window)
{
    struct reseq *r = calloc(1, sizeof(*r));
    if (!r)
        return NULL;
    r->deadline = deadline_us ? deadline_us : RESEQ_DEADLINE_DEF;
    r->win = window ? window : RESEQ_WIN_DEFAULT;
    if (r->win > RESEQ_WIN_MAX)
        r->win = RESEQ_WIN_MAX;
    r->slot = calloc(r->win, sizeof(*r->slot));
    if (!r->slot) {
        free(r);
        return NULL;
    }
    return r;
}

void
reseq_free(struct reseq *r)
{
    if (!r)
        return;
    free(r->slot);
    free(r);
}

/* Emit and clear the slot holding `next`, advancing next. Returns 1 if a
 * packet was emitted, 0 if the slot was empty. */
static int
reseq_emit_next(struct reseq *r, uint64_t now, reseq_emit emit, void *ctx)
{
    struct reseq_slot *s = &r->slot[r->next % r->win];

    if (!s->used || s->seq != r->next)
        return 0;

    uint64_t hold = now - s->rx_time;
    if (hold > r->st.max_hold_us)
        r->st.max_hold_us = hold;

    emit(ctx, s->buf, s->len);
    s->used = 0;
    r->held--;
    r->next++;
    r->st.released++;
    return 1;
}

/* Release every held packet in seq order and empty the buffer. */
static void
reseq_flush(struct reseq *r, uint64_t now, reseq_emit emit, void *ctx)
{
    while (r->held) {
        uint64_t lo = UINT64_MAX;
        for (unsigned i = 0; i < r->win; i++)
            if (r->slot[i].used && r->slot[i].seq < lo)
                lo = r->slot[i].seq;
        if (lo == UINT64_MAX)
            break;
        r->next = lo;
        while (reseq_emit_next(r, now, emit, ctx))
            ;
    }
}

/* Drain all in-order packets starting at next. */
static void
reseq_drain(struct reseq *r, uint64_t now, reseq_emit emit, void *ctx)
{
    while (reseq_emit_next(r, now, emit, ctx))
        ;
}

/* Is any packet buffered with seq > next (i.e. a gap we're waiting on)? */
static int
reseq_has_waiting(const struct reseq *r)
{
    return r->held > 0;
}

/* Find the oldest buffered packet's rx_time (for deadline checks). */
static int
reseq_oldest(const struct reseq *r, uint64_t *rx_time)
{
    int found = 0;
    uint64_t oldest = 0;
    for (unsigned i = 0; i < r->win; i++) {
        const struct reseq_slot *s = &r->slot[i];
        if (!s->used)
            continue;
        if (!found || s->rx_time < oldest) {
            oldest = s->rx_time;
            found = 1;
        }
    }
    if (found && rx_time)
        *rx_time = oldest;
    return found;
}

/* If next is a gap and the oldest held packet has waited past the deadline,
 * skip next (count it lost) so buffered packets can flow. Repeat. */
static void
reseq_expire(struct reseq *r, uint64_t now, reseq_emit emit, void *ctx)
{
    while (reseq_has_waiting(r)) {
        struct reseq_slot *s = &r->slot[r->next % r->win];
        if (s->used && s->seq == r->next) {
            reseq_drain(r, now, emit, ctx);
            continue;
        }
        uint64_t oldest;
        if (!reseq_oldest(r, &oldest))
            break;
        if (now - oldest < r->deadline)
            break;                 /* still within budget, keep waiting */
        /* deadline passed on a gap: declare r->next lost, advance */
        r->next++;
        r->st.released_timeout++;
        reseq_drain(r, now, emit, ctx);
    }
}

void
reseq_push(struct reseq *r, uint64_t seq, const void *buf, size_t len,
           uint64_t now, reseq_emit emit, void *ctx)
{
    r->st.pushed++;

    if (len > RESEQ_PKT_MAX)
        len = RESEQ_PKT_MAX;

    if (!r->started) {
        r->started = 1;
        r->next = seq;
    }

    /* below the delivery point: a straggler we already passed, or a dup */
    if (seq < r->next) {
        r->st.dropped_late++;
        return;
    }

    /* too far ahead for the window. Either the sender restarted (its
     * sequence jumps forward to wall-clock us: a new epoch) or a gap larger
     * than the window opened. Release everything held, in order, and restart
     * delivery at this packet; waiting on a window's worth of gaps would only
     * stall the new stream. */
    if (seq - r->next >= r->win) {
        reseq_flush(r, now, emit, ctx);
        r->next = seq;
        r->st.dropped_overflow++;
    }

    struct reseq_slot *s = &r->slot[seq % r->win];
    if (s->used && s->seq == seq) {
        r->st.dups++;
        return;
    }
    if (s->used) {
        /* slot collision from a seq exactly r->win apart; the occupant is
         * older and cannot be delivered before us without its own gap
         * resolving. Deliver the buffer forward to clear it. */
        r->st.dropped_overflow++;
        r->next = s->seq;           /* jump to the occupant */
        reseq_drain(r, now, emit, ctx);
        s = &r->slot[seq % r->win];
        if (s->used) {              /* still occupied: drop incoming */
            r->st.dropped_late++;
            return;
        }
    }

    s->used = 1;
    s->seq = seq;
    s->rx_time = now;
    s->len = len;
    memcpy(s->buf, buf, len);
    r->held++;

    reseq_drain(r, now, emit, ctx);
    reseq_expire(r, now, emit, ctx);
}

void
reseq_tick(struct reseq *r, uint64_t now, reseq_emit emit, void *ctx)
{
    if (r->started)
        reseq_expire(r, now, emit, ctx);
}

void
reseq_get_stats(const struct reseq *r, struct reseq_stats *out)
{
    *out = r->st;
    out->held = r->held;
}
