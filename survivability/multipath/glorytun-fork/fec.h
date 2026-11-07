#pragma once

/* Black Relay forward-error-correction (XOR parity).
 *
 * The sender groups N consecutive data packets and emits one parity packet
 * = XOR of the group. If exactly one of the N data packets is lost, the
 * receiver rebuilds it from the parity and the other N-1 — so a single loss
 * per group is recovered without waiting out the resequencer deadline.
 *
 * N is settable at runtime (the "adaptive" knob): a control loop can raise N
 * when loss is low (less overhead) and lower it when loss rises (more
 * protection). Overhead is 1/N.
 *
 * XOR recovers at most one loss per group. This is the cheap, low-latency
 * tier; Reed-Solomon (multi-loss) is a future upgrade behind the same API.
 *
 * The codec is pure (no crypto, no sockets) so it can be unit-tested in
 * isolation and dropped into the mud datapath. Each XOR unit is
 * [len:2][payload], zero-padded to the group's max; the 2-byte length lets
 * the receiver recover a rebuilt packet's true size.
 */

#include <stddef.h>
#include <inttypes.h>

#define FEC_UNIT_MAX   1600U          /* >= max inner packet + 2 (length) */
#define FEC_N_MIN      2U
#define FEC_N_MAX      64U

/* ---- encoder ---- */
struct fec_enc {
    unsigned n;                       /* current group size */
    unsigned count;                   /* members seen in this group */
    uint64_t base;                    /* seq of the group's first member */
    uint16_t maxlen;                  /* max unit length in this group */
    unsigned char acc[FEC_UNIT_MAX];  /* running XOR */
};

void fec_enc_init(struct fec_enc *, unsigned n);
void fec_enc_set_n(struct fec_enc *, unsigned n);   /* takes effect next group */

/* Add one data packet. If this completes a group, writes the parity payload
 * to pbuf (must be >= FEC_UNIT_MAX), sets *groupbase and *plen, returns 1.
 * Otherwise returns 0. */
int fec_enc_add(struct fec_enc *, uint64_t seq, const void *buf, size_t len,
                uint64_t *groupbase, unsigned char *pbuf, size_t *plen);

/* ---- decoder ----
 * Recent data packets are kept in a seq-indexed ring. Recovery happens when
 * a parity packet arrives: the decoder looks up the group's members in the
 * ring, and if exactly one is missing, rebuilds it. This avoids needing to
 * know the (adaptive) group size until the parity carries it. The ring must
 * exceed group size + worst reorder depth. */
#define FEC_DEC_RING 1024U

struct fec_dec_slot {
    int used;
    uint64_t seq;
    uint16_t len;                     /* inner packet length */
    unsigned char buf[FEC_UNIT_MAX];  /* inner packet */
};

struct fec_dec {
    struct fec_dec_slot slot[FEC_DEC_RING];
    uint64_t recovered;
};

void fec_dec_init(struct fec_dec *);

/* Record a received data packet (its inner bytes and seq). */
void fec_dec_data(struct fec_dec *, uint64_t seq, const void *buf, size_t len);

/* Process a received parity packet. If exactly one member of its group is
 * missing from the ring, rebuilds it: writes the recovered inner packet to
 * out_buf (>= FEC_UNIT_MAX), sets *out_seq and *out_len, returns 1. The
 * recovered packet is also inserted into the ring. Otherwise returns 0. */
int fec_dec_parity(struct fec_dec *, uint64_t groupbase, unsigned n,
                   uint16_t maxlen, const void *par, size_t parlen,
                   uint64_t *out_seq, unsigned char *out_buf, size_t *out_len);
