#include "fec.h"

#include <string.h>

static void
xor_into(unsigned char *acc, const unsigned char *src, size_t len)
{
    for (size_t i = 0; i < len; i++)
        acc[i] ^= src[i];
}

/* Build the XOR unit [len:2][payload] for a packet into u (FEC_UNIT_MAX).
 * Returns the unit length (2 + len), clamped. */
static size_t
fec_unit(unsigned char *u, const unsigned char *buf, size_t len)
{
    if (len > FEC_UNIT_MAX - 2)
        len = FEC_UNIT_MAX - 2;
    u[0] = (unsigned char)(len & 0xFF);
    u[1] = (unsigned char)((len >> 8) & 0xFF);
    memcpy(u + 2, buf, len);
    return len + 2;
}

/* ------------------------------------------------------------ encoder */
void
fec_enc_init(struct fec_enc *e, unsigned n)
{
    memset(e, 0, sizeof(*e));
    e->n = (n < FEC_N_MIN) ? FEC_N_MIN : (n > FEC_N_MAX ? FEC_N_MAX : n);
}

void
fec_enc_set_n(struct fec_enc *e, unsigned n)
{
    if (n < FEC_N_MIN) n = FEC_N_MIN;
    if (n > FEC_N_MAX) n = FEC_N_MAX;
    e->n = n;            /* applies to the next group that starts */
}

int
fec_enc_add(struct fec_enc *e, uint64_t seq, const void *buf, size_t len,
            uint64_t *groupbase, unsigned char *pbuf, size_t *plen)
{
    if (e->count == 0) {
        e->base = seq;
        e->maxlen = 0;
        memset(e->acc, 0, sizeof(e->acc));
    }
    unsigned char u[FEC_UNIT_MAX];
    size_t ulen = fec_unit(u, (const unsigned char *)buf, len);

    xor_into(e->acc, u, ulen);
    if (ulen > e->maxlen)
        e->maxlen = (uint16_t)ulen;
    e->count++;

    if (e->count < e->n)
        return 0;

    /* group complete: emit parity payload = [n:1][maxlen:2][acc:maxlen] */
    unsigned char *p = pbuf;
    p[0] = (unsigned char)e->n;
    p[1] = (unsigned char)(e->maxlen & 0xFF);
    p[2] = (unsigned char)((e->maxlen >> 8) & 0xFF);
    memcpy(p + 3, e->acc, e->maxlen);
    *plen = 3U + e->maxlen;
    *groupbase = e->base;
    e->count = 0;
    return 1;
}

/* ------------------------------------------------------------ decoder */
void
fec_dec_init(struct fec_dec *d)
{
    memset(d, 0, sizeof(*d));
}

static void
fec_dec_store(struct fec_dec *d, uint64_t seq, const void *buf, size_t len)
{
    if (len > FEC_UNIT_MAX - 2)
        len = FEC_UNIT_MAX - 2;
    struct fec_dec_slot *s = &d->slot[seq % FEC_DEC_RING];
    s->used = 1;
    s->seq = seq;
    s->len = (uint16_t)len;
    memcpy(s->buf, buf, len);
}

void
fec_dec_data(struct fec_dec *d, uint64_t seq, const void *buf, size_t len)
{
    fec_dec_store(d, seq, buf, len);
}

int
fec_dec_parity(struct fec_dec *d, uint64_t groupbase, unsigned n,
               uint16_t maxlen, const void *par, size_t parlen,
               uint64_t *out_seq, unsigned char *out_buf, size_t *out_len)
{
    if (n < FEC_N_MIN || n > FEC_N_MAX || maxlen > FEC_UNIT_MAX ||
        parlen < maxlen)
        return 0;

    /* XOR the parity with every present member of [base, base+n); track the
     * single missing index. If more than one is missing, we cannot recover. */
    unsigned char acc[FEC_UNIT_MAX];
    memcpy(acc, par, maxlen);

    unsigned missing = 0;
    unsigned miss_idx = 0;
    for (unsigned i = 0; i < n; i++) {
        uint64_t seq = groupbase + i;
        struct fec_dec_slot *s = &d->slot[seq % FEC_DEC_RING];
        if (!s->used || s->seq != seq) {
            missing++;
            miss_idx = i;
            if (missing > 1)
                return 0;             /* XOR recovers at most one loss */
            continue;
        }
        unsigned char u[FEC_UNIT_MAX];
        size_t ulen = fec_unit(u, s->buf, s->len);
        xor_into(acc, u, ulen);       /* ulen <= maxlen by construction */
    }
    if (missing != 1)
        return 0;                     /* group complete, or unrecoverable */

    /* acc now holds the missing member's unit [len:2][payload] */
    size_t plen = (size_t)acc[0] | ((size_t)acc[1] << 8);
    if (plen > (size_t)maxlen - 2)
        return 0;                     /* inconsistent */

    memcpy(out_buf, acc + 2, plen);
    *out_len = plen;
    *out_seq = groupbase + miss_idx;

    fec_dec_store(d, *out_seq, out_buf, plen);   /* so a later parity sees it */
    d->recovered++;
    return 1;
}

#ifdef FEC_TEST
/* Standalone correctness test: encode groups, drop one member each, decode,
 * assert the rebuilt packet is bit-exact. Build:
 *   cc -DFEC_TEST -I. src/fec.c -o /tmp/fectest && /tmp/fectest */
#include <stdio.h>
#include <stdlib.h>

static int failures;

static void
check_group(unsigned n, unsigned drop, const unsigned size_seed)
{
    struct fec_enc enc;
    struct fec_dec dec;
    fec_enc_init(&enc, n);
    fec_dec_init(&dec);

    unsigned char pkt[FEC_N_MAX][1500];
    size_t len[FEC_N_MAX];
    uint64_t base = 1000 * (uint64_t)n;   /* aligned so (seq/n)*n == base */
    unsigned char pbuf[FEC_UNIT_MAX];
    size_t plen = 0;
    uint64_t gbase = 0;

    for (unsigned i = 0; i < n; i++) {
        len[i] = 40 + ((size_seed * (i + 1) * 7) % 900);
        for (size_t b = 0; b < len[i]; b++)
            pkt[i][b] = (unsigned char)((i * 131 + b * 17 + size_seed) & 0xFF);
        int done = fec_enc_add(&enc, base + i, pkt[i], len[i],
                               &gbase, pbuf, &plen);
        if (done && i != n - 1) { printf("early parity\n"); failures++; }
        if (i == n - 1 && !done) { printf("no parity at group end\n"); failures++; }
    }

    /* feed all data except the dropped one */
    for (unsigned i = 0; i < n; i++) {
        if (i == drop)
            continue;
        fec_dec_data(&dec, base + i, pkt[i], len[i]);
    }

    unsigned char rec[FEC_UNIT_MAX];
    size_t rlen = 0;
    uint64_t rseq = 0;
    unsigned char nn = pbuf[0];
    uint16_t maxlen = (uint16_t)(pbuf[1] | (pbuf[2] << 8));
    int got = fec_dec_parity(&dec, gbase, nn, maxlen, pbuf + 3, plen - 3,
                             &rseq, rec, &rlen);
    if (!got) { printf("n=%u drop=%u: NOT recovered\n", n, drop); failures++; return; }
    if (rseq != base + drop) { printf("n=%u drop=%u: wrong seq %llu\n", n, drop,
                                      (unsigned long long)rseq); failures++; }
    if (rlen != len[drop] || memcmp(rec, pkt[drop], rlen)) {
        printf("n=%u drop=%u: CONTENT MISMATCH (len %zu vs %zu)\n",
               n, drop, rlen, len[drop]); failures++;
    }
}

int
main(void)
{
    for (unsigned n = 2; n <= 16; n++)
        for (unsigned drop = 0; drop < n; drop++)
            check_group(n, drop, n + drop + 1);

    /* two losses in a group: must NOT (wrongly) recover */
    {
        struct fec_enc enc; struct fec_dec dec;
        fec_enc_init(&enc, 6); fec_dec_init(&dec);
        unsigned char pkt[6][100]; size_t len = 80;
        uint64_t gbase; unsigned char pbuf[FEC_UNIT_MAX]; size_t plen;
        for (unsigned i = 0; i < 6; i++) {
            memset(pkt[i], i + 1, len);
            fec_enc_add(&enc, 6000 + i, pkt[i], len, &gbase, pbuf, &plen);
        }
        for (unsigned i = 0; i < 6; i++) if (i != 2 && i != 4)
            fec_dec_data(&dec, 6000 + i, pkt[i], len);
        unsigned char rec[FEC_UNIT_MAX]; size_t rlen; uint64_t rseq;
        int got = fec_dec_parity(&dec, gbase, pbuf[0],
                                 (uint16_t)(pbuf[1] | (pbuf[2] << 8)),
                                 pbuf + 3, plen - 3, &rseq, rec, &rlen);
        if (got) { printf("two-loss: wrongly recovered\n"); failures++; }
    }

    printf(failures ? "FEC TEST: %d FAILURES\n" : "FEC TEST: all passed\n",
           failures);
    return failures ? 1 : 0;
}
#endif
